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

## Prerequisites — Install and Connect the Toolchain

This project uses several tools together. Each tool has a separate job:

```text
Git and GitHub       Store and track the project files
Visual Studio Code   Edit the Terraform, Python, and Markdown files
Azure CLI            Sign in to Azure and select the subscription
Terraform            Read the .tf files and deploy Azure resources
Python               Run the tag-compliance automation
Azure Python SDK     Allow the Python script to query Azure
```

Simple meaning:

> Azure CLI provides the Azure login. Terraform and the Python script reuse that login to work with the selected Azure subscription.

### Prerequisite 1 — Open PowerShell as Administrator

Use an elevated PowerShell window for the initial software installation.

Confirm that Windows Package Manager is available:

```powershell
winget --version
```

If `winget` is not recognized, install or update **App Installer** from the Microsoft Store.

### Prerequisite 2 — Install Git

Git tracks changes to the repository and communicates with GitHub.

```powershell
winget install --id Git.Git -e
```

Close and reopen PowerShell after installation, then verify:

```powershell
git --version
```

Configure the name and email that Git will attach to commits:

```powershell
git config --global user.name "<YOUR_NAME>"
git config --global user.email "<YOUR_GITHUB_EMAIL>"
```

Verify the configuration:

```powershell
git config --global --list
```

Simple meaning:

> Git tracks the files on the computer. GitHub stores a remote copy of the repository.

Git does not need to be reconnected every time PowerShell is reopened. After the repository is cloned or connected to a remote, verify the connection with:

```powershell
git remote -v
```

### Prerequisite 3 — Install Visual Studio Code

Visual Studio Code is used to edit the Terraform files, Python script, Markdown documentation, and evidence references.

```powershell
winget install --id Microsoft.VisualStudioCode -e
```

Verify:

```powershell
code --version
```

Recommended Visual Studio Code extensions:

- HashiCorp Terraform
- Python
- PowerShell
- GitHub Pull Requests and Issues

Open the repository from PowerShell:

```powershell
code .
```

Simple meaning:

> Visual Studio Code edits the project files. The integrated PowerShell terminal runs the same Git, Azure CLI, Terraform, and Python commands.

### Prerequisite 4 — Install Azure CLI

Azure CLI signs the engineer into Azure and selects the subscription used by Terraform and Python.

```powershell
winget install --id Microsoft.AzureCLI -e
```

Close and reopen PowerShell, then verify:

```powershell
az version
```

Sign in:

```powershell
az login
```

List subscriptions:

```powershell
az account list --output table
```

Select the project subscription:

```powershell
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

Confirm the selected subscription:

```powershell
az account show `
  --query "{Name:name,SubscriptionId:id,State:state,IsDefault:isDefault}" `
  --output table
```

Simple meaning:

> `az login` creates the Azure login session. `az account set` tells the other tools which subscription to use.

The Azure CLI login often remains available after PowerShell is closed. Check it with:

```powershell
az account show --output table
```

Run `az login` again only when Azure says authentication is required.

### Prerequisite 5 — Install Terraform

Terraform reads the `.tf` files, compares them with the Terraform state and Azure, and deploys the required changes.

```powershell
winget install --id Hashicorp.Terraform -e
```

Close and reopen PowerShell, then verify:

```powershell
terraform version
```

This runbook requires:

```text
Terraform >= 1.6.0 and < 2.0.0
```

Terraform does not have a separate login command.

It communicates with Azure by using:

1. The current Azure CLI login created by `az login`
2. The subscription selected by `az account set`
3. The `azurerm` provider configured in the Terraform files
4. The subscription environment variable created later in Step 3

Simple meaning:

> Azure CLI proves who you are. Terraform uses that identity to deploy resources into Azure.

### Prerequisite 6 — Install Python

Python runs the tag-compliance automation.

Install a supported Python 3 release:

```powershell
winget install --id Python.Python.3.12 -e
```

Close and reopen PowerShell, then verify:

```powershell
python --version
python -m pip --version
```

This runbook requires Python 3.10 or later.

Installing Python does **not** connect Python to Azure by itself.

Python connects to Azure later in **Step 14 and Step 15**:

1. Step 14 creates and activates `.venv`.
2. Step 14 installs the Azure Python packages from `requirements.txt`.
3. Step 15 runs `tag_compliance_report.py`.
4. The script imports `DefaultAzureCredential`.
5. `DefaultAzureCredential` reuses the current Azure CLI login.
6. The script queries the selected subscription through Azure Resource Graph.

Simple meaning:

> Python is the engine. The Azure Python packages give it Azure capabilities. The Azure CLI login gives it permission to query Azure.

The supplied `requirements.txt` should contain:

```text
azure-identity>=1.17,<2.0
azure-mgmt-resourcegraph>=8.0,<9.0
```

These packages are installed later inside the project virtual environment, not globally.

### Prerequisite 7 — Confirm All Tools Are Available

Run:

```powershell
git --version
code --version
az version
terraform version
python --version
python -m pip --version
```

All commands must return version information before continuing.

### How the Tools Work Together

```text
PowerShell
   |
   +-- Git ----------------------> tracks repository changes
   |
   +-- Visual Studio Code ------> edits project files
   |
   +-- Azure CLI ---------------> authenticates to Azure
   |                                 |
   |                                 +--> selected subscription
   |                                          |
   +-- Terraform -----------------------------+--> deploys Azure resources
   |                                          |
   +-- Python + Azure SDK ---------------------+--> audits Azure resource tags
