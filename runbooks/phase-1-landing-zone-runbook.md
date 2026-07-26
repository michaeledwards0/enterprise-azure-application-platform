<div align="center">

# Workstream 1 Runbook: Enterprise Landing Zone
### Remote Terraform State, Resource Organization, Governance Standards, and Python Tag Compliance

</div>

---

## Purpose

This runbook builds the foundation for the Enterprise Azure Application Platform.

You will:

1. Prepare the local workstation and Azure subscription.
2. Create the repository structure.
3. Define naming and tagging standards.
4. Bootstrap an Azure Storage backend for Terraform state.
5. Create Terraform files for the development landing zone.
6. Deploy four purpose-built resource groups.
7. Validate remote state and configuration consistency.
8. Run a Python automation that audits required tags and exports a CSV report.
9. Capture portfolio evidence without exposing sensitive information.

> **Deployment model:** Azure CLI is used only to bootstrap the remote backend. Terraform manages the landing-zone resources after the backend exists.

> **Simple distinction:** The Terraform backend is the resource group, storage account, and container that store Terraform state. The landing zone is the organized Azure foundation that Terraform deploys for the platform.


---

## Target Resources

| Resource | Suggested Name | Purpose |
|---|---|---|
| Backend resource group | `rg-eaap-tfstate-dev` | Holds Terraform state infrastructure |
| Storage account | `steaaptfstatedev<suffix>` | Stores remote Terraform state |
| Blob container | `tfstate` | Holds environment state blobs |
| Platform resource group | `rg-eaap-platform-dev` | Shared platform services |
| Network resource group | `rg-eaap-network-dev` | Network and private connectivity resources |
| Operations resource group | `rg-eaap-operations-dev` | Monitoring, automation, backup, and operations |
| Workload resource group | `rg-eaap-workload-dev` | Application workloads and test resources |

The examples use **South Central US** (`southcentralus`) and the abbreviation `scus`. Change both values consistently if another region is required.

---

## Prerequisites

Install and verify:

- Git
- Azure CLI
- Terraform
- Python 3.10 or later
- Visual Studio Code or another code editor
- An Azure subscription where you have permission to create resource groups, storage accounts, and resources

Run:

```bash
az version
terraform version
python --version
git --version
```

### Recommended Terraform Version

Use a current Terraform 1.x release. The configuration below requires Terraform `>= 1.6.0` and `< 2.0.0`.

---

## Step 1 — Clone or Create the Repository

Create the project folder:

```bash
mkdir Enterprise-Azure-Application-Platform
cd Enterprise-Azure-Application-Platform
git init
```

Create the initial folder structure:

```bash
mkdir -p docs/phase-1-landing-zone
mkdir -p runbooks
mkdir -p terraform/environments/dev
mkdir -p automation/tag-compliance/reports
mkdir -p screenshots/phase-1
```

> **Windows PowerShell:** If `mkdir -p` is unavailable, create the folders individually with `New-Item -ItemType Directory -Force -Path <path>`.

Copy the supplied files into their matching repository paths.

---

## Step 2 — Create the Repository `.gitignore`

At the repository root, create `.gitignore`:

```gitignore
# Terraform working directories
**/.terraform/*

# Terraform state
*.tfstate
*.tfstate.*

# Terraform plan files
*.tfplan
*.plan

# Terraform variable and backend files that can contain environment data
*.tfvars
!*.tfvars.example
backend.hcl
!backend.hcl.example

# Terraform crash and override files
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Terraform CLI configuration
.terraformrc
terraform.rc

# Python
__pycache__/
*.py[cod]
.venv/
venv/
.env

# Generated automation reports
automation/**/reports/*.csv
automation/**/reports/*.json
automation/**/reports/*.md

# IDE and operating system files
.vscode/
.idea/
.DS_Store
Thumbs.db
```

Validate that sensitive Terraform files will not be committed later:

```bash
git status
```

---

