[CmdletBinding()]
param(
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repositoryRoot '.state\deployment.json'
$outputPath = Join-Path $repositoryRoot 'status.html'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Local deployment state was not found. An Azure Portal deployment creates only the Azure resources. Run scripts\Deploy.ps1 to validate and reuse the existing resources, configure this workstation, and generate the state file."
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$checks = [System.Collections.Generic.List[object]]::new()
$checkedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

function Add-Check {
    param(
        [string]$Item,
        [string]$Area,
        [ValidateSet('pass', 'warning', 'fail')][string]$State,
        [string]$Description,
        [string]$Help = ''
    )

    if ([string]::IsNullOrWhiteSpace($Help)) {
        $Help = switch ($Area) {
            'Azure' { 'Review the deployment resource group in Azure Portal.' }
            'Grafana' { 'Open the Managed Grafana endpoint and review the GitHub Copilot dashboard.' }
            default { 'Re-run scripts\Deploy.ps1 to repair the local configuration.' }
        }
    }

    $checks.Add([pscustomobject]@{
            Item = $Item
            Area = $Area
            State = $State
            Description = $Description
            CheckedAt = $checkedAt
            Help = $Help
        })
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

try {
    $account = Invoke-AzJson @('account', 'show', '--output', 'json')
    $matches = $account.id -eq $state.subscriptionId -and $account.tenantId -eq $state.tenantId
    Add-Check 'Azure context' 'Azure' $(if ($matches) { 'pass' } else { 'fail' }) $(if ($matches) {
            "Connected to $($account.name)."
        } else {
            'The active Azure subscription/tenant does not match deployment state.'
        })
}
catch {
    Add-Check 'Azure context' 'Azure' 'fail' $_.Exception.Message
}

try {
    $resources = @(Invoke-AzJson @(
            'resource', 'list',
            '--resource-group', [string]$state.resourceGroupName,
            '--output', 'json'
        ))
    $expected = @(
        [string]$state.logAnalyticsWorkspaceName,
        [string]$state.applicationInsightsName,
        [string]$state.grafanaName
    )
    $missing = @($expected | Where-Object { $_ -notin $resources.name })
    Add-Check 'Azure resources' 'Azure' $(if ($missing.Count -eq 0) { 'pass' } else { 'fail' }) $(if ($missing.Count -eq 0) {
            "All core resources are present in $($state.resourceGroupName)."
        } else {
            "Missing: $($missing -join ', ')."
        })
}
catch {
    Add-Check 'Azure resources' 'Azure' 'fail' $_.Exception.Message
}

try {
    $grafana = Invoke-AzJson @(
        'grafana', 'show',
        '--resource-group', [string]$state.resourceGroupName,
        '--name', [string]$state.grafanaName,
        '--output', 'json'
    )
    $ready = $grafana.properties.provisioningState -eq 'Succeeded'
    Add-Check 'Managed Grafana' 'Azure' $(if ($ready) { 'pass' } else { 'fail' }) "Provisioning state: $($grafana.properties.provisioningState)."
}
catch {
    Add-Check 'Managed Grafana' 'Azure' 'fail' $_.Exception.Message
}

try {
    $dashboards = @(Invoke-AzJson @(
            'grafana', 'dashboard', 'list',
            '--resource-group', [string]$state.resourceGroupName,
            '--name', [string]$state.grafanaName,
            '--output', 'json'
        ))
    $present = @($dashboards | Where-Object uid -eq 'GitHubCopilot').Count -gt 0
    Add-Check 'GitHub Copilot dashboard' 'Grafana' $(if ($present) { 'pass' } else { 'fail' }) $(if ($present) {
            'Dashboard UID GitHubCopilot is installed.'
        } else {
            'Dashboard UID GitHubCopilot is missing.'
        })
}
catch {
    Add-Check 'GitHub Copilot dashboard' 'Grafana' 'fail' $_.Exception.Message
}

try {
    $workspace = Invoke-AzJson @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--resource-group', [string]$state.resourceGroupName,
        '--workspace-name', [string]$state.logAnalyticsWorkspaceName,
        '--output', 'json'
    )
    $queryBody = @{
        query = 'union AppTraces, AppDependencies, AppRequests, AppEvents, AppMetrics | where TimeGenerated > ago(7d) | summarize Events=count(), LastSeen=max(TimeGenerated), CopilotEvents=countif(AppRoleName in ("copilot-chat", "github-copilot"))'
    } | ConvertTo-Json -Compress
    $queryFile = Join-Path ([System.IO.Path]::GetTempPath()) "agent-ai-status-$([guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($queryFile, $queryBody, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-AzJson @(
            'rest',
            '--method', 'post',
            '--url', "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/query",
            '--resource', 'https://api.loganalytics.io',
            '--headers', 'Content-Type=application/json',
            '--body', "@$queryFile",
            '--output', 'json'
        )
    }
    finally {
        if (Test-Path -LiteralPath $queryFile) {
            Remove-Item -LiteralPath $queryFile -Force
        }
    }

    $row = @($result.tables[0].rows)[0]
    $events = if ($null -eq $row) { 0 } else { [long]$row[0] }
    $copilotEvents = if ($null -eq $row) { 0 } else { [long]$row[2] }
    Add-Check 'Recent telemetry' 'Azure' $(if ($events -gt 0) { 'pass' } else { 'warning' }) $(if ($events -gt 0) {
            "$events records in seven days, including $copilotEvents Copilot records."
        } else {
            'No telemetry records found in the last seven days.'
        })
}
catch {
    Add-Check 'Recent telemetry' 'Azure' 'fail' $_.Exception.Message
}