```

### What Persists After PowerShell Is Closed

These remain installed or saved:

- Git, Azure CLI, Terraform, Python, and Visual Studio Code
- The cloned repository
- Terraform and Python files
- Git remote configuration
- The `.venv` folder and packages installed inside it
- Terraform's `.terraform` folder and provider lock file

These must be restored when needed:

- PowerShell environment variables such as `$env:TFSTATE_SA`
- Normal PowerShell variables such as `$myPublicIp`
- Python virtual-environment activation
- Azure authentication only when the existing login has expired

To reactivate the Python virtual environment:

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform\automation\tag-compliance"
.\.venv\Scripts\Activate.ps1
```

The prompt should change to:

```text
(.venv) PS C:\...
```

The packages do not need to be reinstalled every time. Activate the existing virtual environment and run the script.

---

## Step 1 — Clone or Create the Repository

Create the project folder:

```powershell
New-Item -ItemType Directory -Force -Path ".\enterprise-azure-application-platform"
cd .\enterprise-azure-application-platform
git init
```

Create the initial folder structure:

```powershell
New-Item -ItemType Directory -Force -Path ".\docs\phase-1-landing-zone"
New-Item -ItemType Directory -Force -Path ".\runbooks"
New-Item -ItemType Directory -Force -Path ".\terraform\environments\dev"
New-Item -ItemType Directory -Force -Path ".\automation\tag-compliance\reports"
New-Item -ItemType Directory -Force -Path ".\screenshots\phase-1"
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

```powershell
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
  --output json
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
az storage account show `
  --name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query "{PublicNetworkAccess:publicNetworkAccess, DefaultAction:networkRuleSet.defaultAction}" `
  --output table
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

```powershell
cd .\terraform\environments\dev
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

```powershell
Copy-Item .\backend.hcl.example .\backend.hcl
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

```powershell
Get-Content .\backend.hcl
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

```powershell
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
```

Review the directory:

```powershell
Get-ChildItem -Force
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

```powershell
terraform fmt -recursive
```

Initialize the backend:

```powershell
terraform init -backend-config=backend.hcl
```

Validate the configuration:

```powershell
terraform validate
```

Expected result:

```text
Success! The configuration is valid.
```

---

## Step 9 — Create and Review the Terraform Plan

Create a saved plan:

```powershell
terraform plan -out=phase1.tfplan
```

Review the plan carefully:

```powershell
terraform show phase1.tfplan
```

Confirm that Terraform plans to create only the four expected resource groups.

Do not apply the plan if unexpected resources, regions, names, or destructive actions appear.

---

## Step 10 — Deploy the Landing Zone

Apply the reviewed plan:

```powershell
terraform apply phase1.tfplan
```

Display outputs:

```powershell
terraform output
```

List the deployed resource groups:

```powershell
az group list --query "[?starts_with(name, 'rg-eaap-')].[name,location,tags.ManagedBy,tags.Environment]" --output table

```

---

## Step 11 — Validate Remote State

List state objects from Terraform:

```powershell
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

```powershell
az group show --name "rg-eaap-platform-dev" --query "{Name:name,Location:location,Tags:tags}" --output json

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

```powershell
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

```powershell
cd ../../..
```

Move into the tag-compliance automation folder:

```powershell
cd .\automation\tag-compliance
```

Simple meaning:

> Move PowerShell into the folder that will contain the Python environment, package list, script, and generated reports.

Create a project-specific Python virtual environment:

```powershell
python -m venv .venv
```

Activate it:

```powershell
.\.venv\Scripts\Activate.ps1
```

The PowerShell prompt should now begin with:

```text
(.venv)
```

Example:

```text
(.venv) PS C:\Users\<username>\Documents\enterprise-azure-application-platform\automation\tag-compliance>
```

Simple meaning:

> Create and activate a private Python environment for this project so its packages remain separate from other Python projects.

The `.venv` folder only needs to be created once.

After reopening PowerShell, reactivate it with:

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform\automation\tag-compliance"

.\.venv\Scripts\Activate.ps1
```

The packages do not need to be reinstalled every time the virtual environment is activated.

The `requirements.txt` file is a list of the Python packages required by the tag-compliance script.

It is not automatically created by Python or Azure. The developer creates it based on the libraries imported by the Python script.

Create the file:

```powershell
New-Item `
  -ItemType File `
  -Name "requirements.txt" `
  -Force
```

Open it in Visual Studio Code:

```powershell
code .\requirements.txt
```

Paste the following package requirements into the file:

```text
azure-identity>=1.17,<2.0
azure-mgmt-resourcegraph>=8.0,<9.0
```

Save the file with:

```text
Ctrl + S
```

The completed file should be located at:

```text
automation/tag-compliance/requirements.txt
```

Simple meaning:

> `requirements.txt` is the project's Python package list. It tells `pip` which Azure libraries must be installed.

The packages serve these purposes:

```text
azure-identity
```

> Allows the Python script to obtain an Azure credential, including reusing the current Azure CLI login.

```text
azure-mgmt-resourcegraph
```

> Allows the Python script to query Azure Resource Graph for resources, resource groups, and tags.

Upgrade pip:

```powershell
python -m pip install --upgrade pip
```

Simple meaning:

> Update the tool Python uses to install packages.

Install everything listed in `requirements.txt`:

```powershell
python -m pip install -r .\requirements.txt
```

Simple meaning:

> Read the package names inside `requirements.txt` and install them into the active `.venv` environment.

The packages are installed inside:

```text
automation/tag-compliance/.venv
```

They are not installed directly into the repository files and are not committed to GitHub.

Confirm the packages were installed:

```powershell
python -m pip list | Select-String "azure"
```

Confirm the identity package:

```powershell
python -m pip show azure-identity
```

Confirm the Resource Graph package:

```powershell
python -m pip show azure-mgmt-resourcegraph
```

These checks are mainly for initial setup and troubleshooting. They do not need to be run every time PowerShell is reopened.

Check that the Azure CLI login is still valid:

```powershell
az account show `
  --query "{Name:name,SubscriptionId:id,State:state,IsDefault:isDefault}" `
  --output table
```

If Azure reports that authentication is required, sign in again:

```powershell
az login
```

Select the correct subscription when necessary:

```powershell
az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
```

Simple meaning:

> Azure CLI authenticates the user. The Python script will reuse this Azure login through `DefaultAzureCredential`.

Set the active Azure subscription ID for the current PowerShell session:

```powershell
$env:AZURE_SUBSCRIPTION_ID = az account show --query id -o tsv
```

Confirm that the variable contains a value:

```powershell
$env:AZURE_SUBSCRIPTION_ID
```

Do not include the subscription ID in public screenshots.

This environment variable must be recreated after PowerShell is closed because PowerShell session variables do not persist automatically.

The Python-to-Azure connection happens in this order:

```text
az login
   ↓
Azure CLI stores the authenticated login
   ↓
requirements.txt identifies the required Azure Python packages
   ↓
pip installs azure-identity and azure-mgmt-resourcegraph
   ↓
tag_compliance_report.py imports those packages
   ↓
DefaultAzureCredential finds the Azure CLI login
   ↓
