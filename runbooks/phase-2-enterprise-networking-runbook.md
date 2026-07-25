<div align="center">

# Workstream 2 Runbook: Enterprise Networking
### Hub-and-Spoke VNets, Subnets, Peerings, NSGs, Route Tables, and Private DNS

</div>

---

## Purpose

This runbook builds the network foundation for the Enterprise Azure Application Platform.

You will:

1. Confirm the Phase 1 Terraform backend and landing-zone state are healthy.
2. Create a hub VNet and application spoke VNet.
3. Create purpose-built subnets with non-overlapping CIDR ranges.
4. Configure bidirectional VNet peering.
5. Create and associate subnet-level network security groups.
6. Create and associate a spoke route table.
7. Create a centralized Azure Private DNS zone and link both VNets.
8. Validate the deployment and capture portfolio evidence.

> **Dependency:** Do not deploy Workstream 2 until Workstream 1 is complete in the intended EAAP subscription. The remote backend, state blob, and four landing-zone resource groups must already exist.

---

## Target Resources

| Resource | Name | Address or Purpose |
|---|---|---|
| Hub VNet | `vnet-eaap-hub-dev-scus-001` | `10.10.0.0/16` |
| Application spoke VNet | `vnet-eaap-app-dev-scus-001` | `10.20.0.0/16` |
| Hub shared-services subnet | `snet-shared-services-dev-scus-001` | `10.10.1.0/24` |
| Azure Bastion subnet | `AzureBastionSubnet` | `10.10.2.0/26` |
| Ingress subnet | `snet-ingress-dev-scus-001` | `10.20.1.0/24` |
| Workload subnet | `snet-workload-dev-scus-001` | `10.20.2.0/23` |
| Private endpoint subnet | `snet-private-endpoints-dev-scus-001` | `10.20.4.0/24` |
| Ingress NSG | `nsg-eaap-ingress-dev-scus-001` | Ingress boundary |
| Workload NSG | `nsg-eaap-workload-dev-scus-001` | Application workload boundary |
| Spoke route table | `rt-eaap-app-dev-scus-001` | Future centralized routing control |
| Private DNS zone | `internal.contoso.com` | Internal name-resolution foundation |

---

## Design Notes

- The VNets use non-overlapping `/16` address spaces.
- The workload subnet uses `/23` to reserve additional capacity for later platform components.
- `AzureBastionSubnet` must keep that exact Azure-required name if Bastion is deployed later.
- The route table intentionally contains no forced-tunneling route yet because no Azure Firewall or virtual appliance exists.
- The private DNS zone is a project namespace. Private Link-specific zones will be added when their services are deployed.
- No VM is deployed in this workstream, so validation focuses on control-plane configuration rather than packet-level testing.

---

## Step 1 — Open the Repository and Restore the PowerShell Context

Open PowerShell and move to the repository root:

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
```

Confirm Git recognizes the repository:

```powershell
git status
```

Authenticate if needed:

```powershell
az account show --output none
```

If authentication has expired:

```powershell
az login
```

List subscriptions:

```powershell
az account list --output table
```

Select the dedicated EAAP subscription:

```powershell
az account set --subscription "<EAAP_SUBSCRIPTION_NAME_OR_ID>"
```

Confirm the context without exposing IDs:

```powershell
az account show `
  --query "{Name:name,State:state,IsDefault:isDefault}" `
  --output table