$task = Get-ScheduledTask -TaskName ([string]$state.collectorTaskName) -ErrorAction SilentlyContinue
$taskReady = $null -ne $task -and $task.State -eq 'Running'
Add-Check 'Collector Scheduled Task' 'Local' $(if ($taskReady) { 'pass' } else { 'fail' }) $(if ($taskReady) {
        "$($state.collectorTaskName) is running."
    } else {
        "$($state.collectorTaskName) is missing or stopped."
    })

$collectorExecutable = Join-Path $repositoryRoot 'otelcol\otelcol-contrib.exe'
$collectorConfiguration = Join-Path $repositoryRoot 'otel-collector-config.yaml'
$collectorFilesReady = (Test-Path -LiteralPath $collectorExecutable -PathType Leaf) -and
    (Test-Path -LiteralPath $collectorConfiguration -PathType Leaf)
Add-Check 'Collector files' 'Local' $(if ($collectorFilesReady) { 'pass' } else { 'fail' }) $(if ($collectorFilesReady) {
        'The Collector executable and generated configuration are present.'
    } else {
        'The Collector executable or generated configuration is missing.'
    })

$ports = @(Get-NetTCPConnection -State Listen -LocalPort 4317, 4318 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty LocalPort -Unique)
$portsReady = 4317 -in $ports -and 4318 -in $ports
Add-Check 'OTLP listeners' 'Local' $(if ($portsReady) { 'pass' } else { 'fail' }) $(if ($portsReady) {
        'Ports 4317 and 4318 are listening.'
    } else {
        'One or both OTLP listener ports are closed.'
    })

$vsCodeSettingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
$vsCodeSettingsReady = $false
if (Test-Path -LiteralPath $vsCodeSettingsPath -PathType Leaf) {
    $vsCodeSettings = Get-Content -LiteralPath $vsCodeSettingsPath -Raw
    $vsCodeSettingsReady =
        $vsCodeSettings -match '"github\.copilot\.chat\.otel\.enabled"\s*:\s*true' -and
        $vsCodeSettings -match '"github\.copilot\.chat\.otel\.exporterType"\s*:\s*"otlp-http"' -and
        $vsCodeSettings -match '"github\.copilot\.chat\.otel\.otlpEndpoint"\s*:\s*"http://localhost:4318"'
}
Add-Check 'VS Code settings' 'Local' $(if ($vsCodeSettingsReady) { 'pass' } else { 'fail' }) $(if ($vsCodeSettingsReady) {
        'GitHub Copilot Chat exports OTLP telemetry to localhost:4318.'
    } else {
        "Required GitHub Copilot OTel settings are missing from $vsCodeSettingsPath."
    }) 'Restart VS Code after settings change, then start a new Copilot Chat session.'

