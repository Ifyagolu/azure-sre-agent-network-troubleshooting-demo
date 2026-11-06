targetScope = 'resourceGroup'

param location string
param networkWatcherName string
param createNetworkWatcher bool
param clientFlowLogName string
param workloadFlowLogName string
param clientVnetId string
param workloadVnetId string
param storageAccountId string
param workspaceResourceId string
param workspaceCustomerId string
param workspaceRegion string
param retentionDays int

resource newNetworkWatcher 'Microsoft.Network/networkWatchers@2025-09-01' = if (createNetworkWatcher) {
  name: networkWatcherName
  location: location
}

resource networkWatcher 'Microsoft.Network/networkWatchers@2025-09-01' existing = {
  name: networkWatcherName
}

resource clientFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2025-09-01' = {
  parent: networkWatcher
  name: clientFlowLogName
  location: workspaceRegion
  dependsOn: [
    newNetworkWatcher
  ]
  properties: {
    targetResourceId: clientVnetId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      days: retentionDays
      enabled: true
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceId: workspaceCustomerId
        workspaceRegion: workspaceRegion
        workspaceResourceId: workspaceResourceId
        trafficAnalyticsInterval: 10
      }
    }
  }
}

resource workloadFlowLog 'Microsoft.Network/networkWatchers/flowLogs@2025-09-01' = {
  parent: networkWatcher
  name: workloadFlowLogName
  location: workspaceRegion
  dependsOn: [
    newNetworkWatcher
  ]
  properties: {
    targetResourceId: workloadVnetId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      days: retentionDays
      enabled: true
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceId: workspaceCustomerId
        workspaceRegion: workspaceRegion
        workspaceResourceId: workspaceResourceId
        trafficAnalyticsInterval: 10
      }
    }
  }
}

output clientFlowLogId string = clientFlowLog.id
output workloadFlowLogId string = workloadFlowLog.id
output flowLogNames array = [
  clientFlowLog.name
  workloadFlowLog.name
]
