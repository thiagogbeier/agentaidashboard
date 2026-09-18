[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$Location = 'canadacentral',
    [string]$ResourceGroupName = 'rg-copilot-monitoring',
    [string]$LogAnalyticsWorkspaceName = 'law-copilot-monitoring',
    [string]$ApplicationInsightsName = 'appi-copilot-monitoring',
    [string]$GrafanaName,
    [string]$CollectorVersion = '0.161.0',
    [bool]$CaptureContent = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repositoryRoot 'infra\main.bicep'
$stateDirectory = Join-Path $repositoryRoot '.state'
$collectorDirectory = Join-Path $repositoryRoot 'otelcol'
$collectorConfigPath = Join-Path $repositoryRoot 'otel-collector-config.yaml'
$statePath = Join-Path $stateDirectory 'deployment.json'
$statusScriptPath = Join-Path $PSScriptRoot 'Status.ps1'
$taskName = 'AgentAIDashboard-OtelCollector'

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [switch]$AllowEmptyOutput
    )

    $output = & $FilePath @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $AllowEmptyOutput -and [string]::IsNullOrWhiteSpace($text)) {
        throw "$FilePath $($ArgumentList -join ' ') returned no output."
    }

    return $text
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    return (Invoke-NativeCommand -FilePath 'az' -ArgumentList $ArgumentList) | ConvertFrom-Json
}

function Resolve-ExistingResourceName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Resources,

        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$ResourceLabel,

        [AllowEmptyString()]
        [string]$RequestedName,

        [Parameter(Mandatory)]
        [bool]$NameWasSpecified
    )

    $matchingResources = @($Resources | Where-Object type -eq $ResourceType)
    $activeResources = foreach ($resource in $matchingResources) {
        try {
            $details = Invoke-AzJson -ArgumentList @(
                'resource', 'show',
                '--ids', [string]$resource.id,
                '--output', 'json'
            )
        }
        catch {
            if ($_.Exception.Message -match 'ResourceNotFound|could not be found|was not found') {
                Write-Warning "Ignoring stale $ResourceLabel '$($resource.name)' because it no longer exists."
                continue
            }
            throw
        }

        $provisioningStateProperty = $details.properties.PSObject.Properties['provisioningState']
        if ($null -ne $provisioningStateProperty -and
            $provisioningStateProperty.Value -in 'Deleting', 'Deleted') {
            Write-Warning "Ignoring $ResourceLabel '$($details.name)' because it is $($provisioningStateProperty.Value)."
            continue
        }
        $details
    }

    $activeResources = @($activeResources)
    if ($activeResources.Count -eq 0) {
        throw "Resource group '$ResourceGroupName' already exists but has no $ResourceLabel. Refusing to add resources to a partial or unrelated environment."
    }
    if ($activeResources.Count -gt 1) {
        throw "Resource group '$ResourceGroupName' contains multiple active ${ResourceLabel}s: $($activeResources.name -join ', '). Refusing to guess which one to use."
    }

    $existingName = [string]$activeResources[0].name
    if ($NameWasSpecified -and $RequestedName -ne $existingName) {
        throw "$ResourceLabel '$RequestedName' does not match existing resource '$existingName' in '$ResourceGroupName'. Refusing to create a duplicate."
    }

    Write-Host "Reusing existing $ResourceLabel '$existingName'." -ForegroundColor DarkGreen
    return $existingName
}

