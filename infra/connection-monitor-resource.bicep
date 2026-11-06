targetScope = 'resourceGroup'

param location string
param networkWatcherName string
param connectionMonitorName string
param clientVmId string
param workloadVmId string
param workloadPrivateIp string
param workspaceResourceId string

resource networkWatcher 'Microsoft.Network/networkWatchers@2025-09-01' existing = {
  name: networkWatcherName
}

resource connectionMonitor 'Microsoft.Network/networkWatchers/connectionMonitors@2025-09-01' = {
  parent: networkWatcher
  name: connectionMonitorName
  location: location
  properties: {
    endpoints: [
      {
        name: 'client'
        type: 'AzureVM'
        resourceId: clientVmId
      }
      {
        name: 'iis'
        type: 'AzureVM'
        resourceId: workloadVmId
        address: workloadPrivateIp
      }
    ]
    testConfigurations: [
      {
        name: 'TCP-80'
        protocol: 'Tcp'
        preferredIPVersion: 'IPv4'
        testFrequencySec: 30
        tcpConfiguration: {
          port: 80
          destinationPortBehavior: 'None'
          disableTraceRoute: false
        }
        successThreshold: {
          checksFailedPercent: 10
          roundTripTimeMs: 100
        }
      }
    ]
    testGroups: [
      {
        name: 'client-to-iis'
        disable: false
        sources: [
          'client'
        ]
        destinations: [
          'iis'
        ]
        testConfigurations: [
          'TCP-80'
        ]
      }
    ]
    outputs: [
      {
        type: 'Workspace'
        workspaceSettings: {
          workspaceResourceId: workspaceResourceId
        }
      }
    ]
  }
}

output connectionMonitorId string = connectionMonitor.id
output connectionMonitorName string = connectionMonitor.name
output connectionMonitorPortalUrl string = 'https://portal.azure.com/#resource${connectionMonitor.id}/overview'
