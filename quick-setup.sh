#!/bin/bash

# Secure Software Delivery Challenge Lab - Complete Setup Script
# Run this script in Google Cloud Shell

set -e

echo "Starting Secure Software Delivery Challenge Lab Setup..."

# Set environment variables
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export REGION=us-central1  # Change this if your lab uses a different region
export CLOUD_BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
export COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "Project ID: $PROJECT_ID"
echo "Project Number: $PROJECT_NUMBER"
echo "Region: $REGION"

# Task 1: Enable APIs
echo "Enabling APIs..."
gcloud services enable \
  cloudkms.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  container.googleapis.com \
  containerregistry.googleapis.com \
  artifactregistry.googleapis.com \
  containerscanning.googleapis.com \
  ondemandscanning.googleapis.com \
  binaryauthorization.googleapis.com

# Download sample app
echo "Downloading sample application..."
mkdir -p sample-app && cd sample-app
gcloud storage cp gs://spls/gsp521/* .

# Create Artifact Registry repositories
echo "Creating Artifact Registry repositories..."
gcloud artifacts repositories create artifact-scanning-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for vulnerability scanning"

gcloud artifacts repositories create artifact-prod-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for production images"

# Task 2: Initial Cloud Build setup
echo "Setting up Cloud Build service account permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/ondemandscanning.admin"

# Task 3: Binary Authorization setup
echo "Setting up Binary Authorization..."

# Create attestor note
cat > note.json << EOF
{
  "name": "projects/$PROJECT_ID/notes/vulnerability_note",
  "attestation": {
    "hint": {
      "human_readable_name": "Container Vulnerabilities attestation authority"
    }
  }
}
EOF

# Create note via API
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -X POST \
     -d @note.json \
     "https://containeranalysis.googleapis.com/v1/projects/$PROJECT_ID/notes?noteId=vulnerability_note"

# Create attestor
gcloud container binauthz attestors create vulnerability-attestor \
    --attestation-authority-note=vulnerability_note \
    --attestation-authority-note-project=$PROJECT_ID

# Set IAM policy on note
cat > iam-policy.json << EOF
{
  "bindings": [
    {
      "role": "roles/containeranalysis.notes.occurrences.viewer",
      "members": [
        "serviceAccount:service-$PROJECT_NUMBER@gcp-sa-binaryauthorization.iam.gserviceaccount.com"
      ]
    }
  ]
}
EOF

curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -X POST \
     -d @iam-policy.json \
     "https://containeranalysis.googleapis.com/v1/projects/$PROJECT_ID/notes/vulnerability_note:setIamPolicy"

# Create KMS keyring and key
echo "Creating KMS keyring and key..."
gcloud kms keyrings create binauthz-keys --location=global

gcloud kms keys create lab-key \
    --keyring=binauthz-keys \
    --location=global \
    --purpose=asymmetric-signing \
    --default-algorithm=rsa-sign-pkcs1-2048-sha256

# Link key to attestor
gcloud container binauthz attestors public-keys add \
    --attestor=vulnerability-attestor \
    --keyversion-project=$PROJECT_ID \
    --keyversion-location=global \
    --keyversion-keyring=binauthz-keys \
    --keyversion-key=lab-key \
    --keyversion=1

# Update Binary Authorization policy
cat > policy.yaml << EOF
defaultAdmissionRule:
  requireAttestationsBy:
  - projects/$PROJECT_ID/attestors/vulnerability-attestor
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  evaluationMode: REQUIRE_ATTESTATION
globalPolicyEvaluationMode: ENABLE
name: projects/$PROJECT_ID/policy
EOF

gcloud container binauthz policy import policy.yaml

# Task 4: Complete CI/CD pipeline setup
echo "Setting up complete CI/CD pipeline..."

# Add additional roles to Cloud Build service account
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/binaryauthorization.attestorsViewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/cloudkms.signerVerifier"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/containeranalysis.notes.attacher"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/cloudkms.signerVerifier"

# Install custom build step
echo "Installing custom build step..."
git clone https://github.com/GoogleCloudPlatform/cloud-builders-community.git
cd cloud-builders-community/binauthz-attestation
gcloud builds submit . --config cloudbuild.yaml
cd ../..
rm -rf cloud-builders-community

# Update files for vulnerability fix
echo "Creating fixed application files..."

# Create fixed Dockerfile
cat > Dockerfile << EOF
FROM python:3.8-alpine

WORKDIR /app

COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8080

CMD exec gunicorn --bind :\$PORT --workers 1 --threads 8 --timeout 0 main:app
EOF

# Create fixed requirements.txt
cat > requirements.txt << EOF
Flask==3.0.3
gunicorn==23.0.0
Werkzeug==3.0.4
EOF

# Create complete cloudbuild.yaml
cat > cloudbuild.yaml << EOF
steps:

# Build Step
- id: "build"
  name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '\${_REGION}-docker.pkg.dev/\${PROJECT_ID}/artifact-scanning-repo/sample-image:latest', '.']
  waitFor: ['-']

# Push to Artifact Registry
- id: "push"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push',  '\${_REGION}-docker.pkg.dev/\${PROJECT_ID}/artifact-scanning-repo/sample-image:latest']

# Run a vulnerability scan
- id: scan
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    (gcloud artifacts docker images scan \\
    \${_REGION}-docker.pkg.dev/\${PROJECT_ID}/artifact-scanning-repo/sample-image:latest \\
    --location us \\
    --format="value(response.scan)") > /workspace/scan_id.txt

# Analyze the result of the scan
- id: severity check
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
      gcloud artifacts docker images list-vulnerabilities \$(cat /workspace/scan_id.txt) \\
      --format="value(vulnerability.effectiveSeverity)" | if grep -Fxq CRITICAL; \\
      then echo "Failed vulnerability check for CRITICAL level" && exit 1; else echo \\
      "No CRITICAL vulnerability found, congrats !" && exit 0; fi

# Sign the image only if the previous severity check passes
- id: 'create-attestation'
  name: 'gcr.io/\${PROJECT_ID}/binauthz-attestation:latest'
  args:
    - '--artifact-url'
    - '\${_REGION}-docker.pkg.dev/\${PROJECT_ID}/artifact-scanning-repo/sample-image:latest'
    - '--attestor'
    - 'vulnerability-attestor'
    - '--keyversion'
    - 'projects/\${PROJECT_ID}/locations/global/keyRings/binauth