function Get-RunningOtlpCollector {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationInsightsConnectionString
    )

    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 4317, 4318 -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) {
        return $null
    }

    $ports = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
    $processIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    if (4317 -notin $ports -or 4318 -notin $ports -or $processIds.Count -ne 1) {
        throw 'OTLP ports 4317 and 4318 are already partially occupied or owned by different processes. Refusing to replace or duplicate the existing runtime.'
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($processIds[0])"
    if ($null -eq $process -or $process.Name -ne 'otelcol-contrib.exe') {
        throw "OTLP ports 4317 and 4318 are already owned by process '$($process.Name)'. Refusing to replace it."
    }

    $configMatch = [regex]::Match([string]$process.CommandLine, '--config\s+(?:"(?<path>[^"]+)"|(?<path>\S+))')
    if (-not $configMatch.Success -or
        -not (Test-Path -LiteralPath $configMatch.Groups['path'].Value -PathType Leaf)) {
        throw 'A running OpenTelemetry Collector owns ports 4317 and 4318, but its configuration path could not be verified.'
    }

    $configurationPath = $configMatch.Groups['path'].Value
    $configuration = Get-Content -LiteralPath $configurationPath -Raw
    $configuredKey = [regex]::Match($configuration, 'InstrumentationKey=(?<key>[0-9a-fA-F-]{36})')
    $expectedKey = [regex]::Match($ApplicationInsightsConnectionString, 'InstrumentationKey=(?<key>[0-9a-fA-F-]{36})')
    if (-not $configuredKey.Success -or
        -not $expectedKey.Success -or
        $configuredKey.Groups['key'].Value -ne $expectedKey.Groups['key'].Value) {
        throw 'A running OpenTelemetry Collector already owns ports 4317 and 4318 but targets a different or unverifiable Application Insights resource.'
    }

    $executablePath = [string]$process.ExecutablePath
    $scheduledTask = Get-ScheduledTask |
        Where-Object {
            @($_.Actions | Where-Object Execute -eq $executablePath).Count -gt 0
        } |
        Select-Object -First 1
    if ($null -eq $scheduledTask) {
        throw "The running OpenTelemetry Collector at '$executablePath' has no matching Scheduled Task. Refusing to take ownership of an unmanaged process."
    }

    return [pscustomobject]@{
        ExecutablePath = $executablePath
        ConfigurationPath = $configurationPath
        TaskName = [string]$scheduledTask.TaskName
    }
}

function Save-DeploymentState {
    param(
        [Parameter(Mandatory)]
        [string]$ApplicationInsightsId,

        [Parameter(Mandatory)]
        [string]$GrafanaEndpoint,

        [Parameter(Mandatory)]
        [string]$CollectorExecutablePath,

        [Parameter(Mandatory)]
        [string]$CollectorConfigurationPath,

        [Parameter(Mandatory)]
        [string]$CollectorTaskName
    )

    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $state = [ordered]@{
        subscriptionId = $SubscriptionId
        tenantId = $TenantId
        subscriptionName = [string]$account.name
        location = $Location
        resourceGroupName = $ResourceGroupName
        logAnalyticsWorkspaceName = $LogAnalyticsWorkspaceName
        applicationInsightsName = $ApplicationInsightsName
        applicationInsightsId = $ApplicationInsightsId
        grafanaName = $GrafanaName
        grafanaEndpoint = $GrafanaEndpoint
        collectorVersion = $CollectorVersion
        collectorTaskName = $CollectorTaskName
        collectorExecutablePath = $CollectorExecutablePath
        collectorConfigurationPath = $CollectorConfigurationPath
        captureContent = $CaptureContent
        discoveredAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Set-VsCodeSetting {
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    $jsonValue = $Value | ConvertTo-Json -Compress
    $content = Get-Content -LiteralPath $SettingsPath -Raw
    $escapedName = [regex]::Escape($Name)
    $pattern = "(?m)^(?<indent>\s*)`"$escapedName`"\s*:\s*(?:`"(?:\\.|[^`"])*`"|true|false|null|-?\d+(?:\.\d+)?)\s*,?"

    if ([regex]::IsMatch($content, $pattern)) {
        $settingPattern = [regex]::new($pattern)
        $content = $settingPattern.Replace(
            $content,
            { param($match) "$($match.Groups['indent'].Value)`"$Name`": $jsonValue," },
            1
        )
    }
    else {
        $closingBrace = $content.LastIndexOf('}')
        if ($closingBrace -lt 0) {
            throw "VS Code settings file is not a JSON/JSONC object: $SettingsPath"
        }

        $before = $content.Substring(0, $closingBrace).TrimEnd()
        $separator = if ($before -match '\{\s*$' -or $before -match ',\s*$') { '' } else { ',' }
        $content = "$before$separator`r`n  `"$Name`": $jsonValue`r`n}"
    }

    [System.IO.File]::WriteAllText($SettingsPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function Install-Collector {
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $executablePath = Join-Path $Destination 'otelcol-contrib.exe'
    if (Test-Path -LiteralPath $executablePath -PathType Leaf) {
        $versionOutput = (& $executablePath --version 2>&1) -join ' '
        if ($versionOutput -match [regex]::Escape($Version)) {
            Write-Host "OpenTelemetry Collector v$Version is already installed." -ForegroundColor DarkGreen
            return $executablePath
        }
    }

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $assetName = "otelcol-contrib_${Version}_windows_amd64.zip"
    $releaseRoot = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$Version"
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "agent-ai-dashboard-$([guid]::NewGuid().ToString('N'))"
    $archivePath = Join-Path $temporaryDirectory $assetName
    $checksumsPath = Join-Path $temporaryDirectory "otelcol-contrib_${Version}_checksums.txt"

    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        Write-Host "Downloading OpenTelemetry Collector v$Version..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri "$releaseRoot/$assetName" -OutFile $archivePath
        Invoke-WebRequest -Uri "$releaseRoot/otelcol-contrib_${Version}_checksums.txt" -OutFile $checksumsPath

        $checksumLine = Get-Content -LiteralPath $checksumsPath |
            Where-Object { $_ -match "\s\*?$([regex]::Escape($assetName))$" } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($checksumLine)) {
            throw "No checksum was published for $assetName."
        }

        $expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Collector checksum mismatch. Expected $expectedHash; received $actualHash."
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Collector extraction did not produce $executablePath."
    }

    return $executablePath
}

function Set-CollectorScheduledTask {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string]$ConfigurationPath
    )

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction `
        -Execute $ExecutablePath `
        -Argument "--config `"$ConfigurationPath`"" `
        -WorkingDirectory (Split-Path -Parent $ExecutablePath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentIdentity
    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Runs the OpenTelemetry Collector for Agent AI Dashboard.' `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3

    $ports = @(Get-NetTCPConnection -State Listen -LocalPort 4317, 4318 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty LocalPort -Unique)
    $missingPorts = @(4317, 4318 | Where-Object { $_ -notin $ports })
    if ($missingPorts.Count -gt 0) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        throw "Collector did not open ports $($missingPorts -join ', '). LastTaskResult=$($taskInfo.LastTaskResult)."
    }
}

