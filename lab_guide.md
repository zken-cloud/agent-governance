# Governing Agentic Workloads with Agent Gateway on Gemini Enterprise Agent Platform
## Hands-on Masterclass Lab Guide

---

## Overview & Lab Architecture

In this advanced hands-on lab, you will explore how to secure, govern, and audit enterprise AI agents calling internal tools (Model Context Protocol - MCP servers) deployed within Google Cloud. 

You will provision the foundational VPC networking, deploy three MCP servers to Cloud Run, run an Agent Development Kit (ADK) agent on Vertex AI Agent Runtime, and secure the egress paths using **Agent Gateway** integrated with **Identity-Aware Proxy (IAP)** and **Model Armor** content sanitization templates.

```mermaid
graph TD
    subgraph Gemini Enterprise [Gemini Enterprise Agent Platform]
        GE[Gemini Enterprise Client]
    end

    subgraph Agent Runtime [Vertex AI Agent Runtime]
        Agent[Mortgage Assistant ADK Agent]
        Registry[Agent Registry]
    end

    subgraph VPC [Customer VPC]
        direction TB
        LB[Internal Application LB / Agent Gateway]
        
        subgraph Cloud Run [MCP Servers on Cloud Run]
            DMS[Legacy Document Management DMS]
            Email[Corporate Email Server]
            Income[Income Verification API]
        end
    end

    subgraph Security Extensions [Agent Governance Plane]
        IAP[IAP Authz Extension: REQUEST_AUTHZ]
        MA[Model Armor Extension: CONTENT_AUTHZ]
    end

    GE -->|Interacts| Agent
    Agent -->|Discovers Tools via| Registry
    Agent -->|Egresses via PSC Interface| LB
    LB -->|Validates mTLS & IAM| IAP
    LB -->|Screens content| MA
    IAP -->|Authorized| Cloud Run
    MA -->|Sanitized| Cloud Run
```

---

## Lab Syllabus & Estimated Timings

| Module | Task Description | Est. Duration |
| :--- | :--- | :---: |
| **Setup** | Environment Bootstrapping & Script Execution | 10 Mins |
| **Module 1** | Provisioning Infrastructure via Terraform | 20 Mins |
| **Module 2** | Packaging & Deploying MCP Servers to Cloud Run | 15 Mins |
| **Module 3** | Deploying the Mortgage Assistant ADK Agent | 15 Mins |
| **Module 4** | Configuring Agent Gateway Service Extensions (IAP & Model Armor) | 15 Mins |
| **Module 5** | End-to-End Execution & Cloud Trace Audit | 15 Mins |

---

## Setup & Environment Bootstrapping (10 Mins)

### Step 1: Access Cloud Shell & Set Project Context
In the Google Cloud Console, click **Activate Cloud Shell** (the icon in the top right toolbar). 

If you are using a newly allocated or fresh GCP sandbox project, explicitly set your active configuration context in `gcloud`:

```bash
gcloud config set project <your-allocated-project-id>
```

Verify that the active account and project are correct:
```bash
gcloud config list
```

### Step 2: Navigate and Bootstrap
The lab files are located in your workspace directory. Run the following commands to navigate to the workspace and execute the custom bootstrap setup script:

```bash
cd /Users/zken/.gemini/antigravity/scratch/cloudnet-agent-gateway-lab
./scripts/setup_lab.sh
```

This bootstrap script automates several crucial steps:
1. Installs/upgrades prerequisites (`uv`, `skaffold`, `envsubst`).
2. Creates a centralized Terraform remote GCS state bucket named `<project-id>-tfstate`.
3. Populates `terraform/backend.conf` and `terraform/terraform.tfvars` automatically.
4. Auto-enables the complete suite of **17 Google Cloud APIs** required for the lab:
   * **Base & Core**: `compute.googleapis.com`, `serviceusage.googleapis.com`, `cloudresourcemanager.googleapis.com`, `iam.googleapis.com`, `storage.googleapis.com`
   * **Routing & DNS**: `dns.googleapis.com`, `servicedirectory.googleapis.com`
   * **Containers & Serverless**: `run.googleapis.com`, `artifactregistry.googleapis.com`
   * **Security, Gateway, and IAP**: `networkservices.googleapis.com`, `networksecurity.googleapis.com`, `iap.googleapis.com`
   * **GenAI & Safety**: `modelarmor.googleapis.com`, `aiplatform.googleapis.com`
   * **Observability**: `logging.googleapis.com`, `monitoring.googleapis.com`, `cloudtrace.googleapis.com`

> [!NOTE]
> The setup script will attempt to auto-detect your parent organization ID. If it is running in a standalone sandbox with no organization hierarchy, it will fall back to using a dummy value (`123456789012`). This is perfectly fine for the default public ingress path.


---

## Module 1: Provisioning Infrastructure via Terraform (20 Mins)

In this module, you will initialize and apply the Terraform configuration. This lays down the core secure networking (VPC, private subnets, co-located Agent Gateway subnet, PSC networks), artifact registries, and foundational governance primitives.

### Step 1: Initialize Terraform
Navigate to the `terraform` directory and initialize Terraform with the remote state backend generated in the setup step:

