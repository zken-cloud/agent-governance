# Demo Scripts Guide - Agent Gateway & Governance

This guide provides a detailed technical breakdown of the three custom automation scripts located in the `scripts/` directory of the repository. These scripts automate the lifecycle of the Agent Gateway Governance demo: from project bootstrap and prerequisite installation to securing the agent egress plane and auditing the deployment.

---

## Script 1: `scripts/setup_lab.sh` (Bootstrap & API Enablement)

### Purpose
When deploying to a brand-new Google Cloud project, there are multiple manual steps: installing client tools, enabling APIs, and configuring Terraform variables and backend settings. `setup_lab.sh` automates this entire bootstrapping phase, transforming any fresh GCP sandbox into a ready-to-use playground.

### What It Does (Step-by-Step)
1. **Detects Google Cloud Environment Context**:
   - Queries `gcloud config` to auto-detect the active `PROJECT_ID`, numeric `PROJECT_NUMBER`, and authenticated user `ACTIVE_ACCOUNT`.
   - Attempts to resolve the parent Google Cloud `ORG_ID`. If none is found (common in standalone personal sandboxes), it falls back to a dummy Org ID (`123456789012`) and warns the user.
2. **Installs Local Developer Prerequisites (No Sudo Required)**:
   - **`uv`**: Installs Astral's ultra-fast Python package manager to `${HOME}/.local/bin/uv` if not already installed.
   - **`skaffold`**: Detects the host's operating system (macOS/Linux) and architecture (Intel/Apple Silicon) to fetch the correct static binary from Google Storage, placing it in `${HOME}/.local/bin/skaffold`.
   - **`envsubst`**: If the system doesn't have `gettext`, it creates a lightweight Python wrapper in `${HOME}/.local/bin/envsubst` that behaves identically to the C binary.
3. **Enables 17 Critical GCP APIs**:
   Enables all services required for networking, serverless compute, AI, safety, and observability:
   - *Core*: `compute`, `storage`, `iam`, `serviceusage`, `cloudresourcemanager`
   - *Routing & Registry*: `dns`, `servicedirectory`, `artifactregistry`
   - *AI & Runtime*: `aiplatform`, `run`
   - *Gateway & Security*: `networkservices`, `networksecurity`, `iap`, `modelarmor`
   - *Observability*: `logging`, `monitoring`, `cloudtrace`
4. **Provisions GCS Terraform State Bucket**:
   - Checks if a state bucket named `<project_id>-tfstate` exists. If not, it creates it in `us-central1` with uniform bucket-level access.
5. **Auto-Generates Configurations**:
   - **`terraform/backend.conf`**: Configures the GCS bucket and prefix for remote state.
   - **`terraform/terraform.tfvars`**: Sets the project variables and adds your active `gcloud` email address as the initial `platform_admin_members` administrator.

### Usage
Run this script at the very beginning of the lab before executing any other commands:
```bash
chmod +x scripts/setup_lab.sh
./scripts/setup_lab.sh
```

---

## Script 2: `scripts/grant_agent_mcp_egress.sh` (Secure Egress Plane)

### Purpose
By default, the Agent Gateway blocks all agent egress requests under a zero-trust model. To allow your agent to call registered MCP servers or external endpoints, you must grant the agent's unique principal identity the IAP secured egress role (`roles/iap.egressor`) directly on those specific resources.

Because CLI commands like `gcloud beta iap web add-iam-policy-binding` do not yet support `--mcpServer` or `--endpoint` resource types, this script interacts directly with the Google Cloud REST APIs to perform atomic **Get-Merge-Set** IAM operations.

### What It Does (Step-by-Step)
1. **Determines the Agent's Secure Principal**:
   - If `--agent-id <ID>` is specified, it constructs the resource-specific Federated Identity principal:
     ```
     principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${AGENT_ID}
     ```
   - If `--bind-all-agents` is set, it targets the project-wide principal set:
     ```
     principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}
     ```
2. **Discovers Registered Resources via Agent Registry**:
   - Queries the Agent Registry API (`agentregistry.googleapis.com`) to retrieve all registered `mcpServers` and regional `endpoints` in `us-central1`.
   - Filters out resources if CLI substring filters (`--mcp-filter` or `--endpoints-filter`) are set.
3. **Performs Client-Side Atomic IAM Update**:
   For each discovered resource, it calls the IAP REST API:
   - **GET IAM Policy**: Fetches the existing IAM policy (requesting policy version 3 to support conditional bindings).
   - **Merge**: Merges the role `roles/iap.egressor` and the agent's principal, preserving all other bindings.
   - **SET IAM Policy**: Writes the updated policy back. If a condition is provided via `--condition-expression`, it attaches a CEL condition.

### Key Flags
- `--agent-id <ID>`: *Required (unless `--bind-all-agents` is passed)*. The numeric ID of the deployed Vertex AI reasoning engine.
- `--mcp` / `--endpoints`: Targets only MCP servers, only endpoints, or both (default).
- `--mcp-filter <string>`: Substring filter to selectively authorize specific tools.
- `--condition-expression <CEL>`: Optional CEL expression to restrict authorization (e.g., read-only tools).

### Usage
```bash
# Secure the egress plane for a specific agent
PROJECT_ID=<PROJECT_ID> \
PROJECT_NUMBER=<PROJECT_NUMBER> \
ORG_ID=<ORG_ID> \
REGION=us-central1 \
./scripts/grant_agent_mcp_egress.sh --agent-id <AGENT_ID>
```

---

## Script 3: `scripts/verify_lab.sh` (Progress Verification)

### Purpose
Acting as a localized "Check My Progress" Qwiklabs-style assessor, this script audits the active Google Cloud project to verify that the student has completed each module correctly. It provides real-time validation and actionable hints on failures.

### Technical Checks Performed
The script evaluates the six core stages of the architecture:

| Check | Stage Audited | Commands & Methods Used |
| :--- | :--- | :--- |
| **Check 1** | **Google Cloud APIs** | Audits `gcloud services list --enabled` to verify `compute`, `run`, `networkservices`, `networksecurity`, and `modelarmor` APIs are fully ready. |
| **Check 2** | **VPC & Subnets** | Verifies the custom VPC network `gateway-vpc` exists alongside the primary subnet `mcp-subnet-us-central1` and the dedicated `agent-coloc-agent-gateway-subnet`. |
| **Check 3** | **Cloud Run Servers** | Describes Cloud Run services (`legacy-dms`, `corporate-email`, `income-verification`) to ensure they are deployed and accessible in `us-central1`. |
| **Check 4** | **Model Armor** | Lists regional Model Armor templates. If `gcloud` fails due to regional restrictions, it safely falls back to inspecting the local Terraform state (`terraform state list`) for `google_model_armor_template`. |
| **Check 5** | **Agent Gateway** | Validates that the Resource Manager has successfully initialized the `agent-gateway` resource in `us-central1`. |
| **Check 6** | **Security Policies** | Verifies that both Identity-Aware Proxy (IAP) and Model Armor Service Authorization policies are actively bound to the gateway. |

### Diagnostic Output Example
If a check fails, the script outputs a customized **"Tip"** with the exact solution:
```
  [ FAIL ] Required Google Cloud APIs are enabled.
           Tip: Run 'gcloud services enable <api>' or ensure Terraform has been applied.
```

### Usage
```bash
./scripts/verify_lab.sh
```
A clean exit code `0` is returned only when all six checks are 100% successful.
