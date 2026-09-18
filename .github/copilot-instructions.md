# Copilot instructions for agentaidashboard

This repo deploys a GitHub Copilot telemetry pipeline: **Copilot Chat/CLI → OTLP (localhost:4317/4318)
→ OpenTelemetry Collector Contrib → Application Insights → Log Analytics → Azure Managed Grafana**
(dashboard `25053`, UID `GitHubCopilot`). There is no application code to build/run — the repository
*is* the deployment tooling (Bicep + PowerShell).

## Validate changes (mirrors `.github/workflows/validate.yml`)

There's no test suite. CI/local validation is three checks; run the one relevant to what you changed:

```powershell
# Any .ps1 file: parse-check syntax (no execution)
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\scripts\Deploy.ps1', [ref]$null, [ref]$errors) | Out-Null
$errors

# Bicep changes: must compile, and main.bicep + azuredeploy.json must stay in sync (see below)
az bicep build --file .\infra\main.bicep --outfile .\infra\azuredeploy.json

# Any file: CI rejects these secret patterns anywhere in the repo (excluding .git)
# InstrumentationKey=<36-hex-guid>, glsa_*, client_secret: "..."
```

To exercise the deploy script without changing Azure, run `.\scripts\Deploy.ps1` and answer the
confirmation prompt with anything other than the exact string `YES` — it prints the full plan/what-if
and exits cleanly ("Cancelled. No changes were made.").

## Architecture — two-phase, idempotent deployment

1. **Cloud phase** (Bicep, subscription-scoped): `infra/main.bicep` creates the resource group, then
   invokes `infra/resources.bicep` (resource-group-scoped module) for the Log Analytics workspace,
   workspace-based Application Insights, Azure Managed Grafana (Standard), and two **least-privilege**
   role assignments — Grafana Admin (scoped to the Grafana resource only) and Monitoring Reader
   (scoped to the resource group only, granted to Grafana's system-assigned managed identity, needed
   because the dashboard uses Azure Resource Graph to resolve its RG/App Insights variables).
2. **Local phase** (`scripts/Deploy.ps1`, Windows-only): downloads and checksum-verifies a pinned
   OpenTelemetry Collector release, writes `otel-collector-config.yaml` with the live App Insights
   connection string, merges VS Code/Copilot CLI OTel settings, registers the
   `AgentAIDashboard-OtelCollector` Scheduled Task, imports/updates the Grafana dashboard, and writes
   `.state/deployment.json` (gitignored — this is what `scripts/Status.ps1` reads to verify state).

**`infra/azuredeploy.json` is a generated artifact of `infra/main.bicep`**, not hand-edited — the
Azure Portal "Deploy to Azure" button fetches `azuredeploy.json` directly from `main` via a raw
GitHub URL, so any change to `main.bicep`/`resources.bicep` must be followed by rebuilding
`azuredeploy.json` (see command above) and committing both.

`scripts/Status.ps1` works two ways: if `.state/deployment.json` exists it uses that; otherwise it
falls back to discovering resources live via `az resource list` against `-ResourceGroupName` (default
`rg-copilot-monitoring`). Either path then checks Grafana provisioning state, dashboard presence,
7-day Log Analytics telemetry volume, the Scheduled Task, listener ports 4317/4318, VS Code settings,
and Copilot CLI env vars, then renders `reports/status.html` (gitignored).

## Key conventions / gotchas

- **Grafana naming is `auto` by default** in both `main.bicep` and `azuredeploy.json`, computed
  identically as `amg-cop-${uniqueString(subscription().subscriptionId)}`. This must stay identical in
  both files. If a Grafana instance with a *different* name already exists in the target resource
  group (e.g. from a manual/prior deployment), leaving `-GrafanaName` blank creates a **second,
  duplicate** Grafana Standard instance (extra recurring cost) rather than reusing the existing one —
  always pass `-GrafanaName '<existing-name>'` explicitly when a Grafana resource already exists.
- `grafanaAdminPrincipalId` defaults to the literal string `current-deployer`, resolved via Bicep's
  `deployer().objectId`; clearing it (empty string) skips that role assignment (`resources.bicep`'s
  `grafanaAdmin` resource has an `if (!empty(...))` condition).
- Built-in role definition GUIDs are hardcoded in Bicep rather than looked up by display name:
  Monitoring Reader = `43d0d8ad-25c7-4714-9337-8ba259a9fe05`, Grafana Admin =
  `22926164-76b3-42b3-bc55-97df8dab3e41`.
- `Deploy.ps1`'s confirmation gate is **case-sensitive** (`-cne 'YES'` in PowerShell) even though
  `docs/DEPLOYMENT.md` currently describes it as case-insensitive — only the exact uppercase `YES`
  proceeds.
- Portal's **Region** field only locates the subscription-scope deployment *record*; **Resource
  Location** (default `canadacentral`) is the actual region every resource is created in — they're
  independent and commonly differ.
- Never commit tenant IDs, subscription IDs, connection strings, tokens, or the generated
  `.state/`, `otelcol/`, `otel-collector-config.yaml`, or `reports/` (all gitignored). The App
  Insights connection string is treated as sensitive (ingestion-only) and only ever written to the
  ignored local config file.
- PowerShell scripts follow `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`, and
  always run `az deployment sub what-if` before `az deployment sub create` so changes are previewable.