```

Restore the subscription variables:

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

Restore the project variables:

```powershell
$env:LOCATION = "southcentralus"
$env:LOCATION_SHORT = "scus"
$env:ENVIRONMENT = "dev"
$env:PROJECT_SHORT = "eaap"
```

---

## Step 2 — Confirm Workstream 1 Is Complete

Move to the Terraform environment:

```powershell
cd .\terraform\environments\dev
```

Confirm the backend file exists locally:

```powershell
Test-Path .\backend.hcl
```

Expected:

```text
True
```

Initialize or refresh the backend connection:

```powershell
terraform init -reconfigure -backend-config=backend.hcl
```

Validate the Phase 1 state:

```powershell
terraform state list
```

Expected Phase 1 resources:

```text
azurerm_resource_group.landing_zone["network"]
azurerm_resource_group.landing_zone["operations"]
azurerm_resource_group.landing_zone["platform"]
azurerm_resource_group.landing_zone["workload"]
```

Run a baseline plan:

```powershell
terraform plan
```

Expected before adding Workstream 2 code:

```text
No changes. Your infrastructure matches the configuration.
```

Stop if the backend cannot initialize, the resource groups are missing, or Terraform reports unexplained drift.

---

## Step 3 — Create the Phase 2 Documentation and Screenshot Folder

Return to the repository root:

```powershell
cd ..\..\..
```

Create the folders if they do not exist:

```powershell
New-Item -ItemType Directory -Force -Path ".\docs\phase-2-enterprise-networking"
New-Item -ItemType Directory -Force -Path ".\screenshots\phase-2"
```

Place the supplied case study at:

```text
docs/phase-2-enterprise-networking/README.md
```

Place this runbook at:

```text
runbooks/phase-2-enterprise-networking-runbook.md
```

---

## Step 4 — Add Networking Variables

Move back to the Terraform environment:

```powershell
cd .\terraform\environments\dev
```

Create `networking-variables.tf`:

```powershell
@'
variable "hub_vnet_address_space" {
  description = "Address space for the development hub virtual network."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "app_vnet_address_space" {
  description = "Address space for the development application spoke virtual network."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "hub_shared_services_subnet_prefix" {
  description = "CIDR prefix for the hub shared-services subnet."
  type        = list(string)
  default     = ["10.10.1.0/24"]
}

variable "hub_bastion_subnet_prefix" {
  description = "CIDR prefix reserved for Azure Bastion."
  type        = list(string)
  default     = ["10.10.2.0/26"]
}

variable "app_ingress_subnet_prefix" {
  description = "CIDR prefix for future ingress components."
  type        = list(string)
  default     = ["10.20.1.0/24"]
}

variable "app_workload_subnet_prefix" {
  description = "CIDR prefix for application platform workloads."
  type        = list(string)
  default     = ["10.20.2.0/23"]
}

variable "app_private_endpoints_subnet_prefix" {
  description = "CIDR prefix for Azure Private Endpoints."
  type        = list(string)
  default     = ["10.20.4.0/24"]
}

variable "private_dns_zone_name" {
  description = "Internal private DNS namespace used by the platform."
  type        = string
  default     = "internal.contoso.com"
}
'@ | Set-Content -Path "networking-variables.tf"
```

---

## Step 5 — Create the Virtual Networks and Subnets

Create `networking.tf`:

```powershell
@'
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-eaap-hub-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name
  address_space       = var.hub_vnet_address_space

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Hub-Network"
    }
  )
}

resource "azurerm_virtual_network" "app" {
  name                = "vnet-eaap-app-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name
  address_space       = var.app_vnet_address_space

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Spoke-Network"
    }
  )
}

resource "azurerm_subnet" "hub_shared_services" {
  name                 = "snet-shared-services-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = var.hub_shared_services_subnet_prefix
}

resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = var.hub_bastion_subnet_prefix
}

resource "azurerm_subnet" "app_ingress" {
  name                 = "snet-ingress-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_ingress_subnet_prefix
}

resource "azurerm_subnet" "app_workload" {
  name                 = "snet-workload-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_workload_subnet_prefix
}

resource "azurerm_subnet" "app_private_endpoints" {
  name                 = "snet-private-endpoints-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_private_endpoints_subnet_prefix
}
'@ | Set-Content -Path "networking.tf"
```

---

## Step 6 — Create Bidirectional VNet Peering

Append the peering resources to `networking.tf`:

```powershell
@'

resource "azurerm_virtual_network_peering" "hub_to_app" {
  name                      = "peer-hub-to-app-${var.environment}"
  resource_group_name       = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.app.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app_to_hub" {
  name                      = "peer-app-to-hub-${var.environment}"
  resource_group_name       = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name      = azurerm_virtual_network.app.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
'@ | Add-Content -Path "networking.tf"
```

> Gateway transit remains disabled because no VPN or ExpressRoute gateway exists yet.

---

## Step 7 — Create Network Security Groups and Rules

Create `network-security.tf`:

```powershell
@'
resource "azurerm_network_security_group" "ingress" {
  name                = "nsg-eaap-ingress-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Ingress-Subnet-Security"
    }
  )
}

