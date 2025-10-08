# Secure Software Delivery

This guide provides all the commands and files needed to complete the GSP521 Secure Software Delivery Challenge Lab.

## Prerequisites  

- Google Cloud Project with billing enabled
- Cloud Shell access
- Lab environment activated

## Task 1: Enable APIs and Set Up Environment

### 1.1 Enable Required APIs
```bash
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
```

### 1.2 Download Sample Application
```bash
mkdir sample-app && cd sample-app
gcloud storage cp gs://spls/gsp521/* .
```

### 1.3 Create Artifact Registry Repositories
```bash
# Set your region (replace with your lab region)
export REGION=us-central1

# Create scanning repository
gcloud artifacts repositories create artifact-scanning-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for vulnerability scanning"

# Create production repository
gcloud artifacts repositories create artifact-prod-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for production images"
```

## Task 2: Create the Cloud Build Pipeline

### 2.1 Add Roles to Cloud Build Service Account
```bash
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export CLOUD_BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/ondemandscanning.admin"
```

### 2.2 Update cloudbuild.yaml (Initial Version)

Create or update the `cloudbuild.yaml` file with the basic pipeline:

```yaml
steps:
# Build Step
- id: "build"
  name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest', '.']
  waitFor: ['-']

# Push to Artifact Registry
- id: "push"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest']

images:
  - ${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest

substitutions:
  _REGION: us-central1
```

### 2.3 Submit the Build
```bash
gcloud builds submit . --config cloudbuild.yaml --substitutions _REGION=$REGION
```

## Task 3: Set Up Binary Authorization

### 3.1 Create Attestor Note
```bash
# Create the note JSON file
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

# Create the note using Container Analysis API
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -X POST \
     -d @note.json \
     "https://containeranalysis.googleapis.com/v1/projects/$PROJECT_ID/notes?noteId=vulnerability_note"
```

### 3.2 Verify Note Creation
```bash
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://containeranalysis.googleapis.com/v1/projects/$PROJECT_ID/notes/vulnerability_note"
```

### 3.3 Create Binary Authorization Attestor
```bash
gcloud container binauthz attestors create vulnerability-attestor \
    --attestation-authority-note=vulnerability_note \
    --attestation-authority-note-project=$PROJECT_ID
```

### 3.4 List Attestors
```bash
gcloud container binauthz attestors list
```

### 3.5 Set IAM Policy on Note
```bash
# Create IAM policy JSON
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

# Apply IAM policy
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "Content-Type: application/json" \
     -X POST \
     -d @iam-policy.json \
     "https://containeranalysis.googleapis.com/v1/projects/$PROJECT_ID/notes/vulnerability_note:setIamPolicy"
```

### 3.6 Create KMS Keyring and Key
```bash
# Create keyring
gcloud kms keyrings create binauthz-keys --location=global

# Create asymmetric signing key
gcloud kms keys create lab-key \
    --keyring=binauthz-keys \
    --location=global \
    --purpose=asymmetric-signing \
    --default-algorithm=rsa-sign-pkcs1-2048-sha256
```

### 3.7 Link Key to Attestor
```bash
gcloud container binauthz attestors public-keys add \
    --attestor=vulnerability-attestor \
    --keyversion-project=$PROJECT_ID \
    --keyversion-location=global \
    --keyversion-keyring=binauthz-keys \
    --keyversion-key=lab-key \
    --keyversion=1
```

### 3.8 Update Binary Authorization Policy
```bash
# Get current policy
gcloud container binauthz policy export > policy.yaml

# Update policy to require attestations
cat > policy.yaml << EOF
defaultAdmissionRule:
  requireAttestationsBy:
  - projects/$PROJECT_ID/attestors/vulnerability-attestor
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  evaluationMode: REQUIRE_ATTESTATION
globalPolicyEvaluationMode: ENABLE
name: projects/$PROJECT_ID/policy
EOF

# Import updated policy
gcloud container binauthz policy import policy.yaml
```

## Task 4: Create CI/CD Pipeline with Vulnerability Scanning

### 4.1 Add Additional Roles to Cloud Build Service Account
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/binaryauthorization.attestorsViewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/cloudkms.signerVerifier"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}" \
    --role="roles/containeranalysis.notes.attacher"

