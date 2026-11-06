targetScope = 'subscription'

@description('Azure region for the demo resources. Verify service, image and SKU availability before deployment.')
param resourceLocation string = 'westcentralus'

@description('Dedicated demo group: rg-sre-network-demo with an optional lowercase alphanumeric suffix.')
@minLength(19)
@maxLength(40)
param resourceGroupName string = 'rg-sre-network-demo'

@description('Resource group containing the existing regional Network Watcher.')
param networkWatcherResourceGroupName string = 'NetworkWatcherRG'

@description('Name of the existing regional Network Watcher.')
param networkWatcherName string = 'NetworkWatcher_${resourceLocation}'

@description('Create the regional watcher only when discovery confirms it is absent. Its resource group must already exist.')
param createNetworkWatcher bool = false

@description('RFC1918 client VNet address space, non-overlapping with the workload VNet.')
param clientVnetPrefix string = '10.10.0.0/16'

@description('Client subnet contained within the client VNet; /29 or larger.')
param clientSubnetPrefix string = '10.10.1.0/24'

@description('RFC1918 workload VNet address space.')
param workloadVnetPrefix string = '10.20.0.0/16'

@description('Workload subnet contained within the workload VNet; /29 or larger.')
param workloadSubnetPrefix string = '10.20.1.0/24'

@description('Windows local administrator user name.')
param adminUsername string = 'azureuser'

@secure()
@description('Windows local administrator password for both VMs. Supply through a secure deployment input.')
@minLength(14)
param adminPassword string

@description('VM size for both demo VMs. Validate regional availability and quota.')
param vmSize string = 'Standard_D2as_v6'

@description('Windows image version; use a discovered version for reproducibility or latest for a refreshed demo.')
param windowsImageVersion string = 'latest'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

@description('Log Analytics daily ingestion cap in GB.')
@minValue(1)
param logDailyQuotaGb int = 1

@description('Raw VNet flow-log retention in days.')
@minValue(1)
param flowLogRetentionDays int = 7

@description('Globally unique storage account name.')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stsredemo${uniqueString(subscription().id, resourceGroupName)}'

@description('Deploy exact read-only role assignments for an existing SRE Agent managed identity.')
param enableSreAgentRbac bool = false

@description('Object (principal) ID of the existing SRE Agent managed identity. Required only when RBAC is enabled.')
param sreAgentPrincipalId string = ''

@description('Add Monitoring Reader at resource-group scope only when separately validated as necessary.')
param enableMonitoringReader bool = false

var demoName = substring(resourceGroupName, 3)
var names = {
  clientVnet: 'vnet-${demoName}-client'
  workloadVnet: 'vnet-${demoName}-workload'
  clientSubnet: 'snet-client'
  workloadSubnet: 'snet-workload'
  clientNsg: 'nsg-${demoName}-client'
  workloadNsg: 'nsg-${demoName}-workload'
  clientPublicIp: 'pip-${demoName}-client'
  workloadPublicIp: 'pip-${demoName}-web'
  clientNic: 'nic-${demoName}-client'
  workloadNic: 'nic-${demoName}-web'
  clientVm: 'vm-sre-client'
  workloadVm: 'vm-sre-web'
  workspace: 'law-${demoName}'
  dcr: 'dcr-${demoName}-windows-events'
}

resource demoResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: resourceLocation
  tags: {
    workload: 'sre-network-demo'
    environment: 'demo'
  }
}

module monitoring 'monitoring.bicep' = {
  name: 'monitoring'
  scope: demoResourceGroup
  params: {
    location: resourceLocation
    storageAccountName: storageAccountName
    workspaceName: names.workspace
    dataCollectionRuleName: names.dcr
    logRetentionInDays: logRetentionInDays
    logDailyQuotaGb: logDailyQuotaGb
  }
}