$environmentReady = [Environment]::GetEnvironmentVariable('COPILOT_OTEL_ENABLED', 'User') -eq 'true' -and
    [Environment]::GetEnvironmentVariable('COPILOT_OTEL_EXPORTER_TYPE', 'User') -eq 'otlp-http' -and
    [Environment]::GetEnvironmentVariable('OTEL_EXPORTER_OTLP_ENDPOINT', 'User') -eq 'http://localhost:4318'
Add-Check 'Copilot CLI settings' 'Local' $(if ($environmentReady) { 'pass' } else { 'fail' }) $(if ($environmentReady) {
        'User-scope OTel variables are configured.'
    } else {
        'One or more User-scope OTel variables are missing.'
    })

$passCount = @($checks | Where-Object State -eq 'pass').Count
$warningCount = @($checks | Where-Object State -eq 'warning').Count
$failCount = @($checks | Where-Object State -eq 'fail').Count

function ConvertTo-HtmlText {
    param([object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

$rows = foreach ($check in $checks) {
    "<tr class='$($check.State)'><td>$(ConvertTo-HtmlText $check.Item)</td><td>$(ConvertTo-HtmlText $check.Area)</td><td>$(ConvertTo-HtmlText $check.Description)</td><td>$($check.State.ToUpperInvariant())</td><td><time>$(ConvertTo-HtmlText $check.CheckedAt)</time><small>$(ConvertTo-HtmlText $check.Help)</small></td></tr>"
}

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent AI Dashboard Status</title>
<style>
:root{color-scheme:dark;--bg:#08100d;--panel:#101b17;--line:#294238;--text:#dfeae5;--muted:#8da39a;--ok:#8bf09b;--warn:#ffd166;--bad:#ff7468}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,sans-serif}main{max-width:1200px;margin:auto;padding:42px 22px}
h1{font-size:clamp(38px,7vw,76px);line-height:.9;margin:0 0 12px}p{color:var(--muted)}.summary{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:28px 0}
.card{background:var(--panel);border:1px solid var(--line);padding:18px}.card strong{display:block;font-size:34px}.pass strong{color:var(--ok)}.warning strong{color:var(--warn)}.fail strong{color:var(--bad)}
table{width:100%;border-collapse:collapse;background:var(--panel)}th,td{padding:13px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted)}tr.pass td:nth-child(4){color:var(--ok)}tr.warning td:nth-child(4){color:var(--warn)}tr.fail td:nth-child(4){color:var(--bad)}time,small{display:block;white-space:nowrap}small{color:var(--muted);white-space:normal;margin-top:5px}
@media(max-width:700px){.summary{grid-template-columns:1fr}table{font-size:13px}}
</style>
</head>
<body><main>
<p>Agent AI Dashboard / live deployment check</p>
<h1>STATUS</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') for $($state.subscriptionName).</p>
<section class="summary">
<div class="card pass"><strong>$passCount</strong>passing</div>
<div class="card warning"><strong>$warningCount</strong>attention</div>
<div class="card fail"><strong>$failCount</strong>blocking</div>
</section>
<table><thead><tr><th>Item</th><th>Location</th><th>Description</th><th>Status</th><th>Checked at / help</th></tr></thead><tbody>
$($rows -join [Environment]::NewLine)
</tbody></table>
</main></body></html>
"@

[System.IO.File]::WriteAllText($outputPath, $html, [System.Text.UTF8Encoding]::new($false))
Write-Host "Generated $outputPath"
Write-Host "Passing: $passCount | Attention: $warningCount | Blocking: $failCount"

if ($Open) {
    Start-Process $outputPath
}