## Step 3 — Authenticate to Azure

Sign in:

```bash
az login
```

List available subscriptions:

```bash
az account list --output table
```

Set the correct subscription:

```bash
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

Confirm the active context:

```bash
az account show --output table
```

Store the subscription ID in your current shell.

### Bash

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_SUBSCRIPTION_ID=$ARM_SUBSCRIPTION_ID
```

### PowerShell

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

Do not paste the subscription ID into public screenshots.

---

## Step 4 — Define Project Variables

### Bash

```bash
export LOCATION="southcentralus"
export LOCATION_SHORT="scus"
export ENVIRONMENT="dev"
export PROJECT_SHORT="eaap"
export TFSTATE_RG="rg-eaap-tfstate-dev"
export TFSTATE_CONTAINER="tfstate"
export RANDOM_SUFFIX=$(printf '%04d' $((RANDOM % 10000)))
export TFSTATE_SA="steaaptfstatedev${RANDOM_SUFFIX}"
```

Confirm the generated storage account name:

```bash
echo "$TFSTATE_SA"
```

### PowerShell

```powershell
$env:LOCATION = "southcentralus"
$env:LOCATION_SHORT = "scus"
$env:ENVIRONMENT = "dev"
$env:PROJECT_SHORT = "eaap"
$env:TFSTATE_RG = "rg-eaap-tfstate-dev"
$env:TFSTATE_CONTAINER = "tfstate"
$randomSuffix = Get-Random -Minimum 1000 -Maximum 9999
$env:TFSTATE_SA = "steaaptfstatedev$randomSuffix"
```

Confirm:

```powershell
$env:TFSTATE_SA
```

> Azure Storage account names must be globally unique, 3–24 characters, and use lowercase letters and numbers only.


### PowerShell Session Restart Notes

PowerShell variables only exist in the current PowerShell session. If PowerShell is closed and reopened, return to the repository and recreate the variables before continuing.

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"

az account show --query "{Name:name,State:state,IsDefault:isDefault}" --output table

$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID

$env:LOCATION = "southcentralus"
$env:LOCATION_SHORT = "scus"
$env:ENVIRONMENT = "dev"
$env:PROJECT_SHORT = "eaap"
$env:TFSTATE_RG = "rg-eaap-tfstate-dev"
$env:TFSTATE_CONTAINER = "tfstate"
$env:TFSTATE_SA = "<EXISTING_STORAGE_ACCOUNT_NAME>"
```

Do not generate a new storage-account name after the backend has already been created. Reuse the existing name.

Variables such as `$myPublicIp` and `$policyAssignmentId` also disappear when PowerShell closes. Recreate them only when the related task requires them.

Installed tools, repository files, Git configuration, Terraform files, and the `.venv` folder remain on the computer. Terraform does not need to be activated. The Python virtual environment must be reactivated only when performing Python work.

---

## Step 5 — Bootstrap the Terraform Backend

The backend is created with Azure CLI because Terraform cannot store state in a backend that does not exist yet.

The storage account uses this network design:

```text
Public network access: Enabled
Firewall default action: Deny
Approved workstation public IP: Allow
Anonymous blob access: Disabled
```

This keeps the storage firewall compliant with a policy that requires traffic to be denied by default while still allowing the engineer's approved public IP.

### 5.1 Create the Backend Resource Group

#### Bash

```bash
az group create \
  --name "$TFSTATE_RG" \
  --location "$LOCATION" \
  --tags \
    Project="Enterprise-Azure-Application-Platform" \
    Environment="$ENVIRONMENT" \
    ManagedBy="Bootstrap-AzureCLI" \
    Owner="Cloud-Platform-Team" \
    CostCenter="Platform-Engineering" \
    DataClassification="Internal" \
    Criticality="High"
