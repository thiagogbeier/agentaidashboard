# Architecture

```text
GitHub Copilot Chat / GitHub Copilot CLI
                   |
                   | OTLP/HTTP localhost:4318
                   | OTLP/gRPC localhost:4317
                   v
       OpenTelemetry Collector Contrib
                   |
                   | Azure Monitor exporter
                   v
          Application Insights
                   |
                   v
          Log Analytics workspace
                   |
                   | Azure Monitor data source
                   v
           Azure Managed Grafana
```

## Azure resources

The deployment creates one resource group containing:

- Log Analytics workspace
- Workspace-based Application Insights
- Azure Managed Grafana Standard
- Grafana managed-identity `Monitoring Reader` at the project resource-group scope
- Optional human `Grafana Admin` at the Grafana-resource scope

Resource-group scope is intentional. The GitHub Copilot dashboard uses Azure Resource Graph to
discover its Resource Group and Application Insights variables before querying telemetry.

## Local resources

The PowerShell deployment:

- Downloads a pinned OpenTelemetry Collector release from GitHub Releases.
- Verifies its SHA-256 checksum.
- Writes the live connection string only to ignored local runtime state.
- Configures VS Code Copilot Chat and GitHub Copilot CLI OTel export.
- Registers an at-logon Scheduled Task with restart-on-failure.
- Imports dashboard `25053` and sets its Azure resource defaults.
