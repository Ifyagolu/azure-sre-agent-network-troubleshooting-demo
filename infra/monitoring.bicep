targetScope = 'resourceGroup'

param location string
param storageAccountName string
param workspaceName string
param dataCollectionRuleName string
param logRetentionInDays int
param logDailyQuotaGb int

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: logRetentionInDays
    sku: {
      name: 'PerGB2018'
    }
    workspaceCapping: {
      dailyQuotaGb: logDailyQuotaGb
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dataCollectionRuleName
  location: location
  kind: 'Windows'
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'sre-network-demo-application-events'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[Provider[@Name="SRE-Network-Demo"]]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'demo-workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'demo-workspace'
        ]
      }
    ]
  }
}

output storageAccountId string = storageAccount.id
output workspaceResourceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output dataCollectionRuleId string = dataCollectionRule.id