```bash
cd terraform
terraform init -backend-config=backend.conf
```

### Step 2: Apply the Configuration
Generate and execute the Terraform deployment plan:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

> [!IMPORTANT]
> The Terraform deployment provisions approximately 40 separate resources (including IAM bindings, VPC networks, Cloud NAT router, and Artifact Registry repository) and will take **8 to 10 minutes** to complete. Please let it finish without interruption.

---

## Module 2: Packaging & Deploying MCP Servers (15 Mins)

Our mortgage assistant agent requires three internal tools to perform underwriting. These are packaged as Model Context Protocol (MCP) servers:
1. **Legacy DMS (`legacy-dms`)**: Manages tax forms and property appraisal documents.
2. **Corporate Email (`corporate-email`)**: Handles sending out notifications to applicants and underwriters.
3. **Income Verification (`income-verification`)**: Validates payroll history and debt-to-income stats.

You will build and deploy these three servers onto Cloud Run using a declarative Skaffold pipeline.

### Step 1: Render the Skaffold Pipeline Configuration
Skaffold uses a templated pipeline configuration that needs to resolve your local GCP Project ID:

```bash
cd ..
envsubst < skaffold.yaml.tmpl > skaffold.yaml
```

### Step 2: Build and Deploy the Containers
Execute Skaffold to compile the container images, push them to your regional Artifact Registry repository, and deploy them as serverless Cloud Run services:

```bash
skaffold run
```

> [!TIP]
> Skaffold handles Docker compilation and Google Cloud Run v2 deployments on your behalf. Once deployed, run `gcloud run services list` to verify that all three services are up and active.

---

## Module 3: Deploying the Mortgage Assistant Agent (15 Mins)

With our tools running on Cloud Run, we will deploy the Mortgage Assistant ADK Agent (`mortgage-agent`) to Vertex AI Agent Runtime.

### Step 1: Understand Tool Discovery
Notice that you do not need to bake any hardcoded Cloud Run URLs into your agent code. Instead, the agent is configured to use **Vertex AI Agent Registry**. When the agent starts up, it queries the registry regional endpoint to discover active MCP tools dynamically.

### Step 2: Deploy the Agent
Run the ADK agent deployment command:

```bash
gcloud beta vertex-ai agents deploy mortgage-agent \
  --region=us-central1 \
  --agent-identity=mortgage-assistant-identity \
  --egress-psc-interface=agent-gateway-na
```

---

## Module 4: Configuring Agent Gateway Extensions (15 Mins)

Now, we will enforce security policies at the network boundary. The Agent Gateway acts as an egress proxy that intercepts calls from the agent before reaching internal tools. It evaluates two service authorization extensions:

1. **`REQUEST_AUTHZ` (Identity-Based Access via IAP)**: Validates that the calling agent's identity has the correct role (`roles/iap.egressor`) to call the target MCP service.
2. **`CONTENT_AUTHZ` (AI Safety Screening via Model Armor)**: Analyzes request/response content in-flight to screen for jailbreaks, prompt injections, and redact Social Security Numbers (PII).

### Step 1: Bind IAP Authorization Policy
Run the script to bind the agent's identity to the target IAP-enabled Cloud Run endpoints:

```bash
./scripts/grant_agent_mcp_egress.sh --agent-identity=mortgage-assistant-identity
```

### Step 2: Verify Policies are Active
Run the automated lab validation script to verify that your resources, gateway, safety templates, and authorization extensions are correctly provisioned:

```bash
./scripts/verify_lab.sh
```

---

## Module 5: End-to-End Execution & Audit Trail (15 Mins)

In this final module, you will test the complete mortgage underwriting workflow as an end user and audit the execution trace to see the Agent Gateway governance in action.

### Step 1: Trigger an Underwriting Task
Run the CLI harness to interact with the deployed Mortgage Assistant agent:

```bash
adk run mortgage-agent \
  --input="Underwrite application for John Doe. Access the DMS tax records, verify payroll history, and send an email update."
```

### Step 2: Inspect Safety Redaction
To test Model Armor's Sensitive Data Protection (SDP) in action, ask the agent to retrieve John Doe's tax documents:

```bash
adk run mortgage-agent \
  --input="Print the full content of John Doe's W-2 tax document from the DMS."
```

Notice in the output that John Doe's **Social Security Number (SSN)** is automatically replaced with `[REDACTED_SSN]` or `[INFO_TYPE_SSN]` before the response reaches the user!

### Step 3: Audit Traces on Google Cloud Console
1. In the GCP Console navigation menu, go to **Cloud Trace** > **Trace Explorer**.
2. Select your latest trace.
3. You will see a detailed execution graph mapping the hop-by-hop latency and security evaluations of:
   - Agent calling `legacy-dms`
   - Agent Gateway intercepting, executing `REQUEST_AUTHZ` via IAP (Dry Run or Enforced)
   - Agent Gateway executing `CONTENT_AUTHZ` via Model Armor
   - Request routing down to the Cloud Run server.

---

### Congratulations! You have successfully completed the Agent Gateway Masterclass Lab!
You have successfully built, governed, and audited a multi-tool ADK agent pipeline using Vertex AI Agent Runtime, Agent Gateway, and Model Armor safety extensions.
