targetScope = 'resourceGroup'

@description('Object ID of the existing SRE Agent user-assigned managed identity.')
param principalId string
param workspaceName string
param enableMonitoringReader bool = false

var readerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
)
var logAnalyticsReaderRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '73c42c96-874c-492b-b04d-ab87d138a893'
)
var monitoringReaderRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
)

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: workspaceName
}

resource resourceGroupReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, readerRoleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleDefinitionId
  }
}

resource logAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, principalId, logAnalyticsReaderRoleDefinitionId)
  scope: workspace
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReaderRoleDefinitionId
  }
}

resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableMonitoringReader) {
  name: guid(resourceGroup().id, principalId, monitoringReaderRoleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringReaderRoleDefinitionId
  }
}

output resourceGroupReaderAssignmentId string = resourceGroupReader.id
output logAnalyticsReaderAssignmentId string = logAnalyticsReader.id
output monitoringReaderAssignmentId string = enableMonitoringReader ? monitoringReader.id : ''
output roleAssignmentIds array = concat(
  [
    resourceGroupReader.id
    logAnalyticsReader.id
  ],
  enableMonitoringReader ? [
    monitoringReader.id
  ] : []
)
