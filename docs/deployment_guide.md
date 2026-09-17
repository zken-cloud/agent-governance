# End-to-End Deployment Guide: Agent Gateway & Governance

This document provides a detailed, step-by-step walkthrough for users to deploy the complete **Agent Gateway & Governance** demo from scratch. This guide assumes you are starting with a brand-new, empty Google Cloud Platform (GCP) project.

---

## High-Level Architecture Overview

By completing this guide, you will provision a secure, governed enterprise environment where an AI agent interacts with internal tools (MCP servers) via the **Agent Gateway**. The gateway intercepts all requests, enforcing **Identity-Aware Proxy (IAP)** egress restrictions and **Model Armor** AI safety filters.

```mermaid
graph TD
    subgraph Client [Gemini Enterprise]
        GE[User / Enterprise Client]
    end

    subgraph Agent Runtime [Vertex AI]
        Agent[Mortgage Assistant Agent]
        Registry[Agent Registry]
    end

    subgraph Corporate VPC [VPC Network]
        direction TB
        AGW[Agent Gateway Proxy Subnet]
        
        subgraph Cloud Run [Internal Tools]
            DMS[Legacy DMS Server]
            Email[Corporate Email Server]
            Income[Income Verification API]
        end
    end

    subgraph Security Plane [Governance Service Extensions]
        IAP[IAP Egress authz]
        MA[Model Armor content filter]
    end

    GE -->|Invokes| Agent
    Agent -->|Discovers tools from| Registry
    Agent -->|Egress requests| AGW
    AGW -->|Evaluates IAM| IAP
    AGW -->|Redacts PII / Jailbreaks| MA
    IAP -->|Authorized| Cloud Run
    MA -->|Sanitized| Cloud Run
```

---

## Detailed Deployment Steps

### Phase 1: Authentication & Local Machine Setup

1. **Clone the Repository**:
   Clone the repository containing the lab files and navigate to the project directory:
   ```bash
   git clone https://github.com/zken-cloud/agent-governance.git
   cd agent-governance
   ```

2. **Authenticate with Google Cloud**:
   Authenticate your local `gcloud` shell. This allows the provisioning scripts and Terraform to execute commands on your behalf:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

3. **Set Project Context**:
   Set your active project context to the brand-new Google Cloud project allocated for this demo:
   ```bash
   gcloud config set project <PROJECT_ID>
   ```

---

### Phase 2: Environment Bootstrapping

We use a custom bootstrap script to enable necessary services, install client tools locally (avoiding system password requirements), and configure remote storage for your Terraform state.

1. **Run the Setup Script**:
   Execute the setup script from the root directory:
   ```bash
   chmod +x scripts/setup_lab.sh
   ./scripts/setup_lab.sh
   ```

2. **What happens behind the scenes?**
   - **Prerequisites**: Installs the `uv` package manager, the `skaffold` binary, and a Python fallback utility for `envsubst` to your local user space (`${HOME}/.local/bin`).
   - **GCP APIs**: Automatically enables **17 required services** (including `aiplatform`, `modelarmor`, `networkservices`, `run`, `iap`, etc.).
   - **State Bucket**: Dynamically provisions a GCS bucket named `<project-id>-tfstate` inside the `us-central1` region.
   - **IaC Configuration**: Automatically writes your project configuration to `terraform/terraform.tfvars` and registers your active GCP account as an administrator.

---

### Phase 3: Infrastructure Provisioning (Terraform)

Now, you will use Terraform to deploy the secure networking foundation and Agent Gateway control planes.

1. **Navigate and Initialize**:
   Change directories to the `terraform` folder and initialize the Terraform engine using the remote GCS state configuration generated in Phase 2:
   ```bash
   cd terraform
   terraform init -backend-config=backend.conf
   ```

2. **Apply the Configuration**:
   Run the apply command to provision the resources. Type `yes` when prompted, or run:
   ```bash
   terraform apply -auto-approve
   ```

> [!IMPORTANT]
> This stage creates VPC networks, subnets, routers, network attachments, Model Armor safety templates, and the Agent Gateway resource. It will take approximately **8 to 10 minutes** to complete. Do not cancel the execution.

3. **Return to the Root Directory**:
   Once Terraform finishes successfully, return to the repository root:
   ```bash
   cd ..
   ```

---