```

#### PowerShell

```powershell
az group create `
  --name "$env:TFSTATE_RG" `
  --location "$env:LOCATION" `
  --tags `
    Project="Enterprise-Azure-Application-Platform" `
    Environment="$env:ENVIRONMENT" `
    ManagedBy="Bootstrap-AzureCLI" `
    Owner="Cloud-Platform-Team" `
    CostCenter="Platform-Engineering" `
    DataClassification="Internal" `
    Criticality="High"
```

### 5.2 Create the Storage Account

#### Bash

```bash
az storage account create \
  --name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --https-only true \
  --public-network-access Enabled \
  --default-action Deny \
  --tags \
    Project="Enterprise-Azure-Application-Platform" \
    Environment="$ENVIRONMENT" \
    ManagedBy="Bootstrap-AzureCLI" \
    Owner="Cloud-Platform-Team" \
    CostCenter="Platform-Engineering" \
    DataClassification="Internal" \
    Criticality="High"
```

#### PowerShell

```powershell
az storage account create `
  --name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --location "$env:LOCATION" `
  --sku Standard_LRS `
  --kind StorageV2 `
  --min-tls-version TLS1_2 `
  --allow-blob-public-access false `
  --https-only true `
  --public-network-access Enabled `
  --default-action Deny `
  --tags `
    Project="Enterprise-Azure-Application-Platform" `
    Environment="$env:ENVIRONMENT" `
    ManagedBy="Bootstrap-AzureCLI" `
    Owner="Cloud-Platform-Team" `
    CostCenter="Platform-Engineering" `
    DataClassification="Internal" `
    Criticality="High"