function Set-DashboardDefaults {
    param(
        [Parameter(Mandatory)][string]$SubscriptionName
    )

    $dashboard = Invoke-AzJson -ArgumentList @(
        'grafana', 'dashboard', 'show',
        '--resource-group', $ResourceGroupName,
        '--name', $GrafanaName,
        '--dashboard', 'GitHubCopilot',
        '--output', 'json'
    )

    foreach ($variable in $dashboard.dashboard.templating.list) {
        switch ($variable.name) {
            'am_ds' {
                $variable.current = [pscustomobject]@{ selected = $true; text = 'Azure Monitor'; value = 'azure-monitor-oob' }
            }
            'sub' {
                $variable.current = [pscustomobject]@{ selected = $true; text = $SubscriptionName; value = $SubscriptionId }
            }
            'rg' {
                $variable.current = [pscustomobject]@{ selected = $true; text = $ResourceGroupName; value = $ResourceGroupName }
            }
            'res' {
                $variable.current = [pscustomobject]@{ selected = $true; text = $ApplicationInsightsName; value = $ApplicationInsightsName }
            }
        }
    }

    $dashboard.dashboard.version = [int]$dashboard.dashboard.version + 1
    $temporaryDefinition = Join-Path ([System.IO.Path]::GetTempPath()) "GitHubCopilot-$([guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryDefinition,
            ([ordered]@{ dashboard = $dashboard.dashboard; overwrite = $true } | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
            'grafana', 'dashboard', 'update',
            '--resource-group', $ResourceGroupName,
            '--name', $GrafanaName,
            '--definition', "@$temporaryDefinition",
            '--overwrite', 'true',
            '--output', 'none'
        ) -AllowEmptyOutput | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDefinition -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryDefinition -Force
        }
    }
}

if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it from https://aka.ms/installazurecliwindows.'
}
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "Bicep template not found: $templatePath"
}

try {
    $account = Invoke-AzJson -ArgumentList @('account', 'show', '--output', 'json')
}
catch {
    throw "Azure CLI is not authenticated. Run 'az login' and retry."
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = [string]$account.id
}
Invoke-NativeCommand -FilePath 'az' -ArgumentList @('account', 'set', '--subscription', $SubscriptionId) -AllowEmptyOutput | Out-Null
$account = Invoke-AzJson -ArgumentList @('account', 'show', '--output', 'json')

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = [string]$account.tenantId
}
if ($account.tenantId -ne $TenantId -or $account.state -ne 'Enabled') {
    throw "The selected subscription is not Enabled in tenant $TenantId."
}

$resourceGroupExists = (Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
        'group', 'exists',
        '--name', $ResourceGroupName,
        '--output', 'tsv'
    )).Trim() -eq 'true'

