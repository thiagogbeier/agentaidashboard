# Deployment

## PowerShell flow

`scripts/Deploy.ps1`:

1. Reads the active Azure CLI subscription and tenant.
2. Checks the target resource group for an existing deployment.
3. Reuses its single Managed Grafana resource and refuses resource-name conflicts that would create
   duplicate Grafana, Application Insights, or Log Analytics resources.
4. Generates a deterministic Grafana name only when the resource group has no Grafana resource and
   no name is supplied.
5. Displays every Azure and local setting.
6. Runs subscription-scope Bicep `what-if`.
7. Requires typing `YES`, case-insensitively, after the user reviews the preview.
8. Registers the required Azure providers.
9. Deploys or reconciles the Azure resources.
10. Imports Grafana dashboard `25053` when missing and saves its resource defaults.
11. Downloads OpenTelemetry Collector Contrib v0.161.0 and validates its SHA-256 checksum.
12. Configures VS Code Copilot Chat and GitHub Copilot CLI.
13. Registers `AgentAIDashboard-OtelCollector` as an at-logon Scheduled Task.
14. Writes ignored local deployment state and generates `status.html`.

The script is idempotent. Running it again reconciles the deployment without creating another
monitoring resource when the target resource group already contains one of that type.

## Azure Portal flow

The Deploy to Azure button uses `infra/azuredeploy.json`, compiled from `infra/main.bicep`.

Portal deployment creates the resource group, Log Analytics, Application Insights, Managed Grafana,
and managed-identity access. Leave the Grafana name as `auto` to generate a deterministic name from
the subscription ID. Leave the Grafana Admin principal as `current-deployer` to resolve the
deployment caller through Bicep's `deployer().objectId`; clear it only to skip that assignment.
Portal deployment cannot configure a user's workstation. Run the PowerShell script afterward with
matching names to complete the dashboard and local components.

The Portal **Region** selector is the location of the subscription-scope deployment record.
**Resource Location** is the region used by the deployed monitoring resources. These may differ.
The custom-deployment page may show **2 resources** because it counts the resource group and nested
deployment; the nested deployment contains the three monitoring resources and role assignments.

## Permissions

The deploying identity needs permission to:

- Create a resource group and the three Azure resource types.
- Create role assignments at the project resource-group and Grafana-resource scopes.
- Read the signed-in Entra user object ID.

No subscription-wide data-reader role is assigned to Grafana.

## Removal

Delete the Azure resource group to remove Azure resources and charges:

```powershell
az group delete --name rg-copilot-monitoring --yes --no-wait
```

Remove local runtime components:

```powershell
Unregister-ScheduledTask -TaskName AgentAIDashboard-OtelCollector -Confirm:$false
Remove-Item .\otelcol -Recurse -Force
Remove-Item .\otel-collector-config.yaml, .\status.html -Force -ErrorAction SilentlyContinue
```

The deployment script creates a backup of existing VS Code settings before changing OTel keys.
Restore or remove those keys manually if decommissioning.