resource "azurerm_network_security_group" "workload" {
  name                = "nsg-eaap-workload-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Workload-Subnet-Security"
    }
  )
}

resource "azurerm_network_security_rule" "allow_ingress_https_to_workload" {
  name                        = "Allow-Ingress-HTTPS-To-Workload"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.app_ingress_subnet_prefix[0]
  destination_address_prefix  = var.app_workload_subnet_prefix[0]
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_network_security_rule" "deny_other_inbound_to_workload" {
  name                        = "Deny-Other-Inbound-To-Workload"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  subnet_id                 = azurerm_subnet.app_ingress.id
  network_security_group_id = azurerm_network_security_group.ingress.id
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.app_workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}
'@ | Set-Content -Path "network-security.tf"
```

> The workload deny rule overrides Azure's default `AllowVNetInBound` rule. Later phases must deliberately add required AKS, ingress, health-probe, and management rules before deploying those services.

---

## Step 8 — Create and Associate the Route Table

Create `routing.tf`:

```powershell
@'
resource "azurerm_route_table" "app" {
  name                = "rt-eaap-app-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  bgp_route_propagation_enabled = true

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Spoke-Routing"
    }
  )
}

resource "azurerm_subnet_route_table_association" "app_workload" {
  subnet_id      = azurerm_subnet.app_workload.id
  route_table_id = azurerm_route_table.app.id
}

resource "azurerm_subnet_route_table_association" "app_private_endpoints" {
  subnet_id      = azurerm_subnet.app_private_endpoints.id
  route_table_id = azurerm_route_table.app.id
}
'@ | Set-Content -Path "routing.tf"
```

Do not add a `0.0.0.0/0` route to a virtual appliance until an approved firewall or appliance exists and its private IP is known.

---

## Step 9 — Create the Private DNS Zone and VNet Links

Create `private-dns.tf`:

```powershell
@'
resource "azurerm_private_dns_zone" "internal" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Internal-Name-Resolution"
    }
  )
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  name                  = "link-internal-dns-to-hub-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "app" {
  name                  = "link-internal-dns-to-app-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false

  tags = local.common_tags
}
'@ | Set-Content -Path "private-dns.tf"
```

---

## Step 10 — Create Networking Outputs

Create `networking-outputs.tf`:

```powershell
@'
output "hub_vnet" {
  description = "Hub virtual network name and ID."
  value = {
    name = azurerm_virtual_network.hub.name
    id   = azurerm_virtual_network.hub.id
  }
}

output "app_vnet" {
  description = "Application spoke virtual network name and ID."
  value = {
    name = azurerm_virtual_network.app.name
    id   = azurerm_virtual_network.app.id
  }
}

output "network_subnet_ids" {
  description = "Subnet IDs used by later workstreams."
  value = {
    hub_shared_services = azurerm_subnet.hub_shared_services.id
    hub_bastion         = azurerm_subnet.hub_bastion.id
    app_ingress         = azurerm_subnet.app_ingress.id
    app_workload        = azurerm_subnet.app_workload.id
    private_endpoints   = azurerm_subnet.app_private_endpoints.id
  }
}

output "network_security_group_ids" {
  description = "Network security group IDs."
  value = {
    ingress  = azurerm_network_security_group.ingress.id
    workload = azurerm_network_security_group.workload.id
  }
}

output "app_route_table_id" {
  description = "Application spoke route table ID."
  value       = azurerm_route_table.app.id
}

