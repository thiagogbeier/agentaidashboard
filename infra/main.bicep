targetScope = 'subscription'

@description('Azure region for Log Analytics, Application Insights, and Managed Grafana. This is separate from the subscription deployment record region shown by Azure Portal.')
param resourceLocation string = 'canadacentral'

@minLength(1)
@maxLength(90)
@description('Resource group that contains the complete monitoring stack.')
param resourceGroupName string = 'rg-copilot-monitoring'

@minLength(1)
@maxLength(63)
@description('Log Analytics workspace name.')
param logAnalyticsWorkspaceName string = 'law-copilot-monitoring'

@minLength(1)
@maxLength(260)
@description('Workspace-based Application Insights component name.')
param applicationInsightsName string = 'appi-copilot-monitoring'

@minLength(1)
@maxLength(23)
@description('Use auto to generate a deterministic, subscription-unique Managed Grafana name, or enter a custom globally unique name.')
param grafanaName string = 'auto'

@description('Use current-deployer to grant Grafana Admin to the deployment identity, enter another principal object ID, or clear the value to skip the assignment.')
param grafanaAdminPrincipalId string = 'current-deployer'

var effectiveGrafanaName = toLower(grafanaName) == 'auto'
  ? 'amg-cop-${uniqueString(subscription().subscriptionId)}'
  : grafanaName
var effectiveGrafanaAdminPrincipalId = toLower(grafanaAdminPrincipalId) == 'current-deployer'
  ? deployer().objectId
  : grafanaAdminPrincipalId

resource monitoringResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: resourceLocation
}

module monitoring 'resources.bicep' = {
  name: 'agent-ai-dashboard'
  scope: monitoringResourceGroup
  params: {
    location: resourceLocation
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
    grafanaName: effectiveGrafanaName
    grafanaAdminPrincipalId: effectiveGrafanaAdminPrincipalId
  }
}

output resourceGroupId string = monitoringResourceGroup.id
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output applicationInsightsId string = monitoring.outputs.applicationInsightsId
output applicationInsightsAppId string = monitoring.outputs.applicationInsightsAppId
output grafanaId string = monitoring.outputs.grafanaId
output grafanaName string = monitoring.outputs.grafanaName
output grafanaEndpoint string = monitoring.outputs.grafanaEndpoint
