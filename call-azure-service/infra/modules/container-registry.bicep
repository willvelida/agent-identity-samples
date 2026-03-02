@description('Name of the container registry')
param name string

@description('Azure region')
param location string

@description('Principal ID to assign the AcrPull role to')
param acrPullPrincipalId string

@description('Resource ID of the Log Analytics workspace for diagnostic settings')
param logAnalyticsWorkspaceId string

// Built-in AcrPull role definition
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, acrPullPrincipalId, acrPullRoleId)
  scope: containerRegistry
  properties: {
    principalId: acrPullPrincipalId
    roleDefinitionId: acrPullRoleId
    principalType: 'ServicePrincipal'
    description: 'Allow the managed identity to pull images from ACR'
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${name}-diag'
  scope: containerRegistry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output loginServer string = containerRegistry.properties.loginServer