output "private_dns_zone" {
  description = "Private DNS zone name and ID."
  value = {
    name = azurerm_private_dns_zone.internal.name
    id   = azurerm_private_dns_zone.internal.id
  }
}
'@ | Set-Content -Path "networking-outputs.tf"
```

---

## Step 11 — Review the Terraform Files

Run:

```powershell
Get-ChildItem -Filter *.tf | Sort-Object Name
```

Phase 2 should add:

```text
networking-variables.tf
networking.tf
network-security.tf
routing.tf
private-dns.tf
networking-outputs.tf
```

Open the environment in VS Code:

```powershell
code .
```

Review:

- CIDR ranges do not overlap
- Resource names use `dev` and `scus`
- All resources use the Phase 1 network resource group
- No public IPs, gateways, firewalls, or expensive appliances are being created
- No secrets or subscription IDs are present

---

## Step 12 — Format, Initialize, and Validate

Format the configuration:

```powershell
terraform fmt -recursive
```

Initialize after adding the new resource types:

```powershell
terraform init -upgrade -backend-config=backend.hcl
```

Validate:

```powershell
terraform validate
```

Expected:

```text
Success! The configuration is valid.
```

### Provider schema troubleshooting

If Terraform reports that `bgp_route_propagation_enabled` is unsupported, check the installed AzureRM provider version:

```powershell
terraform providers
```

Then consult the provider documentation for the installed version. Do not guess or silently remove security-related settings.

---

## Step 13 — Create and Review the Terraform Plan

Create a saved plan:

```powershell
terraform plan -out=phase2.tfplan
```

Review it:

```powershell
terraform show phase2.tfplan
```

Confirm the plan creates only the expected network resources:

- 2 virtual networks
- 5 subnets
- 2 VNet peerings
- 2 NSGs
- 2 custom NSG rules
- 2 NSG associations
- 1 route table
- 2 route-table associations
- 1 private DNS zone
- 2 private DNS VNet links

The exact resource count may vary slightly if the provider represents nested items differently.

Stop if the plan includes:

- Destruction of Phase 1 resource groups
- Unexpected CIDR changes
- Public IP addresses
- Azure Firewall, VPN Gateway, or Bastion charges
- Resources in the wrong subscription or region

---

## Step 14 — Apply the Networking Plan

Apply the reviewed plan:

```powershell
terraform apply phase2.tfplan
```

Display the outputs:

```powershell
terraform output
```

Capture the terminal summary after the apply succeeds.

---

## Step 15 — Validate VNets and Subnets

List VNets:

```powershell
az network vnet list `
  --resource-group "rg-eaap-network-dev" `
  --query "[].{Name:name,AddressSpace:addressSpace.addressPrefixes[0],Location:location}" `
  --output table
```

List hub subnets:

```powershell
az network vnet subnet list `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-hub-dev-scus-001" `
  --query "[].{Name:name,Prefix:addressPrefix}" `
  --output table
```

List application spoke subnets:

```powershell
az network vnet subnet list `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-app-dev-scus-001" `
  --query "[].{Name:name,Prefix:addressPrefix}" `
  --output table
```

---

## Step 16 — Validate VNet Peering

List hub peerings:

```powershell
az network vnet peering list `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-hub-dev-scus-001" `
  --query "[].{Name:name,State:peeringState,Access:allowVirtualNetworkAccess,ForwardedTraffic:allowForwardedTraffic}" `
  --output table
```

List spoke peerings:

```powershell
az network vnet peering list `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-app-dev-scus-001" `
  --query "[].{Name:name,State:peeringState,Access:allowVirtualNetworkAccess,ForwardedTraffic:allowForwardedTraffic}" `
  --output table
```

Expected state:

```text
Connected
```

---

## Step 17 — Validate NSGs and Associations

List NSGs:

```powershell
az network nsg list `
  --resource-group "rg-eaap-network-dev" `
  --query "[].{Name:name,Location:location}" `
  --output table
```

Inspect the workload NSG rules:

```powershell
az network nsg rule list `
  --resource-group "rg-eaap-network-dev" `
  --nsg-name "nsg-eaap-workload-dev-scus-001" `
  --query "[].{Name:name,Priority:priority,Access:access,Direction:direction,Source:sourceAddressPrefix,DestinationPort:destinationPortRange}" `
  --output table
```

Inspect subnet associations:

```powershell
az network vnet subnet show `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-app-dev-scus-001" `
  --name "snet-workload-dev-scus-001" `
  --query "{Subnet:name,NSG:networkSecurityGroup.id,RouteTable:routeTable.id}" `
  --output json
