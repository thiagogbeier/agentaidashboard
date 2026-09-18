# KQL Runbook — GitHub Copilot Telemetry

Use these queries to verify and troubleshoot the telemetry path:

```text
GitHub Copilot -> localhost:4318 -> OpenTelemetry Collector
               -> Application Insights -> Log Analytics -> Grafana
```

The resource names below are deployment defaults. Substitute the names supplied to
`scripts/Deploy.ps1` if you used overrides.

## Where to run the queries

Azure exposes the same workspace-based Application Insights data through two table-name schemes.
Use the query variant for the blade you opened:

| Azure Portal location | Table names |
|---|---|
| Application Insights `appi-copilot-monitoring` → **Monitoring** → **Logs** | `traces`, `dependencies`, `requests`, `customEvents`, `customMetrics` |
| Log Analytics `law-copilot-monitoring` → **Logs** | `AppTraces`, `AppDependencies`, `AppRequests`, `AppEvents`, `AppMetrics` |

Do not mix the two naming schemes in one query.

> **Error: `'union' operator: Failed to resolve table expression named 'AppDependencies'`**
>
> You opened **Application Insights → Logs** but pasted a workspace-native `App*` query. Use the
> lowercase Application Insights query in section 1, or change the query scope to the
> `law-copilot-monitoring` Log Analytics workspace before using section 2.

## 1. Application Insights — ingestion summary

Run this from:

**Azure Portal → `appi-copilot-monitoring` → Monitoring → Logs**

It proves whether data is stored and shows the most recent record by table and Copilot source.

```kusto
union withsource=TableName traces, dependencies, requests, customEvents, customMetrics
| where timestamp > ago(24h)
| summarize Events=count(), LastSeen=max(timestamp) by TableName, cloud_RoleName
| order by LastSeen desc
```

## 2. Log Analytics — ingestion summary

Run this from:

**Azure Portal → `law-copilot-monitoring` → Logs**

Workspace-native equivalent of query 1:

```kusto
union withsource=TableName AppTraces, AppDependencies, AppRequests, AppEvents, AppMetrics
| where TimeGenerated > ago(24h)
| summarize Events=count(), LastSeen=max(TimeGenerated) by TableName, AppRoleName
| order by LastSeen desc
```

## 3. Status-page aggregate

This is the aggregate used by `Build-Status.ps1`.

```kusto
union AppTraces, AppDependencies, AppRequests, AppEvents, AppMetrics
| where TimeGenerated > ago(7d)
| summarize
    Events=count(),
    LastSeen=max(TimeGenerated),
    CopilotEvents=countif(AppRoleName == "copilot-chat")
```

## 4. Most recent Copilot metrics

Copilot token, duration, and time-to-first-token measurements arrive in `customMetrics`.

```kusto
customMetrics
| where timestamp > ago(1h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| order by timestamp desc
| take 50
```

Expected metric names include:

- `gen_ai.client.token.usage`
- `gen_ai.client.operation.duration`
- `copilot_chat.time_to_first_token`

## 5. Metric inventory and freshness

```kusto
customMetrics
| where timestamp > ago(24h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| summarize
    Samples=count(),
    Total=sum(value),
    Average=avg(value),
    LastSeen=max(timestamp)
    by name, cloud_RoleName
| order by LastSeen desc
```

## 6. Token usage over time by model and token type

```kusto
customMetrics
| where timestamp > ago(7d)
| where name == "gen_ai.client.token.usage"
| extend
    Model=tostring(customDimensions["gen_ai.request.model"]),
    TokenType=tostring(customDimensions["gen_ai.token.type"])
| summarize Tokens=sum(value) by bin(timestamp, 1h), Model, TokenType, cloud_RoleName
| order by timestamp desc
```

If `TokenType` is empty, inspect query 4 to see the exact dimensions emitted by the installed
Copilot version.

## 7. Operation duration by model

```kusto
customMetrics
| where timestamp > ago(7d)
| where name == "gen_ai.client.operation.duration"
| extend Model=tostring(customDimensions["gen_ai.request.model"])
| summarize
    Requests=count(),
    Average=avg(value),
    P50=percentile(value, 50),
    P90=percentile(value, 90),
    P95=percentile(value, 95)
    by Model, cloud_RoleName
| order by Requests desc
```

## 8. Time to first token by model

