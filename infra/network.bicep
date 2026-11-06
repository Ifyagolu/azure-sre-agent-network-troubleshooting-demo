targetScope = 'resourceGroup'

param location string
param clientVnetName string
param workloadVnetName string
param clientSubnetName string
param workloadSubnetName string
param clientNsgName string
param workloadNsgName string
param clientPublicIpName string
param workloadPublicIpName string

param clientVnetPrefix string
param clientSubnetPrefix string
param workloadVnetPrefix string
param workloadSubnetPrefix string

resource clientNsg 'Microsoft.Network/networkSecurityGroups@2025-09-01' = {
  name: clientNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Client-To-Web-Demo'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: clientSubnetPrefix
          destinationAddressPrefix: workloadSubnetPrefix
        }
      }
    ]
  }
}

resource workloadNsg 'Microsoft.Network/networkSecurityGroups@2025-09-01' = {
  name: workloadNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Client-To-Web-Demo'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: clientSubnetPrefix
          destinationAddressPrefix: workloadSubnetPrefix
        }
      }
    ]
  }
}

resource clientPublicIp 'Microsoft.Network/publicIPAddresses@2025-09-01' = {
  name: clientPublicIpName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource workloadPublicIp 'Microsoft.Network/publicIPAddresses@2025-09-01' = {
  name: workloadPublicIpName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource clientVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: clientVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        clientVnetPrefix
      ]
    }
    subnets: [
      {
        name: clientSubnetName
        properties: {
          addressPrefix: clientSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: clientNsg.id
          }
        }
      }
    ]
  }
}

resource workloadVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: workloadVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        workloadVnetPrefix
      ]
    }
    subnets: [
      {
        name: workloadSubnetName
        properties: {
          addressPrefix: workloadSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: workloadNsg.id
          }
        }
      }
    ]
  }
}

resource clientToWorkload 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-09-01' = {
  parent: clientVnet
  name: 'client-to-workload'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: workloadVnet.id
    }
  }
}

resource workloadToClient 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-09-01' = {
  parent: workloadVnet
  name: 'workload-to-client'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: clientVnet.id
    }
  }
}

output clientVnetId string = clientVnet.id
output workloadVnetId string = workloadVnet.id
output clientSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', clientVnet.name, clientSubnetName)
output workloadSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', workloadVnet.name, workloadSubnetName)
output clientSubnetPrefix string = clientSubnetPrefix
output workloadSubnetPrefix string = workloadSubnetPrefix
output clientPublicIpId string = clientPublicIp.id
output workloadPublicIpId string = workloadPublicIp.id