```

Do not use the full resource-ID output in public screenshots unless cropped.

---

## Step 18 — Validate the Route Table

Show the route table:

```powershell
az network route-table show `
  --resource-group "rg-eaap-network-dev" `
  --name "rt-eaap-app-dev-scus-001" `
  --query "{Name:name,DisableBgpRoutePropagation:disableBgpRoutePropagation,Routes:routes}" `
  --output json
```

Expected:

- The route table exists
- It has no custom forced-tunneling route yet
- It is associated with the workload and private-endpoint subnets

This is intentional, not an incomplete deployment.

---

## Step 19 — Validate Private DNS

Show the private DNS zone:

```powershell
az network private-dns zone show `
  --resource-group "rg-eaap-network-dev" `
  --name "internal.contoso.com" `
  --query "{Name:name,RecordSets:numberOfRecordSets}" `
  --output table
```

List VNet links:

```powershell
az network private-dns link vnet list `
  --resource-group "rg-eaap-network-dev" `
  --zone-name "internal.contoso.com" `
  --query "[].{Name:name,Registration:registrationEnabled,State:virtualNetworkLinkState}" `
  --output table
```

Expected:

- Two VNet links
- Registration disabled
- Link state completed

No custom A record is required yet because no workload has been deployed.

---

## Step 20 — Confirm Terraform State and Idempotency

List the Phase 2 Terraform resources:

```powershell
terraform state list | Select-String "virtual_network|subnet|network_security|route_table|private_dns"
```

Run a second plan:

```powershell
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

Do not proceed to evidence completion if Terraform reports unexplained drift.

---

## Step 21 — Capture Evidence

Save screenshots under:

```text
screenshots/phase-2/
```

### Screenshot 1 — Hub and Spoke VNets

Portal path:

```text
Resource groups > rg-eaap-network-dev > Resources
```

Capture both VNets and their regions.

Filename:

```text
01-hub-spoke-vnets.png
```

### Screenshot 2 — Hub Subnets

Portal path:

```text
Virtual networks > vnet-eaap-hub-dev-scus-001 > Subnets
```

Filename:

```text
02-hub-subnets.png
```

### Screenshot 3 — Application Spoke Subnets

Portal path:

```text
Virtual networks > vnet-eaap-app-dev-scus-001 > Subnets
```

Filename:

```text
03-spoke-subnets.png
```

### Screenshot 4 — VNet Peerings

Capture both peerings with `Connected` status.

Filename:

```text
04-vnet-peerings.png
```

### Screenshot 5 — Network Security Groups

Capture the two NSGs and the workload rule list.

Filename:

```text
05-network-security-groups.png
```

### Screenshot 6 — Route Table

Capture the route table and associated subnets. It is acceptable that no custom routes exist yet.

Filename:

```text
06-route-table.png
```

### Screenshot 7 — Private DNS Links

Capture the private DNS zone and both VNet links.

Filename:

```text
07-private-dns-links.png
```

### Screenshot 8 — Terraform Apply

Capture the successful apply summary.

Filename:

```text
08-terraform-apply.png
```

### Screenshot 9 — Clean Plan

Capture:

```text
No changes. Your infrastructure matches the configuration.
```

Filename:

```text
09-clean-plan.png
```

Hide or crop subscription IDs, tenant IDs, user email addresses, and full resource IDs.

---

## Step 22 — Update the Case Study Evidence Links

Confirm the file exists at:

```text
docs/phase-2-enterprise-networking/README.md
```

GitHub will render the existing relative paths after the screenshots are added.

---

## Step 23 — Review Source-Control Safety

Return to the repository root:

```powershell
cd ..\..\..
```

Run:

```powershell
git status
```

Confirm the following are not staged:

- `backend.hcl`
- `terraform.tfvars`
- `.terraform/`
- `*.tfstate`
- `phase2.tfplan`
- Azure CLI logs containing IDs

Check ignored files:

```powershell
git check-ignore -v .\terraform\environments\dev\backend.hcl
git check-ignore -v .\terraform\environments\dev\phase2.tfplan
```

---

## Step 24 — Commit the Workstream

Stage safe files:

```powershell
git add README.md docs runbooks terraform screenshots
```

Review the staged changes:

```powershell
git diff --cached
```

Commit:

```powershell
git commit -m "Complete Workstream 2 enterprise networking"
```

Push:

```powershell
git push origin main
```

---

## Validation Checklist

- [ ] Dedicated EAAP subscription selected
- [ ] Phase 1 backend initialized successfully
- [ ] Phase 1 resource groups exist in Terraform state
- [ ] Hub VNet created with `10.10.0.0/16`
- [ ] Application spoke VNet created with `10.20.0.0/16`
- [ ] Five subnets created with non-overlapping prefixes
- [ ] Bidirectional VNet peerings report `Connected`
- [ ] Ingress and workload NSGs created
- [ ] NSGs associated with intended subnets
- [ ] HTTPS ingress-to-workload rule exists
- [ ] Explicit workload inbound deny rule exists
- [ ] Route table exists and is associated with intended subnets
- [ ] No invalid forced-tunneling route was added
- [ ] Private DNS zone created
- [ ] Both VNets linked to the private DNS zone
- [ ] Terraform apply succeeded
- [ ] Second Terraform plan reports no changes
- [ ] Screenshots captured and sanitized
- [ ] Sensitive local files remain excluded from Git

---

## Troubleshooting

### Terraform reports that the Phase 1 resource group does not exist

Confirm Workstream 1 was applied in the same Terraform state:

```powershell
terraform state list
```

If the resource groups exist in Azure but not in this state, stop. Do not create duplicates. Resolve the backend or state mismatch first.

### VNet peering remains `Initiated`

Confirm both directional peering resources were created. Azure VNet peering requires a peering object in each direction.

```powershell
az network vnet peering list `
  --resource-group "rg-eaap-network-dev" `
  --vnet-name "vnet-eaap-hub-dev-scus-001" `
  --output table
```

Then check the spoke.

### Address space overlap error

Confirm no existing VNet in the peering relationship uses overlapping ranges.

```powershell
az network vnet list `
  --query "[].{Name:name,Prefixes:addressSpace.addressPrefixes}" `
  --output table
```

Change the planned CIDRs in code rather than editing the deployed VNet manually.

### Subnet CIDR is outside the VNet address space

Check that:

- Hub subnets begin with `10.10`
- Spoke subnets begin with `10.20`
- The prefix length does not overlap another subnet

### Workload traffic fails in a later phase

The workload NSG intentionally denies inbound traffic except the explicit HTTPS rule. Review effective security rules and add only the flows required by the deployed service.

Do not delete the deny rule merely to make troubleshooting easier.

### Route table has no routes

This is intentional in Workstream 2. Custom forced tunneling is deferred until a valid firewall or virtual-appliance next hop exists.

### Private DNS links exist but names do not resolve

A VNet link provides zone visibility, but the zone must also contain a matching record. This workstream does not create an A record because no private workload endpoint exists yet.

### Policy blocks a network resource

Capture the policy definition and assignment names, then determine whether the Terraform configuration should be hardened. Do not create an exemption automatically.

---

## Cleanup Procedure

Keep the resources if you are continuing to Workstream 3.

To remove only the networking resources while preserving Phase 1, use targeted destruction carefully and only in a lab environment. A safer approach is to keep the workstream and destroy the entire environment only when the project is finished.

To preview complete environment destruction:

```powershell
cd terraform\environments\dev
terraform plan -destroy -out=destroy.tfplan
```

Do not apply the destruction plan unless you intend to remove both Workstream 1 and Workstream 2 resources.

---

## Workstream Completion Criteria

Workstream 2 is complete when:

- Hub and application spoke VNets exist with non-overlapping address spaces.
- Purpose-built subnets exist with the planned CIDRs.
- Both VNet peerings report `Connected`.
- NSGs and route-table associations are present.
- The private DNS zone is linked to both VNets.
- Terraform state contains all network resources.
- A second plan reports no changes.
- Evidence screenshots are added to the case study.
- Sensitive files remain outside source control.

---

## Next Workstream

**Workstream 3 — Identity and Secrets** will establish managed identities, Azure RBAC assignments, Key Vault, secret-access patterns, and private connectivity dependencies on top of this network foundation.