if ($resourceGroupExists) {
    $existingResources = @(Invoke-AzJson -ArgumentList @(
            'resource', 'list',
            '--resource-group', $ResourceGroupName,
            '--output', 'json'
        ))

    $LogAnalyticsWorkspaceName = Resolve-ExistingResourceName `
        -Resources $existingResources `
        -ResourceType 'Microsoft.OperationalInsights/workspaces' `
        -ResourceLabel 'Log Analytics workspace' `
        -RequestedName $LogAnalyticsWorkspaceName `
        -NameWasSpecified $PSBoundParameters.ContainsKey('LogAnalyticsWorkspaceName')
    $ApplicationInsightsName = Resolve-ExistingResourceName `
        -Resources $existingResources `
        -ResourceType 'Microsoft.Insights/components' `
        -ResourceLabel 'Application Insights resource' `
        -RequestedName $ApplicationInsightsName `
        -NameWasSpecified $PSBoundParameters.ContainsKey('ApplicationInsightsName')
    $GrafanaName = Resolve-ExistingResourceName `
        -Resources $existingResources `
        -ResourceType 'Microsoft.Dashboard/grafana' `
        -ResourceLabel 'Managed Grafana resource' `
        -RequestedName $GrafanaName `
        -NameWasSpecified $PSBoundParameters.ContainsKey('GrafanaName')
}

$existingCollector = $null
if ($resourceGroupExists) {
    $existingApplicationInsightsConnectionString = (Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
            'resource', 'show',
            '--resource-group', $ResourceGroupName,
            '--name', $ApplicationInsightsName,
            '--resource-type', 'Microsoft.Insights/components',
            '--query', 'properties.ConnectionString',
            '--output', 'tsv'
        )).Trim()
    $existingCollector = Get-RunningOtlpCollector `
        -ApplicationInsightsConnectionString $existingApplicationInsightsConnectionString
    if ($null -ne $existingCollector) {
        Write-Host "Reusing running OpenTelemetry Collector '$($existingCollector.ExecutablePath)'." -ForegroundColor DarkGreen
    }
}

$useGeneratedGrafanaName = [string]::IsNullOrWhiteSpace($GrafanaName)
$grafanaNameDisplay = if ($useGeneratedGrafanaName) {
    'automatic (deterministic and subscription-unique)'
} else {
    $GrafanaName
}

$operatorObjectId = (Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
        'ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv'
    )).Trim()
if ([string]::IsNullOrWhiteSpace($operatorObjectId)) {
    throw 'Could not resolve the signed-in user object ID.'
}

$captureContentText = if ($CaptureContent) { 'enabled (prompts/responses may be exported)' } else { 'disabled (recommended default)' }
$collectorDisplay = if ($null -eq $existingCollector) {
    "v$CollectorVersion in $collectorDirectory"
} else {
    "existing installation at $($existingCollector.ExecutablePath)"
}
$collectorTaskDisplay = if ($null -eq $existingCollector) { $taskName } else { $existingCollector.TaskName }
$plan = @"

Agent AI Dashboard deployment
=============================

Description
  GitHub Copilot -> local OpenTelemetry Collector -> Application Insights
  -> Log Analytics -> Azure Managed Grafana.

Azure
  Subscription:          $($account.name) ($SubscriptionId)
  Tenant:                $TenantId
  Region:                $Location
  Resource group:        $ResourceGroupName
  Log Analytics:         $LogAnalyticsWorkspaceName
  Application Insights:  $ApplicationInsightsName
  Managed Grafana:       $grafanaNameDisplay (Standard, billable)
  Dashboard:             GitHub Copilot, grafana.com ID 25053

Access
  Current user:          Grafana Admin on the Grafana resource only
  Grafana identity:      Monitoring Reader on this resource group only

Local Windows configuration
  Collector:             $collectorDisplay
  Endpoints:             localhost:4317 and localhost:4318
  Persistence:           Scheduled Task $collectorTaskDisplay
  VS Code + CLI export:  enabled
  Capture content:       $captureContentText

The deployment is idempotent and does not delete resources.
"@

Write-Host $plan

$deploymentParameters = @(
    "resourceLocation=$Location",
    "resourceGroupName=$ResourceGroupName",
    "logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName",
    "applicationInsightsName=$ApplicationInsightsName",
    "grafanaAdminPrincipalId=$operatorObjectId"
)
if (-not $useGeneratedGrafanaName) {
    $deploymentParameters += "grafanaName=$GrafanaName"
}

