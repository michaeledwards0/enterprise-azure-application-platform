<div align="center">

# Workstream 4: Container Platform
### Azure Container Registry, AKS, Node Pools, Workload Identity, Key Vault CSI, and Private Service Exposure

**Contoso Digital Services | Microsoft Azure | Terraform | Docker | Azure Container Registry | Azure Kubernetes Service**

</div>

---

## Executive Summary

I deployed the first container platform layer for the Enterprise Azure Application Platform.

This workstream introduces Azure Container Registry, an Azure Kubernetes Service cluster attached to the existing workload subnet, separate system and user node pools, Microsoft Entra integration, OIDC issuer, Workload Identity, Azure Key Vault Secrets Store CSI integration, and a private Azure Load Balancer frontend placed in the dedicated ingress subnet.

> **Outcome:** The platform can build and store container images, run replicated workloads on AKS, pull images through managed identity, retrieve secrets through workload identity, and expose an application privately without giving the workload nodes public IP addresses.

---

## Project Snapshot

| Category | Details |
|---|---|
| **Platform** | Microsoft Azure |
| **Business scenario** | Managed container platform for enterprise application workloads |
| **Primary focus** | Container registry, Kubernetes cluster, node-pool separation, identity, secret delivery, and private exposure |
| **Key services** | Azure Container Registry, Azure Kubernetes Service, Microsoft Entra Workload ID, Key Vault CSI Driver, Azure Load Balancer |
| **Engineering tools** | Terraform, Azure CLI, Docker, kubectl, PowerShell, Git |
| **Deployment model** | Added to the existing EAAP Terraform environment and remote state |
| **Validation** | Image push, cluster access, node readiness, workload identity, secret mount, service private IP, replica health, clean plan |

---

## Business Context

The landing zone, network foundation, and secrets platform are available, but the organization still needs a managed runtime for containerized applications.

The platform must separate system components from application workloads, avoid static cloud credentials, retrieve secrets securely, and expose services through a controlled network entry point.

---

## Engineering Challenge

The design needed to:

- Reuse the existing workload and ingress subnets
- Avoid public IP addresses on AKS nodes
- Separate system and user workloads
- Restrict Kubernetes API access to the approved workstation
- Allow AKS to pull images without ACR admin credentials
- Give pods access to Key Vault without Azure client secrets
- Preserve the Phase 2 deny-by-default NSG design
- Place the service frontend in the ingress subnet
- Keep the platform cost-aware
- Avoid relying on a legacy ingress controller with a near-term support deadline

---

## Target Architecture

```mermaid
flowchart LR
    Engineer[Cloud Engineer]
    Docker[Docker Build]
    ACR[Azure Container Registry]
    API[AKS API Server\nAuthorized IP Range]
    AKS[AKS Cluster]
    Sys[System Node Pool]
    User[User Node Pool]
    Pod[Sample Application Pods]
    ILB[Internal Azure Load Balancer\nIngress Subnet]
    UAMI[Workload Managed Identity]
    KV[Azure Key Vault]
    CSI[Secrets Store CSI Driver]

    Engineer --> Docker
    Docker --> ACR
    Engineer --> API
    API --> AKS
    ACR -->|AcrPull through kubelet identity| AKS
    AKS --> Sys
    AKS --> User
    User --> Pod
    ILB --> Pod
    Pod --> CSI
    CSI --> UAMI
    UAMI -->|Workload Identity federation| KV
```

---

## What I Implemented

### Azure Container Registry

The registry stores the project container images.

Security controls include:

- Admin user disabled
- Microsoft Entra authentication
- `AcrPush` for the engineer during local validation
- `AcrPull` for the AKS kubelet identity
- No registry password embedded in Kubernetes manifests

### Azure Kubernetes Service

The cluster uses:

- The existing application workload subnet
- Azure CNI Overlay networking
- System-assigned cluster identity
- Microsoft Entra integration
- Azure RBAC for Kubernetes authorization
- OIDC issuer
- Microsoft Entra Workload ID
- Key Vault Secrets Store CSI add-on
- API server authorized IP ranges
- No public IP addresses on nodes

### System and User Node Pools

The system node pool hosts critical Kubernetes and AKS components.

A separate user node pool hosts the sample application. This creates a foundation for independent scaling, workload scheduling, different VM sizes, and separate lifecycle decisions.

### Workload Identity Federation

The Kubernetes service account is federated to the user-assigned managed identity created in Workstream 3.

The application can request Key Vault access without client secrets, service-principal passwords, or Azure credentials stored in a Kubernetes Secret.

### Private Service Exposure

The sample application is exposed through an internal Azure Load Balancer.

The frontend private IP is allocated from:

```text
snet-ingress-dev-scus-001
```

The application pods remain in the AKS workload subnet.

This validates:

```text
Approved internal client
        ↓
Ingress subnet private frontend
        ↓
AKS workload nodes and pods
```

This workstream establishes private Layer 4 exposure. A later phase can add Kubernetes Gateway API or Application Gateway for Containers for Layer 7 routing, TLS policy, WAF, and traffic splitting.

---

## Key Engineering Decisions and Tradeoffs

