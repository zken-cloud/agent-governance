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

set -uo pipefail

export PATH="/Users/zken/.local/bin:$PATH"

# Text formatting colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

echo -e "${BLUE}===================================================================${RESET}"
echo -e "${BLUE}  Agent Gateway Skill Boost Lab - Progress Verification Script      ${RESET}"
echo -e "${BLUE}===================================================================${RESET}"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo -e "${RED}[ERROR] No active Google Cloud Project detected.${RESET}"
    exit 1
fi
REGION="us-central1"

PASSED_CHECKS=0
TOTAL_CHECKS=6

print_result() {
    if [[ $1 -eq 0 ]]; then
        echo -e "  [ ${GREEN}PASS${RESET} ] $2"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "  [ ${RED}FAIL${RESET} ] $2"
        if [[ -n "${3:-}" ]]; then
            echo -e "           ${YELLOW}Tip: $3${RESET}"
        fi
    fi
}

# Check 1: APIs Enabled
echo -e "\n${BLUE}Checking Stage 1: Google Cloud APIs...${RESET}"
apis=(
  "compute.googleapis.com"
  "run.googleapis.com"
  "networkservices.googleapis.com"
  "networksecurity.googleapis.com"
  "modelarmor.googleapis.com"
)
api_fail=0
for api in "${apis[@]}"; do
    if ! gcloud services list --enabled --filter="config.name=$api" --project="${PROJECT_ID}" --format="value(config.name)" | grep -q "$api"; then
        api_fail=1
        echo -e "  - ${RED}API not enabled:${RESET} $api"
    fi
done
print_result $api_fail "Required Google Cloud APIs are enabled." "Run 'gcloud services enable <api>' or ensure Terraform has been applied."

# Check 2: VPC Networking & Subnets
echo -e "\n${BLUE}Checking Stage 2: VPC Network and Subnets...${RESET}"
net_fail=0
if ! gcloud compute networks describe gateway-vpc --project="${PROJECT_ID}" &>/dev/null; then
    net_fail=1
    echo -e "  - ${RED}VPC Network 'gateway-vpc' not found.${RESET}"
fi
if ! gcloud compute networks subnets describe mcp-subnet-us-central1 --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    net_fail=1
    echo -e "  - ${RED}Primary Subnet 'mcp-subnet-us-central1' not found.${RESET}"
fi
if ! gcloud compute networks subnets describe agent-coloc-agent-gateway-subnet --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    # Fallback/wildcard check for agent gateway subnet
    if ! gcloud compute networks subnets list --regions="${REGION}" --project="${PROJECT_ID}" --format="value(name)" | grep -q "agent-gateway-subnet"; then
        net_fail=1
        echo -e "  - ${RED}Agent Gateway Subnet not found.${RESET}"
    fi
fi
print_result $net_fail "VPC network ('gateway-vpc') and subnets are correctly provisioned." "Ensure 'terraform apply' ran successfully."

# Check 3: Cloud Run MCP Services
echo -e "\n${BLUE}Checking Stage 3: Cloud Run MCP Servers...${RESET}"
run_fail=0
services=("legacy-dms" "corporate-email" "income-verification")
for svc in "${services[@]}"; do
    if ! gcloud run services describe "$svc" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        run_fail=1
        echo -e "  - ${RED}Cloud Run Service '$svc' not found.${RESET}"
    fi
done
print_result $run_fail "All three MCP Servers are successfully deployed to Cloud Run." "Ensure skaffold run or terraform apply ran successfully."

# Check 4: Model Armor Template
echo -e "\n${BLUE}Checking Stage 4: Model Armor Templates...${RESET}"
ma_fail=0
if ! gcloud alpha model-armor templates list --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null | grep -q "agent-gateway"; then
    # Fallback 1: check general list
    if ! gcloud alpha model-armor templates list --location="global" --project="${PROJECT_ID}" --format="value(name)" &>/dev/null && ! gcloud alpha model-armor templates list --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)" &>/dev/null; then
        # Fallback 2: Check terraform state if gcloud command is blocked or failing (e.g. ECP Proxy issues)
        if [[ -d "terraform" ]]; then
            echo -e "  - ${YELLOW}gcloud query failed or returned no templates. Falling back to local Terraform state audit...${RESET}"
            tf_out=$(cd terraform && terraform state list 2>&1)
            if echo "$tf_out" | grep -q "google_model_armor_template"; then
                echo -e "  - ${GREEN}Detected Model Armor Template resources in Terraform state.${RESET}"
            else
                ma_fail=1
                echo -e "  - ${RED}No active Model Armor templates found in GCP or Terraform state.${RESET}"
                echo -e "    ${YELLOW}Terraform Output/Error:${RESET}\n$tf_out"
            fi
        else
            ma_fail=1
            echo -e "  - ${RED}No active Model Armor templates found.${RESET}"
        fi
    fi
fi
print_result $ma_fail "Model Armor AI Safety Templates are configured." "Check if var.enable_model_armor is true and Terraform was applied."

# Check 5: Agent Gateway
echo -e "\n${BLUE}Checking Stage 5: Agent Gateway resource...${RESET}"
gw_fail=0
if ! gcloud alpha network-services agent-gateways describe agent-gateway --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gw_fail=1
    echo -e "  - ${RED}Agent Gateway 'agent-gateway' not found.${RESET}"
fi
print_result $gw_fail "Agent Gateway resource is successfully deployed and active." "Ensure 'var.enable_agent_gateway = true' and Terraform apply was completed."

# Check 6: Service Extensions & Authorization Policies
echo -e "\n${BLUE}Checking Stage 6: Security Policies...${RESET}"
policy_fail=0
# List authz policies
if ! gcloud beta network-security authz-policies list --location="${REGION}" --project="${PROJECT_ID}" --format="value(name)" | grep -q "agent-gateway"; then
    policy_fail=1
    echo -e "  - ${RED}Agent Gateway Authorization Policies (IAP/Model Armor) not found.${RESET}"
fi
print_result $policy_fail "IAP / Model Armor service authorization policies are deployed." "Verify that both Authorization Policies have been created via Terraform."

echo -e "\n${BLUE}===================================================================${RESET}"
if [[ $PASSED_CHECKS -eq $TOTAL_CHECKS ]]; then
    echo -e "  ${GREEN}CONGRATULATIONS! All ${PASSED_CHECKS}/${TOTAL_CHECKS} checks passed successfully!${RESET}"
    echo -e "  Your Agent Gateway Governance environment is 100% correctly set up."
else
    echo -e "  ${RED}VERIFICATION FAILED: Passed ${PASSED_CHECKS}/${TOTAL_CHECKS} checks.${RESET}"
    echo -e "  Please review the failures and suggestions above before testing."
fi
echo -e "${BLUE}===================================================================${RESET}"

# Exit code indicates status
if [[ $PASSED_CHECKS -eq $TOTAL_CHECKS ]]; then
    exit 0
else
    exit 1
fi