ResourceGraphClient queries the selected Azure subscription
```

Simple meaning:

> Python itself does not automatically connect to Azure. The Azure packages give Python the required Azure functions, and `DefaultAzureCredential` reuses the Azure CLI login.

Confirm the automation folder:

```powershell
Get-ChildItem
```

Expected items:

```text
.venv
reports
requirements.txt
tag_compliance_report.py
```

At this point:

- Python is installed.
- The project virtual environment is active.
- The required Azure packages are installed.
- Azure CLI authentication is available.
- The subscription environment variable is set.
- The Python script is ready to be created or run in Step 15.

---


---

## Step 15 — Create and Run the Python Tag-Compliance Report

The Python packages installed in Step 14 provide the Azure libraries. The actual automation script must also exist in the repository before it can be run.

### 15.1 Confirm the Automation Directory

From the repository root:

```powershell
cd automation/tag-compliance
```

Confirm the expected files and folders:

```powershell
Get-ChildItem
```

Expected structure:

```text
automation/
└── tag-compliance/
    ├── .venv/
    ├── reports/
    ├── requirements.txt
    └── tag_compliance_report.py
```

### 15.2 Create the Script File

If `tag_compliance_report.py` does not already exist, create it:

```powershell
New-Item `
  -ItemType File `
  -Name "tag_compliance_report.py" `
  -Force
```

Open the file in Visual Studio Code:

```powershell
code .\tag_compliance_report.py
```

The file is empty when it is first created. Paste the complete script below into `tag_compliance_report.py`, then save the file with `Ctrl + S`.

### Complete `tag_compliance_report.py` Script

