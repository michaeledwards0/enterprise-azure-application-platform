# EAAP PowerShell Session Bootstrap
# Restores commonly used variables for Enterprise Azure Application Platform Workstreams 1-5.
# Run with dot-sourcing so variables persist in the current PowerShell session:
#   . .\eaap-session-bootstrap.ps1


$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID

$env:LOCATION = "southcentralus"
$env:LOCATION_SHORT = "scus"
$env:ENVIRONMENT = "dev"
$env:PROJECT_SHORT = "eaap"
$env:TFSTATE_RG = "rg-eaap-tfstate-dev"
$env:TFSTATE_CONTAINER = "tfstate"
$env:TFSTATE_SA = "steaaptfstatedev5083"

$tfstateSaId = az storage account show `
  --name "$env:TFSTATE_SA" `
  --resource-group "$env:TFSTATE_RG" `
  --query id `
  -o tsv

$signedInObjectId = az ad signed-in-user show --query id -o tsv

$myPublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Write-Host $myPublicIp
# -----------------------------
# Local repository paths
# -----------------------------
$repoRoot = "$HOME\Documents\enterprise-azure-application-platform"
$terraformDir = Join-Path $repoRoot "terraform\environments\dev"
$appDir = Join-Path $repoRoot "app\sample-web"
$k8sDir = Join-Path $repoRoot "app\k8s"
$workflowDir = Join-Path $repoRoot ".github\workflows"

# -----------------------------
# Azure subscription / tenant
# -----------------------------
$subscriptionId = "565b4a05-b64e-48fa-b70b-30eb2545a67b"
$subscriptionName = "Azure subscription 1"
$tenantId = "14abb5bd-36fe-407a-8b80-cc22c8ce0d49"

az account set --subscription $subscriptionId

$env:ARM_SUBSCRIPTION_ID = $subscriptionId
$env:AZURE_SUBSCRIPTION_ID = $subscriptionId
$env:ARM_TENANT_ID = $tenantId
$env:AZURE_TENANT_ID = $tenantId

# Do NOT set ARM_CLIENT_ID / ARM_CLIENT_SECRET here.
# Local Terraform uses your Azure CLI login. The GitHub SP is for GitHub Actions.

# -----------------------------
# Resource groups
# -----------------------------
$tfStateResourceGroup = "rg-eaap-tfstate-dev"
$platformResourceGroup = "rg-eaap-platform-dev"
$networkResourceGroup = "rg-eaap-network-dev"
$operationsResourceGroup = "rg-eaap-operations-dev"
$workloadResourceGroup = "rg-eaap-workload-dev"

# -----------------------------
# Terraform backend
# -----------------------------
$tfStateContainer = "tfstate"
$tfStateKey = "eaap/dev/landing-zone.tfstate"
$backendConfigFile = Join-Path $terraformDir "backend.hcl"

$tfStateStorageAccount = az storage account list `
  --resource-group $tfStateResourceGroup `
  --query "[0].name" `
  --output tsv

# -----------------------------
# Core Azure resources
# -----------------------------
$aksName = "aks-eaap-dev-scus-001"
$acrName = "acreaapdev5803"
$acrLoginServer = "acreaapdev5803.azurecr.io"
$keyVaultName = "kveaapdev5803"

$k8sNamespace = "eaap-app"
$k8sServiceAccount = "eaap-workload-sa"
$secretProviderClass = "eaap-key-vault-secrets"

$sampleAppRepository = "eaap-sample-web"
$sampleAppServiceName = "eaap-sample-web"
$sampleAppDeploymentName = "eaap-sample-web"
$sampleAppInternalIP = "10.20.1.10"

# -----------------------------
# Networking
# -----------------------------
$appVnetName = "vnet-eaap-app-dev-scus-001"
$workloadSubnetName = "snet-workload-dev-scus-001"
$ingressSubnetName = "snet-ingress-dev-scus-001"

$aksId = az aks show `
  --resource-group $platformResourceGroup `
  --name $aksName `
  --query id `
  --output tsv

$acrId = az acr show `
  --name $acrName `
  --query id `
  --output tsv

$workloadSubnetId = az network vnet subnet show `
  --resource-group $networkResourceGroup `
  --vnet-name $appVnetName `
  --name $workloadSubnetName `
  --query id `
  --output tsv

$ingressSubnetId = az network vnet subnet show `
  --resource-group $networkResourceGroup `
  --vnet-name $appVnetName `
  --name $ingressSubnetName `
  --query id `
  --output tsv

