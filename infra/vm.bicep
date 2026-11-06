targetScope = 'resourceGroup'

param location string
param adminUsername string
@secure()
param adminPassword string
param vmSize string
param windowsImageVersion string
param clientNicName string
param workloadNicName string
param clientVmName string
param workloadVmName string
param clientSubnetId string
param workloadSubnetId string
param clientPublicIpId string
param workloadPublicIpId string
param dataCollectionRuleId string

var clientBootstrapScript = loadTextContent('./windows/client-bootstrap.ps1')
var workloadBootstrapScript = loadTextContent('./windows/workload-bootstrap.ps1')
var clientBootstrapCommand = 'powershell.exe -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "$content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(clientBootstrapScript)}\')); & ([ScriptBlock]::Create($content))"'
var workloadBootstrapCommand = 'powershell.exe -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "$content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(workloadBootstrapScript)}\')); & ([ScriptBlock]::Create($content))"'

resource clientNic 'Microsoft.Network/networkInterfaces@2025-09-01' = {
  name: clientNicName
  location: location
  properties: {
    enableAcceleratedNetworking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: clientSubnetId
          }
          publicIPAddress: {
            id: clientPublicIpId
          }
          primary: true
        }
      }
    ]
  }
}

resource workloadNic 'Microsoft.Network/networkInterfaces@2025-09-01' = {
  name: workloadNicName
  location: location
  properties: {
    enableAcceleratedNetworking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: workloadSubnetId
          }
          publicIPAddress: {
            id: workloadPublicIpId
          }
          primary: true
        }
      }
    ]
  }
}

resource clientVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: clientVmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: clientVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: windowsImageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource workloadVm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: workloadVmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: workloadVmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: windowsImageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: workloadNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource clientBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: clientVm
  name: 'WindowsBootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: clientBootstrapCommand
    }
  }
}

resource workloadBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: workloadVm
  name: 'WindowsBootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: workloadBootstrapCommand
    }
  }
}

resource clientAma 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: clientVm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    provisionAfterExtensions: [
      clientBootstrap.name
    ]
  }
}

resource workloadAma 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: workloadVm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    provisionAfterExtensions: [
      workloadBootstrap.name
    ]
  }
}

resource clientDcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'sre-network-demo-windows-events'
  scope: clientVm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
  }
  dependsOn: [
    clientAma
  ]
}

resource workloadDcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'sre-network-demo-windows-events'
  scope: workloadVm
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
  }
  dependsOn: [
    workloadAma
  ]
}

output clientVmId string = clientVm.id
output workloadVmId string = workloadVm.id
output clientPrivateIp string = clientNic.properties.ipConfigurations[0].properties.privateIPAddress
output workloadPrivateIp string = workloadNic.properties.ipConfigurations[0].properties.privateIPAddress