| Decision | Rationale | Tradeoff |
|---|---|---|
| Use AKS | Azure manages the Kubernetes control plane and integrates with Azure identity and networking | Engineers still manage node pools, upgrades, policy, and workloads |
| Use Azure CNI Overlay | Conserves VNet IP space while preserving Azure networking integration | Pod networking differs from traditional flat Azure CNI |
| Use separate system and user pools | Separates platform components from application workloads | Requires at least two node pools |
| Restrict the API server by IP | Allows local administration without internet-wide API exposure | Public IP changes require an update |
| Disable ACR admin credentials | Enforces identity-based image access | Engineers and pipelines need explicit RBAC |
| Use Workload Identity | Removes long-lived Azure credentials from pods | Requires OIDC, federation, service-account annotations, and RBAC |
| Use a private LoadBalancer service | Validates the ingress subnet without exposing the application publicly | Direct testing requires VNet connectivity or port forwarding |
| Defer full Layer 7 ingress | Avoids a transitional ingress controller and keeps the phase focused | Gateway API, WAF, and TLS routing are deferred |

---

## Implementation Issues Anticipated

### Existing NSG blocks AKS traffic

The Phase 2 workload NSG contains an explicit deny rule.

**Resolution:** Add explicit rules for workload-subnet internal traffic and Azure Load Balancer traffic before creating AKS.

### AKS needs permission on the ingress subnet

The internal Load Balancer frontend is created in a subnet different from the AKS node subnet.

**Resolution:** Give the AKS cluster identity Network Contributor on the ingress subnet.

### ACR pull authorization

Creating AKS and ACR does not automatically guarantee image-pull access.

**Resolution:** Assign `AcrPull` to the AKS kubelet identity at the registry scope.

### Federation depends on the AKS OIDC issuer

The federated credential cannot be completed until the cluster exposes its issuer URL.

**Resolution:** Enable OIDC and Workload Identity on the cluster, then create the federated credential from the issuer URL.

---

## Results and Validation

| Result | Validation |
|---|---|
| Registry deployed | ACR exists with admin user disabled |
| Container image published | Repository and tag appear in ACR |
| AKS operational | Cluster provisioning state is Succeeded |
| Node pools separated | System and user pools both report Ready nodes |
| API access restricted | Authorized IP range contains only approved ranges |
| Image pulls use identity | AKS kubelet identity has AcrPull |
| Pod secret access uses federation | Pod mounts a Key Vault value without an Azure client secret |
| Application replicated | Two sample application pods report Ready |
| Private exposure created | LoadBalancer receives a private IP in the ingress subnet |
| Platform synchronized | Follow-up Terraform plan reports no changes |

---

## Evidence

| Evidence | What It Proves | Screenshot |
|---|---|---|
| ACR overview | Registry exists with expected settings | <img width="1012" height="404" alt="image" src="https://github.com/user-attachments/assets/8dbfa6ab-dd2d-4f31-b93a-38504834de02" /> |
| ACR repository | Sample image was pushed | <img width="922" height="232" alt="image" src="https://github.com/user-attachments/assets/5caf0313-9a38-499d-96fd-15476b00d4cd" /> |
| AKS overview | Cluster deployed successfully | <img width="1016" height="217" alt="image" src="https://github.com/user-attachments/assets/daab32d4-e4aa-4f73-80fa-21bbe1bbccb3" /> |
| Node pools | System and user pools exist | <img width="1200" height="384" alt="image" src="https://github.com/user-attachments/assets/79a7b32d-67ac-42ad-826f-1dbb86ebabe5" /> |
| Authorized IP ranges | API server access is restricted | <img width="916" height="349" alt="image" src="https://github.com/user-attachments/assets/465d1568-8324-46f0-be5c-e327ce9a984f" /> |
| Workload identity | OIDC and federation are configured | <img width="1229" height="540" alt="image" src="https://github.com/user-attachments/assets/6fc4419b-bc6f-4384-abb3-7996f2f0b36c" /> |
| Key Vault CSI | SecretProviderClass and mounted secret validated | <img width="929" height="389" alt="image" src="https://github.com/user-attachments/assets/5ff85680-421b-4812-a1e1-a3fc13278075" /> |
| Running workload | Two application pods are Ready | <img width="1171" height="312" alt="image" src="https://github.com/user-attachments/assets/d2c763d2-bc18-4626-8591-835e37ae0ef6" /> |
| Private service IP | Service uses an ingress-subnet private IP | <img width="911" height="219" alt="image" src="https://github.com/user-attachments/assets/ebe03c21-9879-4340-967f-8847d5f9b563" /> |
| Clean plan | Terraform and Azure remain synchronized | <img width="1141" height="137" alt="image" src="https://github.com/user-attachments/assets/6210578d-6b51-44d1-a3d1-9481d6eed9f7" /> |

---

## Skills Demonstrated

- Docker image build and registry workflows
- Azure Container Registry RBAC
- AKS cluster and node-pool design
- Azure CNI Overlay
- Kubernetes administration with kubectl
- Microsoft Entra integration and Azure RBAC
- OIDC and Workload Identity federation
- Key Vault CSI secret delivery
- Internal load balancing and subnet permissions
- Terraform dependency management
- Cost and security tradeoff analysis

---

## Next Workstream

**Workstream 5 — CI/CD Automation** will use GitHub Actions and workload identity federation to validate Terraform, build the application image, push to ACR, and deploy Kubernetes manifests without long-lived cloud credentials.