# -----------------------------
# Application workload identity
# -----------------------------
$workloadIdentityName = "id-eaap-workload-dev-scus-001"

$workloadIdentityClientId = az identity show `
  --resource-group $platformResourceGroup `
  --name $workloadIdentityName `
  --query clientId `
  --output tsv

$workloadIdentityPrincipalId = az identity show `
  --resource-group $platformResourceGroup `
  --name $workloadIdentityName `
  --query principalId `
  --output tsv

# -----------------------------
# AKS identities
# -----------------------------
$aksClusterPrincipalId = az aks show `
  --resource-group $platformResourceGroup `
  --name $aksName `
  --query identity.principalId `
  --output tsv

$aksKubeletClientId = az aks show `
  --resource-group $platformResourceGroup `
  --name $aksName `
  --query identityProfile.kubeletidentity.clientId `
  --output tsv

$aksKubeletObjectId = az aks show `
  --resource-group $platformResourceGroup `
  --name $aksName `
  --query identityProfile.kubeletidentity.objectId `
  --output tsv

$keyVaultCsiIdentityName = "azurekeyvaultsecretsprovider-aks-eaap-dev-scus-001"
$aksNodeResourceGroup = az aks show `
  --resource-group $platformResourceGroup `
  --name $aksName `
  --query nodeResourceGroup `
  --output tsv

$keyVaultCsiClientId = az identity show `
  --resource-group $aksNodeResourceGroup `
  --name $keyVaultCsiIdentityName `
  --query clientId `
  --output tsv 2>$null

# -----------------------------
# GitHub / CI-CD identity
# -----------------------------
$githubRepository = "michaeledwards0/enterprise-azure-application-platform"
$githubRepositoryId = "1311239206"
$githubBranch = "main"

$githubAppDisplayName = "app-eaap-github-actions-dev"
$githubAppClientId = "95cf53ac-c82f-402e-8d63-e40f6be20284"
$githubServicePrincipalObjectId = "68d785bc-9ea5-4de9-b7f0-4ad6ce8fe3c8"

# Old Phase 5 GitHub UAMI — keep only until final cleanup/reconciliation.
$legacyGithubManagedIdentityName = "id-eaap-github-actions-dev-scus-001"

# GitHub repository variables (stored here for reference; GitHub Actions reads them from repo settings)
$githubActionsVariables = [ordered]@{
  ACR_NAME           = $acrName
  ACR_LOGIN_SERVER   = $acrLoginServer
  AKS_RESOURCE_GROUP = $platformResourceGroup
  AKS_NAME           = $aksName
  K8S_NAMESPACE      = $k8sNamespace
}

# GitHub repository secrets used by OIDC:
#   AZURE_CLIENT_ID       = $githubAppClientId
#   AZURE_TENANT_ID       = $tenantId
#   AZURE_SUBSCRIPTION_ID = $subscriptionId
# There is NO AZURE_CLIENT_SECRET.

# -----------------------------
# Helpful commands
# -----------------------------
$terraformInitCommand = 'terraform init -reconfigure -backend-config="backend.hcl"'
$terraformValidateCommand = 'terraform validate'
$terraformPlanCommand = 'terraform plan'

# -----------------------------
# Phase 6 placeholders (add after monitoring resources are created)
# -----------------------------
# $logAnalyticsWorkspaceName = "law-eaap-ops-dev-scus-001"
# $actionGroupName = "ag-eaap-platform-dev-scus-001"
# $workspaceId = az monitor log-analytics workspace show `
#   --resource-group $operationsResourceGroup `
#   --workspace-name $logAnalyticsWorkspaceName `
#   --query customerId `
#   --output tsv

# -----------------------------
# Session summary
# -----------------------------
Write-Host ""
Write-Host "EAAP session restored."
Write-Host "---------------------------------------------"
Write-Host "Repo:                $repoRoot"
Write-Host "Subscription:        $subscriptionName"
Write-Host "Terraform directory: $terraformDir"
Write-Host "Backend storage:     $tfStateStorageAccount"
Write-Host "AKS:                 $aksName"
Write-Host "ACR:                 $acrLoginServer"
Write-Host "Key Vault:           $keyVaultName"
Write-Host "Namespace:           $k8sNamespace"
Write-Host "GitHub app:          $githubAppDisplayName"
Write-Host "---------------------------------------------"
Write-Host ""
Write-Host "Tip: cd `$terraformDir"