### Phase 4: Deploying MCP Servers (Cloud Run)

The demo utilizes three Model Context Protocol (MCP) servers representing legacy internal backend applications:
- **`legacy-dms`**: A document management system housing applicant forms.
- **`corporate-email`**: An SMTP/email engine for communication.
- **`income-verification`**: An API verifying employment and payroll data.

1. **Render the Container Deployment Pipeline**:
   The Cloud Run deployment pipeline uses a templated config (`skaffold.yaml.tmpl`) that needs your active project ID resolved. Render the working file:
   ```bash
   export PROJECT_ID=$(gcloud config get-value project)
   envsubst < skaffold.yaml.tmpl > skaffold.yaml
   ```

2. **Compile and Deploy via Skaffold**:
   Run Skaffold to compile the container images, publish them to your Artifact Registry, and deploy them securely to Cloud Run:
   ```bash
   skaffold run
   ```

3. **Verify Deployments**:
   Ensure all three services are active on Cloud Run:
   ```bash
   gcloud run services list --region=us-central1
   ```

---

### Phase 5: Deploying and Registering the ADK Agent

We will deploy a lightweight "Hello World" Python agent to Vertex AI Agent Runtime to act as our intelligent mortgage assistant.

1. **Navigate to the Agent Module**:
   ```bash
   cd src/hello-world-agent
   ```

2. **Synchronize Python Environment**:
   Use `uv` to resolve and pull down package dependencies securely:
   ```bash
   uv sync --default-index https://pypi.org/simple --prerelease=allow
   ```

3. **Deploy the Agent**:
   Deploy the ADK agent to Vertex AI Reasoning Engines:
   ```bash
   uv run agents-cli deploy
   ```

4. **Capture the Deployed Agent ID**:
   The deployment output will display a numeric reasoning engine ID (e.g., `8785940681592930304`). **Write this ID down!** You will need it in the next phase.

5. **Return to the Repository Root**:
   ```bash
   cd ../..
   ```

---

### Phase 6: Securing the Egress Plane (Policy Bindings)

By default, zero-trust policies block your newly deployed agent from communicating with the MCP tools. We must explicitly authorize your agent to egress through the Agent Gateway.

Run the egress grant script using the active project context and your **Agent ID** captured in Phase 5:
```bash
PROJECT_ID=<PROJECT_ID> \
PROJECT_NUMBER=<PROJECT_NUMBER> \
ORG_ID=<ORG_ID> \
REGION=us-central1 \
./scripts/grant_agent_mcp_egress.sh --agent-id <YOUR_DEPLOYED_AGENT_ID>
```

This discovers all MCP servers inside the registry and modifies their individual Identity-Aware Proxy (IAP) policies to authorize your agent's unique Federated Identity.

---

### Phase 7: End-to-End Progress Assessment

Ensure your deployment is fully operational. Run the localized validation suite:
```bash
./scripts/verify_lab.sh
```

A successful deployment will output a perfect **6/6 Checks Passed**!

---

## Where are the Policies? (Console Explanation)

After running the egress policy scripts, you might go to **Govern** -> **Policies** -> **IAM Allow** in the Google Cloud Console and find that the table shows **"No rows to display"**:

![IAM Allow Empty](file:///Users/zken/.gemini/antigravity/brain/17d262d8-8d63-430b-80d2-3750fdd9266c/media__1783369950816.png)

### Why is this table empty?
The global **IAM Allow** page in the console only displays **project-level/global** security policies. 

Our script enforces a strict zero-trust model by binding IAM policies directly to **individual, fine-grained resources** (the 3 separate MCP servers and 56 regional endpoints) within the regional **Agent Registry**, rather than applying them globally to the entire project.

### How to verify your policies in the Console:
1. Open the GCP Console and go to **Govern** -> **Agent Registry**:
   [https://console.cloud.google.com/agent-platform/registry?project=<PROJECT_ID>](https://console.cloud.google.com/agent-platform/registry?project=<PROJECT_ID>)
2. Select the **MCP Servers** tab.
3. Click on any server (e.g., `corporate-email`).
4. In the detailed panel on the right side of the screen, open the **Permissions** panel.
5. You will see your agent's secure Federated Identity principal listed with the **IAP Secured Web App User** (`roles/iap.egressor`) role!

This verifies that your micro-segmented egress security plane is active and functioning perfectly.
