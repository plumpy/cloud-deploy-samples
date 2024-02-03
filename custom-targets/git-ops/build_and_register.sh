#!/bin/bash
# Copyright 2023 Google LLC
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https:#www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

CT_SRCDIR="git-ops/git-deployer"
CT_IMAGE_NAME=git
CT_TYPE_NAME=git
CT_CUSTOM_ACTION_NAME=git-deployer
CT_GCS_DIRECTORY=git
CT_SKAFFOLD_CONFIG_NAME=gitConfig
CT_USE_DEFAULT_RENDERER=true

if [[ ! -v PROJECT_ID || ! -v REGION ]]; then
  echo "This script requires \$PROJECT_ID and \$REGION to be set."
  exit 1
fi

boldout() {
  echo "$(tput bold)$(tput setaf 2)>> $*$(tput sgr0)"
}

TMPDIR=$(mktemp -d)
trap 'rm -rf -- "${TMPDIR}"' EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CUSTOM_TARGETS_DIR="${SCRIPT_DIR}/.."
if [[ ! -d "${CUSTOM_TARGETS_DIR}/${CT_SRCDIR}" ]]; then
  boldout "Cloning cloud-deploy-samples repo into ${TMPDIR}"
  git clone --quiet https://github.com/GoogleCloudPlatform/cloud-deploy-samples "${TMPDIR}"
  CUSTOM_TARGETS_DIR="${TMPDIR}/custom-targets"
fi

AR_REPO=$REGION-docker.pkg.dev/$PROJECT_ID/cd-custom-targets
if ! gcloud -q artifacts repositories describe --location "$REGION" --project "$PROJECT_ID" cd-custom-targets > /dev/null 2>&1; then
  boldout "Creating Artifact Registry repository: ${AR_REPO}"
  gcloud -q artifacts repositories create --location "$REGION" --project "$PROJECT_ID" --repository-format docker cd-custom-targets
fi

boldout "Granting the default compute service account access to ${AR_REPO}"
gcloud -q artifacts repositories add-iam-policy-binding \
    --project "${PROJECT_ID}" --location "${REGION}" cd-custom-targets \
    --member="serviceAccount:$(gcloud -q projects describe "${PROJECT_ID}" --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
    --role=roles/artifactregistry.reader > /dev/null

BUCKET_NAME="${PROJECT_ID}-${REGION}-custom-targets"
if ! gsutil ls "gs://${BUCKET_NAME}" > /dev/null 2>&1; then
  boldout "Creating a storage bucket to hold the custom target configuration"
  gcloud -q storage buckets create --project "${PROJECT_ID}" --location "${REGION}" "gs://${BUCKET_NAME}"
fi

boldout "Building the Custom Target image in Cloud Build."
boldout "This will take approximately 10 minutes"

cat >"${TMPDIR}/cloudbuild.yaml" <<'EOF'
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: [
    'build',
    '--build-arg', 'COMMIT_SHA=$COMMIT_SHA',
    '-t', '$LOCATION-docker.pkg.dev/$PROJECT_ID/$_AR_REPO_NAME/$_IMAGE_NAME',
    '-f', 'Dockerfile',
    '.'
  ]
images:
- '$LOCATION-docker.pkg.dev/$PROJECT_ID/$_AR_REPO_NAME/$_IMAGE_NAME'
options:
  logging: CLOUD_LOGGING_ONLY
  requestedVerifyOption: VERIFIED
EOF

# get the commit hash to pass to the build
COMMIT_SHA=$(cd "${CUSTOM_TARGETS_DIR}" && git rev-parse --verify HEAD)

# Using `beta` because the non-beta command won't stream the build logs
gcloud -q beta builds submit --project="$PROJECT_ID" --region="$REGION" \
    --substitutions="_AR_REPO_NAME=cd-custom-targets,_IMAGE_NAME=${CT_IMAGE_NAME},COMMIT_SHA=${COMMIT_SHA}" \
    --config="${TMPDIR}/cloudbuild.yaml" \
    "${CUSTOM_TARGETS_DIR}/${CT_SRCDIR}"

IMAGE_SHA=$(gcloud -q artifacts docker images describe "${AR_REPO}/${CT_IMAGE_NAME}:latest" --project "${PROJECT_ID}" --format 'get(image_summary.digest)')

boldout "Uploading the custom target definition to gs://${BUCKET_NAME}"
cat >"${TMPDIR}/skaffold.yaml" <<EOF
apiVersion: skaffold/v4beta7
kind: Config
metadata:
  name: ${CT_SKAFFOLD_CONFIG_NAME}
customActions:
  - name: ${CT_CUSTOM_ACTION_NAME}
    containers:
      - name: ${CT_CUSTOM_ACTION_NAME}
        image: ${AR_REPO}/${CT_IMAGE_NAME}@${IMAGE_SHA}
EOF
gsutil -q cp "${TMPDIR}/skaffold.yaml" "gs://${BUCKET_NAME}/${CT_GCS_DIRECTORY}/skaffold.yaml"

boldout "Create the CustomTargetType resource in Cloud Deploy"
cat >"${TMPDIR}/clouddeploy.yaml" <<EOF
apiVersion: deploy.cloud.google.com/v1
kind: CustomTargetType
metadata:
  name: ${CT_TYPE_NAME}
customActions:
EOF
if [[ ! -v CT_USE_DEFAULT_RENDERER ]]; then
  echo "  renderAction: ${CT_CUSTOM_ACTION_NAME}" >> "${TMPDIR}/clouddeploy.yaml"
fi
cat >>"${TMPDIR}/clouddeploy.yaml" <<EOF
  deployAction: ${CT_CUSTOM_ACTION_NAME}
  includeSkaffoldModules:
    - configs: ["${CT_SKAFFOLD_CONFIG_NAME}"]
      googleCloudStorage:
        source: "gs://${BUCKET_NAME}/${CT_GCS_DIRECTORY}/*"
        path: "skaffold.yaml"
EOF
gcloud -q deploy apply --project "${PROJECT_ID}" --region "${REGION}" --file "${TMPDIR}/clouddeploy.yaml"
