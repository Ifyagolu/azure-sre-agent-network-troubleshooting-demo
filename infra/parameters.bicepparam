using './main.bicep'

param resourceLocation = 'westcentralus'
param resourceGroupName = 'rg-sre-network-demo'
param networkWatcherResourceGroupName = 'NetworkWatcherRG'
param adminUsername = 'azureuser'
param clientVnetPrefix = '10.10.0.0/16'
param clientSubnetPrefix = '10.10.1.0/24'
param workloadVnetPrefix = '10.20.0.0/16'
param workloadSubnetPrefix = '10.20.1.0/24'

// Set AZURE_VM_ADMIN_PASSWORD only in the deployment process. Never commit a password.
param adminPassword = readEnvironmentVariable('AZURE_VM_ADMIN_PASSWORD')

param vmSize = 'Standard_D2as_v6'
param windowsImageVersion = 'latest'
param logRetentionInDays = 30
param logDailyQuotaGb = 1
param flowLogRetentionDays = 7

// The default deterministic name in main.bicep is used unless a reviewed global name is supplied.
// param storageAccountName = 'stsrenetdemoexample'

// RBAC remains off until the manually created SRE Agent principal ID is reviewed.
param enableSreAgentRbac = false
param sreAgentPrincipalId = ''
param enableMonitoringReader = false