```python
#!/usr/bin/env python3
"""Generate an Azure tag-compliance CSV report with Azure Resource Graph."""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions


REQUIRED_TAGS = [
    "Project",
    "Environment",
    "ManagedBy",
    "Owner",
    "CostCenter",
    "DataClassification",
    "Criticality",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check Azure resources for the required EAAP tags."
    )
    parser.add_argument(
        "--include-resource-groups",
        action="store_true",
        help="Include Azure resource groups in the compliance check.",
    )
    parser.add_argument(
        "--no-fail-on-noncompliance",
        action="store_true",
        help="Return exit code 0 even when missing tags are found.",
    )
    parser.add_argument(
        "--subscription-id",
        help=(
            "Azure subscription ID. When omitted, the script checks "
            "AZURE_SUBSCRIPTION_ID, ARM_SUBSCRIPTION_ID, and then Azure CLI."
        ),
    )
    parser.add_argument(
        "--output-dir",
        default="reports",
        help="Directory where the CSV report will be written. Default: reports",
    )
    return parser.parse_args()


def get_subscription_id(explicit_id: str | None) -> str:
    candidates = [
        explicit_id,
        os.getenv("AZURE_SUBSCRIPTION_ID"),
        os.getenv("ARM_SUBSCRIPTION_ID"),
    ]

    for candidate in candidates:
        if candidate and candidate.strip():
            return candidate.strip()

    try:
        result = subprocess.run(
            ["az", "account", "show", "--query", "id", "-o", "tsv"],
            check=True,
            capture_output=True,
            text=True,
        )
        subscription_id = result.stdout.strip()
        if subscription_id:
            return subscription_id
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            "Could not determine the Azure subscription ID. "
            "Run 'az login' and select a subscription, or set "
            "AZURE_SUBSCRIPTION_ID."
        ) from exc

    raise RuntimeError("The Azure subscription ID could not be determined.")


def build_query(include_resource_groups: bool) -> str:
    resource_query = """
Resources
| project id, name, type, location, resourceGroup, subscriptionId, tags
"""

    if not include_resource_groups:
        return resource_query.strip()

    return """
union
(
    Resources
    | project id, name, type, location, resourceGroup, subscriptionId, tags
),
(
    ResourceContainers
    | where type =~ "microsoft.resources/subscriptions/resourcegroups"
    | project
        id,
        name,
        type,
        location,
        resourceGroup = name,
        subscriptionId,
        tags
)
| order by type asc, name asc
""".strip()


def normalize_tags(tags: Any) -> dict[str, str]:
    if not isinstance(tags, dict):
        return {}

    normalized: dict[str, str] = {}
    for key, value in tags.items():
        normalized[str(key).casefold()] = "" if value is None else str(value).strip()
    return normalized


def evaluate_resource(resource: dict[str, Any]) -> dict[str, Any]:
    tags = normalize_tags(resource.get("tags"))
    missing_tags = [
        required
        for required in REQUIRED_TAGS
        if not tags.get(required.casefold())
    ]

    return {
        "subscription_id": resource.get("subscriptionId", ""),
        "resource_group": resource.get("resourceGroup", ""),
        "resource_name": resource.get("name", ""),
        "resource_type": resource.get("type", ""),
        "location": resource.get("location", ""),
        "resource_id": resource.get("id", ""),
        "compliance_status": "Compliant" if not missing_tags else "Noncompliant",
        "missing_tags": "; ".join(missing_tags),
        **{
            f"tag_{required}": tags.get(required.casefold(), "")
            for required in REQUIRED_TAGS
        },
    }


def query_resources(subscription_id: str, include_resource_groups: bool) -> list[dict[str, Any]]:
    credential = DefaultAzureCredential()
    client = ResourceGraphClient(credential)

    try:
        request = QueryRequest(
            subscriptions=[subscription_id],
            query=build_query(include_resource_groups),
            options=QueryRequestOptions(
                result_format="objectArray",
                top=1000,
            ),
        )
        response = client.resources(request)
        return list(response.data or [])
    finally:
        client.close()
        credential.close()


def write_csv(rows: list[dict[str, Any]], output_dir: str) -> Path:
    report_dir = Path(output_dir)
    report_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report_path = report_dir / f"azure-tag-compliance-{timestamp}.csv"

    fieldnames = [
        "subscription_id",
        "resource_group",
        "resource_name",
        "resource_type",
        "location",
        "resource_id",
        "compliance_status",
        "missing_tags",
        *[f"tag_{tag}" for tag in REQUIRED_TAGS],
    ]

    with report_path.open("w", newline="", encoding="utf-8-sig") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return report_path.resolve()


def print_summary(rows: list[dict[str, Any]], report_path: Path) -> None:
    total = len(rows)
    compliant = sum(row["compliance_status"] == "Compliant" for row in rows)
    noncompliant = total - compliant
    compliance_rate = (compliant / total * 100) if total else 100.0

    print()
    print("Azure Tag Compliance Summary")
    print("============================")
    print(f"Resources evaluated : {total}")
    print(f"Compliant resources : {compliant}")
    print(f"Noncompliant        : {noncompliant}")
    print(f"Compliance rate     : {compliance_rate:.2f}%")
    print(f"CSV report          : {report_path}")


def main() -> int:
    args = parse_args()

    try:
        subscription_id = get_subscription_id(args.subscription_id)
        resources = query_resources(
            subscription_id=subscription_id,
            include_resource_groups=args.include_resource_groups,
        )
        rows = [evaluate_resource(resource) for resource in resources]
        report_path = write_csv(rows, args.output_dir)
        print_summary(rows, report_path)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    has_noncompliance = any(
        row["compliance_status"] == "Noncompliant" for row in rows
    )

    if has_noncompliance and not args.no_fail_on_noncompliance:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Another valid method is to save the completed script directly at:

```text
automation/tag-compliance/tag_compliance_report.py
```

Simple meaning:

> Installing Python prepares the computer to run Python code. Creating the file gives the script a location. Pasting the code into the file adds the automation that checks Azure tags and creates the CSV report.


### 15.3 Validate the Script Before Running It

Check the script for Python syntax errors:

```powershell
python -m py_compile .\tag_compliance_report.py
```

Expected result:

```text
No output
```

No output means Python successfully validated the script syntax.

The final script runs two separate Azure Resource Graph queries:

- `Resources` for Azure resources
- `ResourceContainers` for resource groups

The script combines the results in Python. It does not use a single `union` query.

Confirm the old `union` query is not present:

```powershell
Select-String `
  -Path .\tag_compliance_report.py `
  -Pattern "union"
```

Expected result:

```text
No output
```

### 15.4 Confirm Azure Authentication and Subscription

```powershell
az account show `
  --query "{Subscription:name,SubscriptionId:id,State:state}" `
  --output table
