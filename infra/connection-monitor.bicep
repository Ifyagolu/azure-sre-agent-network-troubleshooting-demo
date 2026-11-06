targetScope = 'resourceGroup'

@description('Use the location and resource names from the existing deployment context.')
param location string
param clientVmName string
param workloadVmName string
param workloadPrivateIp string
param workspaceResourceId string
param networkWatcherResourceGroupName string
param networkWatcherName string
param connectionMonitorName string

@description('False only when a healthy NetworkWatcherAgentWindows extension already exists on the source.')
param installSourceAgent bool = true

resource clientVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: clientVmName
}

resource workloadVm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: workloadVmName
}

resource sourceAgent 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (installSourceAgent) {
  parent: clientVm
  name: 'AzureNetworkWatcherExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentWindows'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

module connectionMonitor 'connection-monitor-resource.bicep' = {
  name: 'connection-monitor'
  scope: resourceGroup(networkWatcherResourceGroupName)
  dependsOn: [
    sourceAgent
  ]
  params: {
    location: location
    networkWatcherName: networkWatcherName
    connectionMonitorName: connectionMonitorName
    clientVmId: clientVm.id
    workloadVmId: workloadVm.id
    workloadPrivateIp: workloadPrivateIp
    workspaceResourceId: workspaceResourceId
  }
}

output connectionMonitorId string = connectionMonitor.outputs.connectionMonitorId
output connectionMonitorName string = connectionMonitor.outputs.connectionMonitorName
output connectionMonitorPortalUrl string = connectionMonitor.outputs.connectionMonitorPortalUrl
output portalValidationLocation string = 'Network Watcher > Monitoring > Connection monitor > ${connectionMonitorName} > client-to-iis > TCP-80'
output sourceAgentInstalledByDeployment bool = installSourceAgent
output logAnalyticsWorkspaceId string = workspaceResourceId
output destinationPrivateIp string = workloadPrivateIp
output testFrequencySeconds int = 30
