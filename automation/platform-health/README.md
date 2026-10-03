# EAAP Platform Health Reporter

This read-only Python automation assesses the health of the Enterprise Azure Application Platform AKS cluster and the `eaap-app` namespace.

It authenticates with `DefaultAzureCredential`, which uses the active Azure CLI login during local execution. It queries the Workstream 6 Log Analytics workspace and generates timestamped JSON and Markdown health reports.

## Health signals

The reporter evaluates:

- AKS node readiness from `KubeNodeInventory`
- Application pod availability from `KubePodInventory`
- Application container restart counts from `KubePodInventory`
- Kubernetes Warning events from `KubeEvents`
- Application log error patterns from `ContainerLogV2`
- AKS control-plane error records from `AKSControlPlane`

## Prerequisites

- Python 3.10 or later
- Azure CLI installed and authenticated with `az login`
- Access to query the EAAP Log Analytics workspace
- Workstream 6 monitoring deployed and ingesting telemetry

## Setup

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform\automation\platform-health"

python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r .\requirements.txt
```

## Run

From the project root, retrieve the Log Analytics workspace customer ID:

```powershell
$workspaceId = az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query customerId `
  --output tsv
```

Run the reporter:

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform\automation\platform-health"

.\.venv\Scripts\Activate.ps1

python .\platform_health_report.py `
  --workspace-id "$workspaceId" `
  --namespace "eaap-app" `
  --time-window-hours 1 `
  --expected-running-pods 2 `
  --restart-warning-threshold 1
```

## Exit codes

- `0` — Healthy
- `1` — Warning
- `2` — Critical or invalid command-line input

A Warning status does not necessarily mean the application is down. It can indicate recent restart activity, warning events, matching application log messages, control-plane error records, incomplete telemetry, or an unavailable table.

## Output

Generated reports are saved under `reports/`:

```text
eaap-platform-health-<UTC timestamp>.json
eaap-platform-health-<UTC timestamp>.md
```

The report files are intentionally ignored by Git. Keep one sanitized Markdown report as evidence if desired, but do not commit sensitive identifiers or unreviewed telemetry.