```kusto
customMetrics
| where timestamp > ago(7d)
| where name == "copilot_chat.time_to_first_token"
| extend Model=tostring(customDimensions["gen_ai.request.model"])
| summarize
    Samples=count(),
    Average=avg(value),
    P50=percentile(value, 50),
    P90=percentile(value, 90),
    P95=percentile(value, 95)
    by Model, cloud_RoleName
| order by Samples desc
```

## 9. Recent GenAI operations

```kusto
dependencies
| where timestamp > ago(24h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| where tostring(customDimensions["gen_ai.operation.name"]) != ""
| extend
    Operation=tostring(customDimensions["gen_ai.operation.name"]),
    Model=coalesce(
        tostring(customDimensions["gen_ai.response.model"]),
        tostring(customDimensions["gen_ai.request.model"])
    ),
    SessionId=tostring(customDimensions["session.id"])
| project timestamp, cloud_RoleName, Operation, Model, name, duration, success, operation_Id, SessionId
| order by timestamp desc
| take 100
```

## 10. Token details recorded on inference traces

```kusto
traces
| where timestamp > ago(24h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| where tostring(customDimensions["gen_ai.operation.name"]) == "chat"
| extend
    Model=coalesce(
        tostring(customDimensions["gen_ai.response.model"]),
        tostring(customDimensions["gen_ai.request.model"])
    ),
    InputTokens=tolong(customDimensions["gen_ai.usage.input_tokens"]),
    OutputTokens=tolong(customDimensions["gen_ai.usage.output_tokens"]),
    SessionId=tostring(customDimensions["session.id"])
| project timestamp, cloud_RoleName, Model, InputTokens, OutputTokens, SessionId, operation_Id
| order by timestamp desc
```

## 11. Session activity

```kusto
dependencies
| where timestamp > ago(7d)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| extend SessionId=tostring(customDimensions["session.id"])
| where isnotempty(SessionId)
| summarize
    Operations=count(),
    FirstSeen=min(timestamp),
    LastSeen=max(timestamp),
    TotalDuration=sum(duration)
    by SessionId, cloud_RoleName
| order by LastSeen desc
```

## 12. Failed operations

```kusto
dependencies
| where timestamp > ago(7d)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| where success == false
| extend
    Operation=tostring(customDimensions["gen_ai.operation.name"]),
    Model=tostring(customDimensions["gen_ai.request.model"])
| project timestamp, cloud_RoleName, Operation, Model, name, resultCode, duration, operation_Id
| order by timestamp desc
```

## 13. Inspect one trace

Replace the value with a trace/operation ID selected in Grafana.

```kusto
let CopilotTraceId = "<operation-id>";
union traces, dependencies, requests, customEvents
| where operation_Id == CopilotTraceId
| order by timestamp asc
```

## 14. Detect ingestion gaps

```kusto
union traces, dependencies, customMetrics
| where timestamp > ago(24h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| summarize Events=count() by bin(timestamp, 15m), cloud_RoleName
| order by timestamp asc
```

Missing bins while Copilot was actively used usually mean the local Collector was stopped or the
client had not been restarted after its OTel settings were changed.

## 15. Confirm the synthetic readiness probe

The manually injected pipeline probe is intentionally labeled so it cannot be confused with real
Copilot activity.

```kusto
union traces, dependencies
| where timestamp > ago(24h)
| where name == "manual-pipeline-readiness-probe"
    or message contains "manual-pipeline-readiness-probe"
| project timestamp, itemType, name, message, operation_Id
| order by timestamp desc
```

## 16. Grafana panel smoke test

This matches the resource-scoped query pattern used by the Grafana dashboard.

```kusto
dependencies
| where timestamp > ago(24h)
| where cloud_RoleName in ("copilot-chat", "github-copilot")
| summarize Events=count(), LastSeen=max(timestamp)
```

## 17. Azure Resource Graph — discover Application Insights

Run this in **Azure Portal → Resource Graph Explorer**, not in Application Insights Logs. Grafana
uses this query pattern to populate its Resource Group selector.

```kusto
resources
| where type =~ "microsoft.insights/components"
| project subscriptionId, resourceGroup, name, location, id
| order by resourceGroup asc, name asc
```

## Azure CLI examples

Run an Application Insights resource-scoped query:

```powershell
az monitor app-insights query `
  --app appi-copilot-monitoring `
  --resource-group rg-copilot-monitoring `
  --analytics-query "customMetrics | where timestamp > ago(1h) | order by timestamp desc | take 5"
```

The `Build-Status.ps1` implementation queries the workspace REST API because
`az monitor log-analytics query` requires the optional `log-analytics` Azure CLI extension.