Write-Host 'Previewing Azure changes...' -ForegroundColor Cyan
& az deployment sub what-if `
    --name 'agent-ai-dashboard-preview' `
    --location $Location `
    --template-file $templatePath `
    --parameters $deploymentParameters
if ($LASTEXITCODE -ne 0) {
    throw 'Azure what-if failed. No deployment was started.'
}

if ($resourceGroupExists) {
    $existingApplicationInsights = Invoke-AzJson -ArgumentList @(
        'resource', 'show',
        '--resource-group', $ResourceGroupName,
        '--name', $ApplicationInsightsName,
        '--resource-type', 'Microsoft.Insights/components',
        '--output', 'json'
    )
    $existingGrafana = Invoke-AzJson -ArgumentList @(
        'grafana', 'show',
        '--resource-group', $ResourceGroupName,
        '--name', $GrafanaName,
        '--output', 'json'
    )
    $stateCollectorExecutable = if ($null -eq $existingCollector) {
        Join-Path $collectorDirectory 'otelcol-contrib.exe'
    } else {
        $existingCollector.ExecutablePath
    }
    $stateCollectorConfiguration = if ($null -eq $existingCollector) {
        $collectorConfigPath
    } else {
        $existingCollector.ConfigurationPath
    }
    $stateCollectorTask = if ($null -eq $existingCollector) {
        $taskName
    } else {
        $existingCollector.TaskName
    }

    Save-DeploymentState `
        -ApplicationInsightsId ([string]$existingApplicationInsights.id) `
        -GrafanaEndpoint ([string]$existingGrafana.properties.endpoint) `
        -CollectorExecutablePath $stateCollectorExecutable `
        -CollectorConfigurationPath $stateCollectorConfiguration `
        -CollectorTaskName $stateCollectorTask
    Write-Host "Saved discovered deployment state to $statePath." -ForegroundColor DarkGreen

    if (Test-Path -LiteralPath $statusScriptPath -PathType Leaf) {
        & $statusScriptPath
    }
}

$confirmation = Read-Host 'Review the what-if above. Type YES to apply Azure and runtime changes; any other response stops after saving state and status'
if ($confirmation.Trim() -ine 'YES') {
    Write-Host 'Cancelled. No Azure deployment or runtime configuration changes were made.' -ForegroundColor Yellow
    exit 0
}

foreach ($provider in 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.Dashboard') {
    Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
        'provider', 'register', '--namespace', $provider, '--wait', '--output', 'none'
    ) -AllowEmptyOutput | Out-Null
}

Write-Host 'Deploying Azure resources...' -ForegroundColor Cyan
$deploymentArguments = @(
    'deployment', 'sub', 'create',
    '--name', 'agent-ai-dashboard',
    '--location', $Location,
    '--template-file', $templatePath,
    '--parameters'
) + $deploymentParameters + @('--output', 'json')
$deployment = Invoke-AzJson -ArgumentList $deploymentArguments

$outputs = $deployment.properties.outputs
$GrafanaName = [string]$outputs.grafanaName.value
$grafanaEndpoint = [string]$outputs.grafanaEndpoint.value
$applicationInsightsId = [string]$outputs.applicationInsightsId.value

Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
    'extension', 'add', '--name', 'amg', '--upgrade', '--yes', '--output', 'none'
) -AllowEmptyOutput | Out-Null

$dashboards = @(Invoke-AzJson -ArgumentList @(
        'grafana', 'dashboard', 'list',
        '--resource-group', $ResourceGroupName,
        '--name', $GrafanaName,
        '--output', 'json'
    ))
if (@($dashboards | Where-Object uid -eq 'GitHubCopilot').Count -eq 0) {
    Write-Host 'Waiting for role propagation and importing dashboard 25053...' -ForegroundColor Cyan
    $imported = $false
    for ($attempt = 1; $attempt -le 12 -and -not $imported; $attempt++) {
        & az grafana dashboard import `
            --resource-group $ResourceGroupName `
            --name $GrafanaName `
            --definition 25053 `
            --output none 2>$null
        $imported = $LASTEXITCODE -eq 0
        if (-not $imported) {
            Start-Sleep -Seconds 15
        }
    }
    if (-not $imported) {
        throw 'Dashboard import failed after waiting three minutes for role propagation.'
    }
}

Set-DashboardDefaults -SubscriptionName ([string]$account.name)

$connectionString = (Invoke-NativeCommand -FilePath 'az' -ArgumentList @(
        'resource', 'show',
        '--ids', $applicationInsightsId,
        '--query', 'properties.ConnectionString',
        '--output', 'tsv'
    )).Trim()
if ([string]::IsNullOrWhiteSpace($connectionString)) {
    throw 'Application Insights returned an empty connection string.'
}

$collectorConfiguration = @"
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317

exporters:
  azure_monitor:
    connection_string: "$connectionString"

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [azure_monitor]
    metrics:
      receivers: [otlp]
      exporters: [azure_monitor]
    logs:
      receivers: [otlp]
      exporters: [azure_monitor]
"@
if ($null -eq $existingCollector) {
    [System.IO.File]::WriteAllText(
        $collectorConfigPath,
        $collectorConfiguration,
        [System.Text.UTF8Encoding]::new($false)
    )

    $collectorExecutable = Install-Collector -Version $CollectorVersion -Destination $collectorDirectory
    & $collectorExecutable validate --config $collectorConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw 'The generated Collector configuration failed validation.'
    }
}
else {
    $collectorExecutable = $existingCollector.ExecutablePath
    $collectorConfigPath = $existingCollector.ConfigurationPath
    $taskName = $existingCollector.TaskName
}

$vsCodeSettingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
$vsCodeSettingsDirectory = Split-Path -Parent $vsCodeSettingsPath
New-Item -ItemType Directory -Path $vsCodeSettingsDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $vsCodeSettingsPath -PathType Leaf)) {
    [System.IO.File]::WriteAllText(
        $vsCodeSettingsPath,
        "{`r`n}`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}
