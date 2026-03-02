@description('Name of the Container App')
param name string

@description('Azure region')
param location string

@description('Resource ID of the Container Apps Environment')
param environmentId string

@description('Container image to deploy')
param containerImage string

@description('Resource ID of the user-assigned managed identity')
param managedIdentityId string

@description('Client ID of the user-assigned managed identity')
param managedIdentityClientId string

@description('ACR login server (e.g. myacr.azurecr.io)')
param acrLoginServer string

@description('Tenant ID for the Entra ID configuration')
param tenantId string

@description('The agent identity blueprint app ID')
param agentBlueprintAppId string

@description('The agent identity ID')
param agentIdentityId string

@description('Azure Cosmos DB endpoint')
param cosmosDbEndpoint string

@description('Azure OpenAI endpoint')
param openAiEndpoint string

@description('Azure OpenAI deployment name')
param openAiDeploymentName string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('URL of the frontend Container App (for CORS)')
param frontendUrl string = ''

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: {
    'azd-service-name': 'api'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'chat-agent-api'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'AzureAd__Instance'
              value: environment().authentication.loginEndpoint
            }
            {
              name: 'AzureAd__TenantId'
              value: tenantId
            }
            {
              name: 'AzureAd__ClientId'
              value: agentBlueprintAppId
            }
            {
              name: 'AzureAd__ClientCredentials__0__SourceType'
              value: 'SignedAssertionFromManagedIdentity'
            }
            {
              name: 'AzureAd__ClientCredentials__0__ManagedIdentityClientId'
              value: managedIdentityClientId
            }
            {
              name: 'AgentIdentity__AgentIdentityId'
              value: agentIdentityId
            }
            {
              name: 'Cosmos__Endpoint'
              value: cosmosDbEndpoint
            }
            {
              name: 'Cosmos__DatabaseName'
              value: 'chat-db'
            }
            {
              name: 'Cosmos__ContainerName'
              value: 'conversations'
            }
            {
              name: 'OpenAI__Endpoint'
              value: openAiEndpoint
            }
            {
              name: 'OpenAI__DeploymentName'
              value: openAiDeploymentName
            }
            {
              name: 'Frontend__Url'
              value: frontendUrl
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsightsConnectionString
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
}

output fqdn string = containerApp.properties.configuration.ingress.fqdn
output url string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