```

Simple meaning:

> Create the storage account, deny network traffic by default, and allow access only through approved network rules.

### 5.3 Allow the Current Workstation Public IP

#### Bash

```bash
MY_PUBLIC_IP=$(curl -s https://api.ipify.org)

az storage account network-rule add \
  --account-name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --ip-address "$MY_PUBLIC_IP" \
  --action Allow
```

#### PowerShell

```powershell
$myPublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Write-Host $myPublicIp

az storage account network-rule add `
  --account-name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --ip-address "$myPublicIp" `
  --action Allow
```

Simple meaning:

> Block all public traffic by default, then allow only the engineer's current public IP.

The public IP may change after restarting the router, changing networks, or connecting to a VPN. If it changes, add the new IP rule and remove the old rule after confirming access.

### 5.4 Assign Blob Data Access When Required

Creating Azure resources and reading blob data use different permissions. If container creation returns an authorization error, assign **Storage Blob Data Contributor** to the signed-in user at the storage-account scope.

#### Bash

```bash
TFSTATE_SA_ID=$(az storage account show \
  --name "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" \
  --query id -o tsv)

SIGNED_IN_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --assignee-object-id "$SIGNED_IN_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$TFSTATE_SA_ID"
```

#### PowerShell

```powershell
$tfstateSaId = az storage account show `
  --name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query id `
  -o tsv

$signedInObjectId = az ad signed-in-user show --query id -o tsv

az role assignment create `
  --assignee-object-id "$signedInObjectId" `
  --assignee-principal-type User `
  --role "Storage Blob Data Contributor" `
  --scope "$tfstateSaId"
```

Wait two to five minutes for role propagation.

### 5.5 Create the Private Blob Container

#### Bash

```bash
az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_SA" \
  --auth-mode login
```

#### PowerShell

```powershell
az storage container create `
  --name "$env:TFSTATE_CONTAINER" `
  --account-name "$env:TFSTATE_SA" `
  --auth-mode login
```

### 5.6 Validate the Storage Account

#### PowerShell

Keep the JMESPath query on one line inside quotation marks.

```powershell
az storage account show `
  --name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query "{Name:name,ProvisioningState:provisioningState,PublicNetworkAccess:publicNetworkAccess,DefaultAction:networkRuleSet.defaultAction,HttpsOnly:enableHttpsTrafficOnly,MinimumTLS:minimumTlsVersion,BlobPublicAccess:allowBlobPublicAccess}" `
  --output table
```

Expected values:

```text
ProvisioningState     Succeeded
PublicNetworkAccess   Enabled
DefaultAction         Deny
HttpsOnly             True
MinimumTLS            TLS1_2
BlobPublicAccess      False
```

### 5.7 Validate the Network Rule

```powershell
az storage account network-rule list `
  --account-name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query "ipRules[].{IPAddress:ipAddressOrRange,Action:action}" `
  --output table
```

Confirm the firewall default action:

```powershell
az storage account network-rule list `
  --account-name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query "defaultAction" `
  --output tsv
```

Expected:

```text
Deny
```

### 5.8 Validate the Container

```powershell
az storage container list `
  --account-name "$env:TFSTATE_SA" `
  --auth-mode login `
  --query "[].{Name:name,PublicAccess:properties.publicAccess}" `
  --output table
```

Expected:

```text
Name      PublicAccess
--------  ------------
tfstate   None
```

> A management-group policy named **Deny Public Storage Accounts — MG Level** was satisfied by setting the firewall default action to `Deny` and allowing only the workstation IP. No additional policy exemption was required for that assignment.

---

## Step 6 — Create the Terraform Backend Configuration

Move into the environment directory:

```bash
cd terraform/environments/dev
```

Create `backend.hcl.example`:

```hcl
resource_group_name  = "rg-eaap-tfstate-dev"
storage_account_name = "REPLACE_WITH_UNIQUE_STORAGE_ACCOUNT_NAME"
container_name       = "tfstate"
key                  = "eaap/dev/landing-zone.tfstate"
use_azuread_auth     = true
```

Copy it to the ignored environment file:

```bash
cp backend.hcl.example backend.hcl
```

Update `backend.hcl` with the actual storage account name.

### Bash replacement

```bash
sed -i "s/REPLACE_WITH_UNIQUE_STORAGE_ACCOUNT_NAME/$TFSTATE_SA/" backend.hcl
```

### PowerShell replacement

```powershell
(Get-Content backend.hcl) `
  -replace 'REPLACE_WITH_UNIQUE_STORAGE_ACCOUNT_NAME', $env:TFSTATE_SA |
  Set-Content backend.hcl
```

Review the file:

```bash
cat backend.hcl
```

Do not commit the completed `backend.hcl` file.

---

## Step 7 — Create the Terraform Files

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}
```

### `backend.tf`

```hcl
terraform {
  backend "azurerm" {}
}
```

### `providers.tf`

```hcl
provider "azurerm" {
  features {}

  resource_provider_registrations = "core"
}
```

> If a later phase requires a resource provider outside the core set, explicitly register it or adjust the provider configuration deliberately rather than enabling broad behavior without review.

### `variables.tf`

```hcl
variable "location" {
  description = "Primary Azure region for the development environment."
  type        = string
  default     = "southcentralus"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be dev, test, or prod."
  }
}

variable "project_name" {
  description = "Long-form project name used in tags."
  type        = string
  default     = "Enterprise-Azure-Application-Platform"
}

variable "owner" {
  description = "Operational owner applied to Azure tags."
  type        = string
  default     = "Cloud-Platform-Team"
}

variable "cost_center" {
  description = "Cost allocation value applied to Azure tags."
  type        = string
  default     = "Platform-Engineering"
}

variable "data_classification" {
  description = "Baseline data classification."
  type        = string
  default     = "Internal"
}

variable "criticality" {
  description = "Operational criticality for the environment."
  type        = string
  default     = "Medium"
}
```

### `locals.tf`

```hcl
locals {
  common_tags = {
    Project            = var.project_name
    Environment        = var.environment
    ManagedBy          = "Terraform"
    Owner              = var.owner
    CostCenter         = var.cost_center
    DataClassification = var.data_classification
    Criticality        = var.criticality
  }

  resource_groups = {
    platform = "rg-eaap-platform-${var.environment}"
    network  = "rg-eaap-network-${var.environment}"
    operations = "rg-eaap-operations-${var.environment}"
    workload = "rg-eaap-workload-${var.environment}"
  }
}
```

### `main.tf`

```hcl
resource "azurerm_resource_group" "landing_zone" {
  for_each = local.resource_groups

  name     = each.value
  location = var.location

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = title(each.key)
    }
  )
}
```

### `outputs.tf`

```hcl
output "resource_group_names" {
  description = "Landing-zone resource groups by purpose."
  value = {
    for purpose, resource_group in azurerm_resource_group.landing_zone :
    purpose => resource_group.name
  }
}

output "resource_group_ids" {
  description = "Landing-zone resource group IDs by purpose."
  value = {
    for purpose, resource_group in azurerm_resource_group.landing_zone :
    purpose => resource_group.id
  }
}

output "common_tags" {
  description = "Required tags applied by the landing-zone configuration."
  value       = local.common_tags
}
```

### `terraform.tfvars.example`

```hcl
location            = "southcentralus"
environment         = "dev"
project_name        = "Enterprise-Azure-Application-Platform"
owner               = "Cloud-Platform-Team"
cost_center         = "Platform-Engineering"
data_classification = "Internal"
criticality         = "Medium"
```

Copy the example to the ignored working file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Review the directory:

```bash
ls -la
```

Expected files:

```text
backend.hcl
backend.hcl.example
backend.tf
locals.tf
main.tf
outputs.tf
providers.tf
terraform.tfvars
terraform.tfvars.example
versions.tf
variables.tf
```

---

## Step 8 — Format and Validate Terraform

Format the configuration:

```bash
terraform fmt -recursive
```

Initialize the backend:

```bash
terraform init -backend-config=backend.hcl
```

Validate the configuration:

```bash
terraform validate
```

Expected result:

```text
Success! The configuration is valid.
```

---

## Step 9 — Create and Review the Terraform Plan

Create a saved plan:

```bash
terraform plan -out=phase1.tfplan
```

Review the plan carefully:

```bash
terraform show phase1.tfplan
```

Confirm that Terraform plans to create only the four expected resource groups.

Do not apply the plan if unexpected resources, regions, names, or destructive actions appear.

---

## Step 10 — Deploy the Landing Zone

Apply the reviewed plan:

```bash
terraform apply phase1.tfplan
```

Display outputs:

```bash
terraform output
```

List the deployed resource groups:

```bash
az group list \
  --query "[?starts_with(name, 'rg-eaap-')].[name,location,tags.ManagedBy,tags.Environment]" \
  --output table
```

---

## Step 11 — Validate Remote State

List state objects from Terraform:

```bash
terraform state list
```

Expected resources:

```text
azurerm_resource_group.landing_zone["network"]
azurerm_resource_group.landing_zone["operations"]
azurerm_resource_group.landing_zone["platform"]
azurerm_resource_group.landing_zone["workload"]
```

List blobs in the backend container:

```bash
az storage blob list \
  --account-name "$TFSTATE_SA" \
  --container-name "$TFSTATE_CONTAINER" \
  --auth-mode login \
  --output table
```

Confirm that the state key exists:

```text
eaap/dev/landing-zone.tfstate
```

Verify the exact blob directly.

### PowerShell

```powershell
az storage blob exists `
  --account-name "$env:TFSTATE_SA" `
  --container-name "$env:TFSTATE_CONTAINER" `
  --name "eaap/dev/landing-zone.tfstate" `
  --auth-mode login `
  --output table
```

Expected:

```text
Exists
------
True
```

Simple meaning:

> Check whether the `tfstate` container contains the blob named `eaap/dev/landing-zone.tfstate`.

Do not download or upload the state file to GitHub.

---

## Step 12 — Validate Resource Tags

Inspect one resource group:

```bash
az group show \
  --name "rg-eaap-platform-dev" \
  --query "{name:name,location:location,tags:tags}" \
  --output json
```

Confirm the required tags are present:

- `Project`
- `Environment`
- `ManagedBy`
- `Owner`
- `CostCenter`
- `DataClassification`
- `Criticality`

Terraform also applies `ResourcePurpose` to each landing-zone resource group.

---

## Step 13 — Confirm Idempotency

Run another plan:

```bash
terraform plan
```

Expected result:

```text
No changes. Your infrastructure matches the configuration.
```

A clean plan is important evidence that Terraform state and Azure resources are synchronized.

---

## Step 14 — Prepare the Python Environment

Return to the repository root:

```bash
cd ../../..
```

Move into the automation folder:

```bash
cd automation/tag-compliance
```

Create a virtual environment:

```bash
python -m venv .venv
```

Activate it.

### Bash

```bash
source .venv/bin/activate
```

### PowerShell

```powershell
.\.venv\Scripts\Activate.ps1
```

Upgrade pip and install dependencies:

```bash
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Confirm authentication is still valid:

```bash
az account show --output table
```

Set the subscription environment variable if the shell was restarted.

### Bash

```bash
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

### PowerShell

```powershell
$env:AZURE_SUBSCRIPTION_ID = az account show --query id -o tsv
```

---

## Step 15 — Run the Python Tag-Compliance Report

Run the script:

```bash
python tag_compliance_report.py --include-resource-groups
```

The script evaluates the live subscription against these tags:

```text
Project
Environment
ManagedBy
Owner
CostCenter
DataClassification
Criticality
```

Expected terminal behavior:

```text
Azure Tag Compliance Summary
===============================
Resources evaluated : <number>
Compliant resources : <number>
Noncompliant         : <number>
Compliance rate      : <percentage>%
CSV report           : <local path>
```

The script returns:

- Exit code `0` when all evaluated resources are compliant
- Exit code `1` when authentication, configuration, or the Resource Graph query fails
- Exit code `2` when the query succeeds but noncompliant resources are found

A nonzero result caused by missing tags is expected in a shared subscription containing resources from other projects.

To generate evidence without failing the terminal session on noncompliance:

```bash
python tag_compliance_report.py \
  --include-resource-groups \
  --no-fail-on-noncompliance
```

Open the generated CSV in Excel or Visual Studio Code:

```text
automation/tag-compliance/reports/azure-tag-compliance-<timestamp>.csv
```

Do not commit generated reports unless they have been reviewed for subscription IDs, resource IDs, or other environment details. The repository `.gitignore` excludes them by default.

---

## Step 16 — Optional Scope Reduction for Cleaner Evidence

The supplied script queries the entire active subscription. In a shared subscription, unrelated resources may lower the compliance percentage.

For recruiter-facing evidence, keep the full report as an operational test, but filter the CSV to show the `rg-eaap-*` resources. Do not modify the compliance result to imply that unrelated resources were compliant.

A later enhancement can add a `--resource-group-prefix rg-eaap-` argument or a project-tag filter.

---

## Step 17 — Capture Evidence

Create screenshots for the Phase 1 evidence section.

### Screenshot 1 — Backend Resource Group

Azure portal path:

```text
Resource groups > rg-eaap-tfstate-dev > Overview
```

Capture the resource group name, region, and resource list.

### Screenshot 2 — State Storage Account and Container

Azure portal path:

```text
Storage accounts > <state-storage-account> > Data storage > Containers > tfstate
```

Do not expose access keys.

### Screenshot 3 — State Blob

Capture the blob path:

```text
eaap/dev/landing-zone.tfstate
```

Do not download or display state contents.

### Screenshot 4 — Terraform Apply

Capture the terminal summary showing:

```text
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
```

### Screenshot 5 — Landing-Zone Resource Groups

Capture the Azure resource-group list filtered to `rg-eaap-`.

### Screenshot 6 — Resource Tags

Open `rg-eaap-platform-dev` and capture the Tags blade.

### Screenshot 7 — Clean Plan

Capture:

```text
No changes. Your infrastructure matches the configuration.
```

### Screenshot 8 — Python Compliance Summary

Capture the script's terminal summary.

### Screenshot 9 — CSV Report

Open the CSV and capture columns such as resource name, type, compliance status, and missing tags. Hide or crop resource IDs if desired.

Save screenshots under:

```text
screenshots/phase-1/
```

Recommended names:

```text
01-backend-resource-group.png
02-state-storage.png
03-state-blob.png
04-terraform-apply.png
05-resource-groups.png
06-resource-tags.png
07-clean-plan.png
08-python-report.png
09-compliance-csv.png
```

---

## Step 18 — Update the Case Study Evidence Links

Replace the code-formatted placeholders in:

```text
docs/phase-1-landing-zone/README.md
```

Example replacement:

```markdown
![Terraform backend resource group](../../screenshots/phase-1/01-backend-resource-group.png)
```

GitHub will render repository-relative image paths automatically.

---

## Step 19 — Commit the Completed Workstream

Return to the repository root:

```bash
cd ../..
```

Review pending files:

```bash
git status
```

Confirm that these files are **not** staged:

- `backend.hcl`
- `terraform.tfvars`
- `.terraform/`
- `*.tfstate`
- `*.tfplan`
- `.venv/`
- Generated CSV reports

Stage the safe project files:

```bash
git add README.md .gitignore docs runbooks terraform automation screenshots
```

Review the staged changes:

```bash
git diff --cached
```

Commit:

```bash
git commit -m "Complete Workstream 1 enterprise landing zone"
```

Push to GitHub after connecting the repository remote.

---

## Validation Checklist

- [ ] Correct Azure subscription selected
- [ ] Backend resource group created
- [ ] Storage account created with HTTPS-only and TLS 1.2 minimum
- [ ] Storage firewall default action set to `Deny`
- [ ] Current workstation public IP added as an `Allow` network rule
- [ ] Anonymous blob access disabled
- [ ] Private `tfstate` container created
- [ ] Terraform initialized against Azure Blob Storage
- [ ] `terraform validate` succeeded
- [ ] Plan showed only the expected resources
- [ ] Four landing-zone resource groups deployed
- [ ] Required tags applied
- [ ] Terraform state blob exists remotely
- [ ] Second Terraform plan showed no changes
- [ ] Python dependencies installed in a virtual environment
- [ ] Python report queried the active subscription
- [ ] CSV report generated
- [ ] Screenshots captured and sanitized
- [ ] Sensitive local files excluded from Git

---

## Troubleshooting

### `terraform init` returns 403 or authorization errors

Confirm:

1. The correct subscription is active.
2. The storage account name in `backend.hcl` is correct.
3. Your identity has `Storage Blob Data Contributor` on the storage account or container.
4. Role assignment propagation has completed.
5. `use_azuread_auth = true` is present in `backend.hcl`.

Then rerun:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

### Storage account creation is denied by policy

Read the policy violation details instead of relying only on the assignment display name.

If the error shows:

```text
Microsoft.Storage/storageAccounts/networkAcls.defaultAction
NotEquals
Deny
```

the policy requires the storage firewall default action to be `Deny`. Create the storage account with:

```text
--public-network-access Enabled
--default-action Deny
```

Then add the engineer's public IP as an explicit network rule. This satisfies the policy without creating another exemption.

### Storage access fails after changing networks or using a VPN

Retrieve the current public IP:

```powershell
$myPublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Write-Host $myPublicIp
```

List existing rules:

```powershell
az storage account network-rule list `
  --account-name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query "ipRules[].{IPAddress:ipAddressOrRange,Action:action}" `
  --output table
```

Add the current IP when it is missing:

```powershell
az storage account network-rule add `
  --account-name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --ip-address "$myPublicIp" `
  --action Allow
```

### PowerShell displays the `>>` continuation prompt

The `>>` prompt means PowerShell is waiting for the rest of an unfinished command. This is usually caused by an unmatched quotation mark, brace, parenthesis, or a backtick.

Press:

```text
Ctrl + C
```

Return to the normal `PS C:\...>` prompt, then rerun the command.

A PowerShell backtick must be the final character on the line. Do not add a space after it.

### Azure CLI reports `invalid jmespath_type value: '{'`

Keep the complete `--query` value on one line inside quotation marks:

```powershell
--query "{Name:name,ProvisioningState:provisioningState,DefaultAction:networkRuleSet.defaultAction}"
```

Do not split the object query across multiple lines inside the quotation marks.

### Storage account name is unavailable

Generate another four-digit suffix and recreate only the storage account command with the new name.

### Resource provider registration error

Register the required provider explicitly:

```bash
az provider register --namespace Microsoft.Resources
az provider register --namespace Microsoft.Storage
```

Check status:

```bash
az provider show --namespace Microsoft.Storage --query registrationState -o tsv
```

### Python reports `CredentialUnavailableError`

Run:

```bash
az login
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

Then verify:

```bash
az account get-access-token --output none
```

Rerun the script.

### Python reports that no subscription ID was provided

Set the variable:

```bash
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

Or pass it directly without committing it:

```bash
python tag_compliance_report.py \
  --subscription-id "<SUBSCRIPTION_ID>" \
  --include-resource-groups
```

### Python returns exit code 2

The query worked, but one or more resources are missing required tags. Review the generated CSV. Use `--no-fail-on-noncompliance` when you need a report without a failing process exit code.

### `terraform plan` shows unexpected tag changes

Check whether tags were modified manually in the portal. Terraform will attempt to restore the configured values. Decide whether the portal change or the code is authoritative, then update the correct source.

### State lock remains after an interrupted operation

First confirm that no other Terraform process is running. Terraform normally releases locks automatically. Use force-unlock only when you have confirmed the lock is stale:

```bash
terraform force-unlock <LOCK_ID>
```

Never force-unlock an active deployment.


---

## Execution-Specific Engineering Decision

### Inherited storage policy handled through compliance

**Issue:** Storage-account creation was denied by the management-group assignment **Deny Public Storage Accounts — MG Level**. The detailed policy evaluation showed that `networkAcls.defaultAction` was not set to `Deny`.

**Resolution:** The storage account was recreated with the firewall default action set to `Deny`. A network rule then allowed only the engineer's current public IP.

**Result:** The backend remained reachable from the approved workstation while all other public traffic was denied by default. The environment stayed compliant, and another policy exemption was not required.

A separate exemption should be documented only for a different policy assignment that could not be satisfied through a compliant configuration.

---

## Cleanup Procedure

Keep the resources if you are continuing to Workstream 2.

To remove the Terraform-managed resource groups:

```bash
cd terraform/environments/dev
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

The backend is intentionally not destroyed by the landing-zone Terraform configuration.

After the Terraform-managed resources are removed, delete the backend only when the entire project is finished and you no longer need the state history:

```bash
az group delete \
  --name "rg-eaap-tfstate-dev" \
  --yes \
  --no-wait
```

Deleting the backend removes the Terraform state. Do not perform this action while continuing the project.

---

## Workstream Completion Criteria

Workstream 1 is complete when:

- The backend exists and Terraform uses it successfully.
- The four landing-zone resource groups are deployed through Terraform.
- Required tags appear on the Terraform-managed resource groups.
- A second plan reports no changes.
- The Python automation creates a valid CSV compliance report.
- Evidence screenshots are added to the case study.
- Sensitive files remain outside source control.

---

## Next Workstream

**Workstream 2 — Enterprise Networking** will build the hub-and-spoke network, subnet architecture, NSGs, route tables, private DNS foundation, and connectivity validation on top of this landing zone.
