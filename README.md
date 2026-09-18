# Agent AI Dashboard

Deploy a reusable GitHub Copilot telemetry pipeline with Azure Application Insights, Log Analytics,
Azure Managed Grafana, and a local OpenTelemetry Collector.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fthiagogbeier%2Fagentaidashboard%2Fmain%2Finfra%2Fazuredeploy.json)
[![validate](https://github.com/thiagogbeier/agentaidashboard/actions/workflows/validate.yml/badge.svg)](https://github.com/thiagogbeier/agentaidashboard/actions/workflows/validate.yml)

> **Cost notice:** Azure Managed Grafana Standard has a recurring charge. Log Analytics and
> Application Insights charge for ingestion and retention. Review current Azure pricing before
> deployment.

## What it deploys

```text
GitHub Copilot Chat / CLI
          |
          | OTLP localhost:4318 / 4317
          v
OpenTelemetry Collector Contrib
          |
          v
Application Insights -> Log Analytics -> Azure Managed Grafana
```

- One Azure resource group
- Log Analytics workspace
- Workspace-based Application Insights
- Azure Managed Grafana Standard
- GitHub Copilot Grafana dashboard, gallery ID `25053`
- Resource-group-scoped Monitoring Reader for the Grafana managed identity
- Grafana-resource-scoped Grafana Admin for the deploying user
- Pinned, checksum-verified Windows OpenTelemetry Collector
- VS Code and GitHub Copilot CLI telemetry settings
- Persistent Windows Scheduled Task for the Collector

## Recommended: one-command PowerShell deployment

### Requirements

- Windows 10/11
- PowerShell 7+
- Azure CLI
- Permission to create resources and role assignments in an Azure subscription
- VS Code with GitHub Copilot Chat and/or GitHub Copilot CLI

### Deploy

```powershell
git clone https://github.com/thiagogbeier/agentaidashboard.git
cd agentaidashboard
pwsh -NoProfile -File .\scripts\Deploy.ps1
```

The script performs read-only discovery, prints the complete deployment plan, and changes nothing
unless you type exactly `YES`.

Common overrides:

```powershell
.\scripts\Deploy.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -Location 'eastus' `
  -ResourceGroupName 'rg-my-copilot-monitoring' `
  -GrafanaName 'amg-my-unique-name' `
  -CaptureContent $false
```

`CaptureContent` defaults to `false`. Enabling it may export prompt/response content; review your
organization's data-handling requirements first.

## Azure Portal deployment

The **Deploy to Azure** button deploys the cloud resources from `infra/azuredeploy.json`.

Leave **Grafana Name** as `auto` to generate a deterministic, subscription-unique name. Leave
**Grafana Admin Principal Id** as `current-deployer` to grant access to the identity launching the
deployment. You can override either value; clear the principal ID only if you intentionally want to
skip the Grafana Admin assignment.

Azure Portal's **Region** stores the subscription-level deployment record. **Resource Location**
controls where the monitoring resources are created; the two values may differ.

![Custom deployment form showing default values: Region "(US) North Central US", Resource Location "canadacentral", Resource Group Name "rg-copilot-monitoring", Log Analytics Workspace Name "law-copilot-monitoring", Application Insights Name "appi-copilot-monitoring", Grafana Name "auto", Grafana Admin Principal Id "current-deployer"](docs/images/portal-deploy-defaults.png)

Leaving every field at its default, as shown above, is the recommended path:

- **Region** (`(US) North Central US`) only stores the subscription-level deployment record and does
  not affect where resources are created — ignore it.
- **Resource Location** (`canadacentral`) is what actually matters: the resource group, Log Analytics
  workspace, Application Insights, and Grafana are all created there.
- **Resource Group Name**, **Log Analytics Workspace Name**, and **Application Insights Name** keep
  their shown defaults (`rg-copilot-monitoring`, `law-copilot-monitoring`, `appi-copilot-monitoring`).
- **Grafana Name** = `auto` generates the deterministic name `amg-cop-<uniqueString(subscriptionId)>`.
- **Grafana Admin Principal Id** = `current-deployer` grants Grafana Admin to whichever identity is
  signed in to the Portal when you click **Review + create**.

These are exactly `Deploy.ps1`'s own parameter defaults, so with this form unchanged you can complete
the deployment with a single command and no name overrides:

```powershell
git clone https://github.com/thiagogbeier/agentaidashboard.git
cd agentaidashboard
pwsh -NoProfile -File .\scripts\Deploy.ps1 -SubscriptionId '<subscription-guid>'
```

After a Portal deployment, clone the repository and run `scripts/Deploy.ps1` with the same names.
The script is idempotent and completes the local Collector, dashboard import/defaults, user-scoped
settings, and status checks.

If you changed any field away from its default in the Portal, pass matching overrides to
`Deploy.ps1` instead of the single-parameter command above — match each parameter to the value you
typed:

```powershell
pwsh -NoProfile -File .\scripts\Deploy.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -Location 'eastus' `
  -ResourceGroupName '<value typed for Resource Group Name>' `
  -GrafanaName '<value typed for Grafana Name, omit if left as auto>'
```

`Deploy.ps1` has no parameter for **Grafana Admin Principal Id**; it always grants Grafana Admin to the
currently signed-in `az` identity, matching the Portal's `current-deployer` default.

The repository is public, so Azure Portal can download the ARM template directly from the button.
The Portal may summarize the template as **2 resources** because it counts the resource group and
its nested deployment at subscription scope; the nested deployment contains the monitoring
resources and role assignments listed above.

## Verify

```powershell
.\scripts\Status.ps1 -Open
```

The generated `status.html` checks Azure resources, the Grafana dashboard, recent telemetry, the
Scheduled Task, OTLP listener ports, and Copilot CLI settings.

For direct Azure verification, use the queries in [docs/KQL.md](docs/KQL.md).

## Repository layout

```text
.
|-- LICENSE
|-- README.md
|-- config/
|   |-- otel-collector-config.template.yaml
|   `-- vscode-settings.example.jsonc
|-- docs/
|   |-- ARCHITECTURE.md
|   |-- CODE_OF_CONDUCT.md
|   |-- CONTRIBUTING.md
|   |-- DEPLOYMENT.md
|   |-- KQL.md
|   |-- SECURITY.md
|   `-- TROUBLESHOOTING.md
|-- infra/
|   |-- azuredeploy.json
|   |-- main.bicep
|   `-- resources.bicep
|-- scripts/
|   |-- Deploy.ps1
|   `-- Status.ps1
`-- .github/workflows/validate.yml
```

## Security and privacy

- No tenant IDs, subscription IDs, connection strings, access tokens, or downloaded binaries are
  committed.
- Runtime configuration is generated locally into ignored files.
- Grafana uses managed identity rather than a client secret.
- See [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Deployment details](docs/DEPLOYMENT.md)
- [KQL query runbook](docs/KQL.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [License](LICENSE)
