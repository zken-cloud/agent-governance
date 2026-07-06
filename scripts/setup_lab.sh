#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

# Text formatting colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

echo -e "${BLUE}===================================================================${RESET}"
echo -e "${BLUE}  Agent Gateway Skill Boost Lab Setup & Bootstrap Script           ${RESET}"
echo -e "${BLUE}===================================================================${RESET}"

# Step 1: Detect Active Google Cloud Configuration
echo -e "\n${GREEN}[Step 1/5] Detecting active Google Cloud environment...${RESET}"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo -e "${RED}[ERROR] No active Google Cloud Project detected.${RESET}"
    echo -e "${YELLOW}Please run: gcloud config set project <your-project-id>${RESET}"
    exit 1
fi
echo -e "  Active Project ID: ${YELLOW}${PROJECT_ID}${RESET}"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || echo "")
echo -e "  Project Number:    ${YELLOW}${PROJECT_NUMBER}${RESET}"

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
echo -e "  Active Account:    ${YELLOW}${ACTIVE_ACCOUNT}${RESET}"

# Try to resolve Organization ID
ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" | awk '$2 == "organization" {print $1}' 2>/dev/null || echo "")
if [[ -z "$ORG_ID" ]]; then
    echo -e "  ${YELLOW}[WARNING] Organization ID could not be detected automatically.${RESET}"
    echo -e "  This happens if your project is not in an organization or you lack parent-level read permissions."
    echo -e "  A dummy Organization ID (123456789012) will be used in your tfvars. Please replace if necessary."
    ORG_ID="123456789012"
else
    echo -e "  Organization ID:   ${YELLOW}${ORG_ID}${RESET}"
fi

# Step 2: Install and Verify Prerequisites
echo -e "\n${GREEN}[Step 2/5] Checking and installing required prerequisites...${RESET}"

# Check for uv
if ! command -v uv &> /dev/null; then
    echo -e "  Installing ${BLUE}uv${RESET} (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Add to path for current session
    export PATH="${HOME}/.local/bin:${PATH}"
else
    echo -e "  ${GREEN}✓${RESET} uv is already installed."
fi

# Check for skaffold
if ! command -v skaffold &> /dev/null; then
    echo -e "  Installing ${BLUE}skaffold${RESET} locally..."
    OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH_NAME=$(uname -m)
    if [[ "$ARCH_NAME" == "x86_64" ]]; then
        ARCH_NAME="amd64"
    elif [[ "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ]]; then
        ARCH_NAME="arm64"
    fi
    mkdir -p "${HOME}/.local/bin"
    echo -e "  Downloading skaffold for ${OS_NAME}-${ARCH_NAME}..."
    curl -Lo "${HOME}/.local/bin/skaffold" "https://storage.googleapis.com/skaffold/releases/latest/skaffold-${OS_NAME}-${ARCH_NAME}"
    chmod +x "${HOME}/.local/bin/skaffold"
    export PATH="${HOME}/.local/bin:${PATH}"
else
    echo -e "  ${GREEN}✓${RESET} skaffold is already installed."
fi

# Check for envsubst (gettext-base)
if ! command -v envsubst &> /dev/null; then
    echo -e "  Creating Python fallback wrapper for ${BLUE}envsubst${RESET}..."
    mkdir -p "${HOME}/.local/bin"
    cat > "${HOME}/.local/bin/envsubst" <<'EOF'
#!/usr/bin/env python3
import os, sys
sys.stdout.write(os.path.expandvars(sys.stdin.read()))
EOF
    chmod +x "${HOME}/.local/bin/envsubst"
    export PATH="${HOME}/.local/bin:${PATH}"
else
    echo -e "  ${GREEN}✓${RESET} envsubst is already installed."
fi


# Step 3: Enable Required Google Cloud APIs
echo -e "\n${GREEN}[Step 3/5] Enabling required Google Cloud APIs...${RESET}"
echo -e "  This enables all foundational, routing, container, security, and AI services."
gcloud services enable \
  compute.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  storage.googleapis.com \
  dns.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  networkservices.googleapis.com \
  networksecurity.googleapis.com \
  modelarmor.googleapis.com \
  aiplatform.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  cloudtrace.googleapis.com \
  servicedirectory.googleapis.com


# Step 4: Configure GCS Terraform State Bucket
echo -e "\n${GREEN}[Step 4/5] Creating GCS bucket for remote Terraform state...${RESET}"
BUCKET_NAME="${PROJECT_ID}-tfstate"
REGION="us-central1"

if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
    echo -e "  Creating bucket ${BLUE}gs://${BUCKET_NAME}${RESET} in region ${YELLOW}${REGION}${RESET}..."
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
      --location="${REGION}" \
      --uniform-bucket-level-access
else
    echo -e "  ${GREEN}✓${RESET} Storage bucket ${BLUE}gs://${BUCKET_NAME}${RESET} already exists."
fi

# Step 5: Auto-Generate Terraform Config Files
echo -e "\n${GREEN}[Step 5/5] Generating backend.conf and terraform.tfvars files...${RESET}"

# Generate backend.conf
cat > terraform/backend.conf <<EOF
bucket = "${BUCKET_NAME}"
prefix = "agent-gateway"
EOF
echo -e "  ${GREEN}✓${RESET} Created ${BLUE}terraform/backend.conf${RESET}"

# Generate terraform.tfvars
cat > terraform/terraform.tfvars <<EOF
# Automatically generated by setup_lab.sh
project_id                             = "${PROJECT_ID}"
organization_id                        = "${ORG_ID}"
platform_admin_members                 = ["user:${ACTIVE_ACCOUNT}"]
agent_gateway_iap_iam_enforcement_mode = "DRY_RUN"
enable_cloud_run_private_networking    = false
EOF
echo -e "  ${GREEN}✓${RESET} Created ${BLUE}terraform/terraform.tfvars${RESET}"

echo -e "\n${GREEN}===================================================================${RESET}"
echo -e "  ${GREEN}Setup Complete! Environment is fully bootstrapped.               ${RESET}"
echo -e "  Next steps for the student:${RESET}"
echo -e "    1. Run: ${YELLOW}cd terraform && terraform init -backend-config=backend.conf${RESET}"
echo -e "    2. Run: ${YELLOW}terraform apply${RESET}"
echo -e "${GREEN}===================================================================${RESET}"
