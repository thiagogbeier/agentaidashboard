targetScope = 'subscription'

@description('Azure region for all deployable resources.')
param location string = 'canadacentral'

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
@description('Globally unique Azure Managed Grafana name.')
param grafanaName string

@description('Optional object ID of the user who receives Grafana Admin at Grafana-resource scope.')
param grafanaAdminPrincipalId string = ''

resource monitoringResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module monitoring 'resources.bicep' = {
  name: 'agent-ai-dashboard'
  scope: monitoringResourceGroup
  params: {
    location: location
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
output grafanaEndpoint string = monitoring.outputs.grafanaEndpoint
