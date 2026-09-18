# Troubleshooting

## Grafana shows No data

1. Run:

   ```powershell
   .\scripts\Status.ps1 -Open
   ```

2. Confirm `AgentAIDashboard-OtelCollector` is running.
3. Confirm ports 4317 and 4318 are listening.
4. Fully restart VS Code or start a new Copilot CLI process.
5. Generate Copilot activity and allow several minutes for ingestion.
6. Ensure the dashboard URL does not contain empty `var-rg=&var-res=` values.
7. Run the ingestion summary in `docs/KQL.md`.

## AppDependencies cannot be resolved

`AppDependencies` is a Log Analytics workspace table. If you opened Application Insights Logs, use
the lowercase `dependencies` table instead. `docs/KQL.md` contains both variants.

## Dashboard selectors are empty

The Grafana managed identity must have Monitoring Reader at the project resource-group scope. The
dashboard uses Azure Resource Graph to discover its Resource Group and Application Insights
variables. Workspace-only permission can query logs but cannot populate those selectors.

## Collector task is stopped

```powershell
Start-ScheduledTask -TaskName AgentAIDashboard-OtelCollector
Get-NetTCPConnection -State Listen -LocalPort 4317,4318
```

If it stops again, inspect:

```powershell
Get-ScheduledTaskInfo -TaskName AgentAIDashboard-OtelCollector
.\otelcol\otelcol-contrib.exe validate --config .\otel-collector-config.yaml
```

## Azure authentication fails

```powershell
az login
az account list --output table
az account set --subscription '<subscription-id>'
```