# Add role to Compute Engine default service account
export COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/cloudkms.signerVerifier"
```

### 4.2 Install Custom Build Step
```bash
git clone https://github.com/GoogleCloudPlatform/cloud-builders-community.git
cd cloud-builders-community/binauthz-attestation
gcloud builds submit . --config cloudbuild.yaml
cd ../..
rm -rf cloud-builders-community
```

### 4.3 Update cloudbuild.yaml (Complete Version)

Replace the existing `cloudbuild.yaml` with this complete version:

```yaml
steps:

# Build Step
- id: "build"
  name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest', '.']
  waitFor: ['-']

# Push to Artifact Registry
- id: "push"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push',  '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest']

# Run a vulnerability scan
- id: scan
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    (gcloud artifacts docker images scan \
    ${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest \
    --location us \
    --format="value(response.scan)") > /workspace/scan_id.txt

# Analyze the result of the scan
- id: severity check
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
      gcloud artifacts docker images list-vulnerabilities $(cat /workspace/scan_id.txt) \
      --format="value(vulnerability.effectiveSeverity)" | if grep -Fxq CRITICAL; \
      then echo "Failed vulnerability check for CRITICAL level" && exit 1; else echo \
      "No CRITICAL vulnerability found, congrats !" && exit 0; fi

# Sign the image only if the previous severity check passes
- id: 'create-attestation'
  name: 'gcr.io/${PROJECT_ID}/binauthz-attestation:latest'
  args:
    - '--artifact-url'
    - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest'
    - '--attestor'
    - 'vulnerability-attestor'
    - '--keyversion'
    - 'projects/${PROJECT_ID}/locations/global/keyRings/binauthz-keys/cryptoKeys/lab-key/cryptoKeyVersions/1'

# Re-tag the image for production and push it to the production repository
- id: "push-to-prod"
  name: 'gcr.io/cloud-builders/docker'
  args: 
    - 'tag' 
    - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest'
    - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-prod-repo/sample-image:latest'
- id: "push-to-prod-final"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-prod-repo/sample-image:latest']

# Deploy to Cloud Run
- id: 'deploy-to-cloud-run'
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    gcloud run deploy auth-service --image=${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-prod-repo/sample-image:latest \
    --binary-authorization=default --region=${_REGION} --allow-unauthenticated

images:
  - ${_REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image:latest

substitutions:
  _REGION: us-central1
```

### 4.4 Submit the Build (This Will Fail)
```bash
gcloud builds submit . --config cloudbuild.yaml --substitutions _REGION=$REGION
```

This build will fail due to CRITICAL vulnerabilities. This is expected behavior.

## Task 5: Fix Vulnerability and Redeploy

### 5.1 Update Dockerfile
Replace the existing Dockerfile with the fixed version:

```dockerfile
FROM python:3.8-alpine

WORKDIR /app

COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8080

CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app
```

### 5.2 Update requirements.txt
Replace the existing requirements.txt with the fixed versions:

```
Flask==3.0.3
gunicorn==23.0.0
Werkzeug==3.0.4
```

### 5.3 Re-trigger the Build
```bash
gcloud builds submit . --config cloudbuild.yaml --substitutions _REGION=$REGION
```

This build should now succeed.

### 5.4 Allow Unauthenticated Access (Testing Only)
```bash
gcloud beta run services add-iam-policy-binding --region=$REGION --member=allUsers --role=roles/run.invoker auth-service
```

### 5.5 Test the Deployment
```bash
# Get the service URL
gcloud run services describe auth-service --region=$REGION --format="value(status.url)"

# Test the service
curl $(gcloud run services describe auth-service --region=$REGION --format="value(status.url)")
```

## Verification Commands

To check your progress throughout the lab:

```bash
# Check Artifact Registry repositories
gcloud artifacts repositories list --location=$REGION

# Check Binary Authorization attestors
gcloud container binauthz attestors list

# Check Cloud Build history
gcloud builds list --limit=10

# Check Cloud Run services
gcloud run services list --region=$REGION

# Check KMS keys
gcloud kms keys list --keyring=binauthz-keys --location=global
```

## Troubleshooting

### Common Issues:

1. **Build fails with permission errors**: Ensure all IAM roles are properly assigned to service accounts.

2. **Vulnerability scan fails**: Wait a few minutes after pushing the image before running the scan.

3. **Attestation fails**: Verify that the KMS key path is correct and the attestor is properly configured.

4. **Cloud Run deployment fails**: Check that Binary Authorization policy is correctly configured.

### Environment Variables Reference:
```bash
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export REGION=us-central1  # Replace with your lab region
export CLOUD_BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
export COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
```

Remember to replace placeholder values (like region) with your actual lab environment values when executing commands.