```

If PowerShell was restarted, reset the subscription environment variable:

```powershell
$env:AZURE_SUBSCRIPTION_ID = az account show --query id -o tsv
```

### 15.5 Run the Tag-Compliance Report

```powershell
python .\tag_compliance_report.py --include-resource-groups
```

Simple meaning:

> Run the Python script and include resource groups in the tag-compliance check.

The script evaluates the active subscription against these tags:

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
============================
Resources evaluated : <number>
Compliant resources : <number>
Noncompliant        : <number>
Compliance rate     : <percentage>%
CSV report          : <local path>
```

The script returns:

- Exit code `0` when all evaluated resources are compliant
- Exit code `1` when authentication, configuration, or an Azure Resource Graph query fails
- Exit code `2` when the queries succeed but noncompliant resources are found

Exit code `2` means the script worked and found resources with missing tags. It does not mean the script failed.

A noncompliant result may be expected in a shared subscription containing resources from other projects.

### 15.6 Generate Evidence Without Failing on Noncompliance

```powershell
python .\tag_compliance_report.py `
  --include-resource-groups `
  --no-fail-on-noncompliance
```

Simple meaning:

> Generate the report even when missing tags are found, but return a successful terminal exit code.

### 15.7 Review the CSV Report

The script creates a timestamped CSV under:

```text
automation/tag-compliance/reports/azure-tag-compliance-<timestamp>.csv
```

List the generated reports:

Make sure PowerShell is currently in:

```text
enterprise-azure-application-platform\automation\tag-compliance
```

Then list the generated reports:

```powershell
Get-ChildItem .\reports
Get-ChildItem .\reports

make sure to be in : enterprise-azure-application-platform\automation\tag-compliance
```

Open the newest report in Visual Studio Code:

```powershell
$latestReport = Get-ChildItem .\reports\azure-tag-compliance-*.csv |
$latestReport = Get-ChildItem .\reports\azure-tag-compliance-*.csv |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

code $latestReport.FullName
```

Review these columns:

```text
resource_name
resource_type
resource_group
compliance_status
missing_tags
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

```powershell
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

```powershell
git add .\.gitignore
git add .\docs\phase-1-landing-zone
git add .\runbooks\phase-1-landing-zone-runbook.md
git add .\terraform
git add .\automation\tag-compliance
git add .\screenshots\phase-1
```

This stages only the Phase 1 project files and avoids accidentally including unfinished later workstreams.

Review the staged changes:

```powershell
git diff --cached
```

Commit:

```powershell
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
- [ ] `tag_compliance_report.py` created and populated with the approved script
- [ ] Python syntax validation completed successfully
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

```powershell
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

### Python reports `Failed to resolve table or column expression named 'Resources'`

The script still contains the old Azure Resource Graph `union` query.

Check the file:

```powershell
Select-String `
  -Path .\tag_compliance_report.py `
  -Pattern "union"
```

The corrected script should return no output because it queries `Resources` and `ResourceContainers` separately and combines the results in Python.

Replace the old script with the approved version, save it, and validate the syntax:

```powershell
python -m py_compile .\tag_compliance_report.py
```

### Python reports `unterminated triple-quoted string literal`

A multi-line Python string was edited incorrectly or left without a closing triple quote.

Replace the entire script with the approved version instead of repairing individual lines. Save the file and run:

```powershell
python -m py_compile .\tag_compliance_report.py
```

No output means the syntax is valid.

### Python returns exit code 2

The query worked, but one or more resources are missing required tags. Review the generated CSV. Use `--no-fail-on-noncompliance` when you need a report without a failing process exit code.

### `terraform plan` shows unexpected tag changes

Check whether tags were modified manually in the portal. Terraform will attempt to restore the configured values. Decide whether the portal change or the code is authoritative, then update the correct source.

### State lock remains after an interrupted operation

First confirm that no other Terraform process is running. Terraform normally releases locks automatically. Use force-unlock only when you have confirmed the lock is stale:

```powershell
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

Do not use clean up procedure if you plan on going to the next phase and completing the project. Only Clean up when you are done with the project. 
Do not use clean up procedure if you plan on going to the next phase and completing the project. Only Clean up when you are done with the project. 

To remove the Terraform-managed resource groups:

```powershell
cd .\terraform\environments\dev
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

The backend is intentionally not destroyed by the landing-zone Terraform configuration.

After the Terraform-managed resources are removed, delete the backend only when the entire project is finished and you no longer need the state history:

```powershell
az group delete `
  --name "rg-eaap-tfstate-dev" `
  --yes `
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