else {
    Copy-Item -LiteralPath $vsCodeSettingsPath -Destination "$vsCodeSettingsPath.agent-ai-dashboard.bak" -Force
}

Set-VsCodeSetting -SettingsPath $vsCodeSettingsPath -Name 'github.copilot.chat.otel.enabled' -Value $true
Set-VsCodeSetting -SettingsPath $vsCodeSettingsPath -Name 'github.copilot.chat.otel.exporterType' -Value 'otlp-http'
Set-VsCodeSetting -SettingsPath $vsCodeSettingsPath -Name 'github.copilot.chat.otel.otlpEndpoint' -Value 'http://localhost:4318'
Set-VsCodeSetting -SettingsPath $vsCodeSettingsPath -Name 'github.copilot.chat.otel.captureContent' -Value $CaptureContent

[Environment]::SetEnvironmentVariable('COPILOT_OTEL_ENABLED', 'true', 'User')
[Environment]::SetEnvironmentVariable('COPILOT_OTEL_EXPORTER_TYPE', 'otlp-http', 'User')
[Environment]::SetEnvironmentVariable('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://localhost:4318', 'User')
$env:COPILOT_OTEL_ENABLED = 'true'
$env:COPILOT_OTEL_EXPORTER_TYPE = 'otlp-http'
$env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4318'

if ($null -eq $existingCollector) {
    Set-CollectorScheduledTask -ExecutablePath $collectorExecutable -ConfigurationPath $collectorConfigPath
}

Save-DeploymentState `
    -ApplicationInsightsId $applicationInsightsId `
    -GrafanaEndpoint $grafanaEndpoint `
    -CollectorExecutablePath $collectorExecutable `
    -CollectorConfigurationPath $collectorConfigPath `
    -CollectorTaskName $taskName

if (Test-Path -LiteralPath $statusScriptPath -PathType Leaf) {
    & $statusScriptPath
}

$dashboardUrl = "${grafanaEndpoint}/d/GitHubCopilot/github-copilot?orgId=1&from=now-7d&to=now&timezone=browser&var-am_ds=azure-monitor-oob&var-sub=$SubscriptionId&var-rg=$ResourceGroupName&var-res=$ApplicationInsightsName&var-copilotTraceId=&var-source=copilot-chat&var-source=github-copilot&refresh=30s"

Write-Host ''
Write-Host 'Deployment completed successfully.' -ForegroundColor Green
Write-Host "Grafana:   $grafanaEndpoint"
Write-Host "Dashboard: $dashboardUrl"
Write-Host "Status:    $(Join-Path $repositoryRoot 'reports\status.html')"
Write-Host ''
Write-Host 'Restart VS Code and start a new Copilot CLI process before generating telemetry.' -ForegroundColor Yellow
