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
@description('Globally unique Azure Managed Grafana name. The default is deterministic for this subscription.')
param grafanaName string = 'amg-cop-${uniqueString(subscription().subscriptionId)}'

@description('Object ID that receives Grafana Admin at Grafana-resource scope. Defaults to the identity running this deployment; clear it to skip the assignment.')
param grafanaAdminPrincipalId string = deployer().objectId

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
    grafanaName: grafanaName
    grafanaAdminPrincipalId: grafanaAdminPrincipalId
  }
}

output resourceGroupId string = monitoringResourceGroup.id
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output applicationInsightsId string = monitoring.outputs.applicationInsightsId
output applicationInsightsAppId string = monitoring.outputs.applicationInsightsAppId
output grafanaId string = monitoring.outputs.grafanaId
output grafanaName string = monitoring.outputs.grafanaName
output grafanaEndpoint string = monitoring.outputs.grafanaEndpoint
