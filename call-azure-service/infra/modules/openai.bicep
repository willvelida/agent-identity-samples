@description('Name of the Azure OpenAI resource')
param name string

@description('Azure region')
param location string

@description('Principal ID of the managed identity to assign Cognitive Services OpenAI User role')
param managedIdentityPrincipalId string

@description('Resource ID of the Log Analytics workspace for diagnostic settings')
param logAnalyticsWorkspaceId string

@description('Name of the GPT model deployment')
param deploymentName string = 'gpt-4o'

@description('GPT model name')
param modelName string = 'gpt-4o'

@description('GPT model version')
param modelVersion string = '2024-11-20'

@description('Deployment capacity in thousands of tokens per minute')
param deploymentCapacity int = 30

// Built-in Cognitive Services OpenAI User role definition
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
  }
}

resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAiAccount
  name: deploymentName
  sku: {
    name: 'Standard'
    capacity: deploymentCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

resource openAiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAiAccount.id, managedIdentityPrincipalId, cognitiveServicesOpenAIUserRoleId)
  scope: openAiAccount
  properties: {
    principalId: managedIdentityPrincipalId
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
    principalType: 'ServicePrincipal'
    description: 'Allow the managed identity to call Azure OpenAI deployments'
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${name}-diag'
  scope: openAiAccount
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

output endpoint string = openAiAccount.properties.endpoint
output deploymentName string = gptDeployment.name