module network 'network.bicep' = {
  name: 'network'
  scope: demoResourceGroup
  params: {
    location: resourceLocation
    clientVnetName: names.clientVnet
    workloadVnetName: names.workloadVnet
    clientSubnetName: names.clientSubnet
    workloadSubnetName: names.workloadSubnet
    clientNsgName: names.clientNsg
    workloadNsgName: names.workloadNsg
    clientPublicIpName: names.clientPublicIp
    workloadPublicIpName: names.workloadPublicIp
    clientVnetPrefix: clientVnetPrefix
    clientSubnetPrefix: clientSubnetPrefix
    workloadVnetPrefix: workloadVnetPrefix
    workloadSubnetPrefix: workloadSubnetPrefix
  }
}

module virtualMachines 'vm.bicep' = {
  name: 'virtual-machines'
  scope: demoResourceGroup
  params: {
    location: resourceLocation
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    windowsImageVersion: windowsImageVersion
    clientNicName: names.clientNic
    workloadNicName: names.workloadNic
    clientVmName: names.clientVm
    workloadVmName: names.workloadVm
    clientSubnetId: network.outputs.clientSubnetId
    workloadSubnetId: network.outputs.workloadSubnetId
    clientPublicIpId: network.outputs.clientPublicIpId
    workloadPublicIpId: network.outputs.workloadPublicIpId
    dataCollectionRuleId: monitoring.outputs.dataCollectionRuleId
  }
}

module flowLogs 'flowlogs.bicep' = {
  name: 'flow-logs'
  scope: resourceGroup(networkWatcherResourceGroupName)
  params: {
    location: resourceLocation
    networkWatcherName: networkWatcherName
    createNetworkWatcher: createNetworkWatcher
    clientFlowLogName: 'fl-${demoName}-client'
    workloadFlowLogName: 'fl-${demoName}-workload'
    clientVnetId: network.outputs.clientVnetId
    workloadVnetId: network.outputs.workloadVnetId
    storageAccountId: monitoring.outputs.storageAccountId
    workspaceResourceId: monitoring.outputs.workspaceResourceId
    workspaceCustomerId: monitoring.outputs.workspaceCustomerId
    workspaceRegion: resourceLocation
    retentionDays: flowLogRetentionDays
  }
}

module sreAgentRbac 'rbac.bicep' = if (enableSreAgentRbac) {
  name: 'sre-agent-read-only-rbac'
  scope: demoResourceGroup
  dependsOn: [
    monitoring
  ]
  params: {
    principalId: sreAgentPrincipalId
    workspaceName: names.workspace
    enableMonitoringReader: enableMonitoringReader
  }
}

output resourceGroupId string = demoResourceGroup.id
output clientPrivateIp string = virtualMachines.outputs.clientPrivateIp
output workloadPrivateIp string = virtualMachines.outputs.workloadPrivateIp
output clientVnetId string = network.outputs.clientVnetId
output workloadVnetId string = network.outputs.workloadVnetId
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceResourceId
output clientFlowLogId string = flowLogs.outputs.clientFlowLogId
output workloadFlowLogId string = flowLogs.outputs.workloadFlowLogId

// Runtime context consumed by scripts/get-deployment-context.ps1.
output resourceGroupName string = resourceGroupName
output location string = resourceLocation
output subscriptionId string = subscription().subscriptionId
output clientVmName string = names.clientVm
output workloadVmName string = names.workloadVm
output clientVmId string = virtualMachines.outputs.clientVmId
output workloadVmId string = virtualMachines.outputs.workloadVmId
output workloadNsgName string = names.workloadNsg
output clientSubnetPrefix string = network.outputs.clientSubnetPrefix
output workloadSubnetPrefix string = network.outputs.workloadSubnetPrefix
output workspaceCustomerId string = monitoring.outputs.workspaceCustomerId
output workspaceResourceId string = monitoring.outputs.workspaceResourceId
output networkWatcherResourceGroup string = networkWatcherResourceGroupName
output networkWatcherName string = networkWatcherName
output flowLogNames array = flowLogs.outputs.flowLogNames
output roleAssignmentIds array = enableSreAgentRbac ? sreAgentRbac!.outputs.roleAssignmentIds : []
