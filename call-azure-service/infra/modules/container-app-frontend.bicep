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

@description('The agent identity blueprint app ID (used as the API scope audience)')
param agentBlueprintAppId string

@description('The frontend app registration client ID')
param frontendAppId string = ''

@description('URL of the backend Chat Agent API')
param apiUrl string

@description('Application Insights connection string')
param appInsightsConnectionString string

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: {
    'azd-service-name': 'frontend'
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
          name: 'chat-frontend'
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
              value: frontendAppId
            }
            {
              name: 'AzureAd__CallbackPath'
              value: '/signin-oidc'
            }
            {
              name: 'AzureAd__SignedOutCallbackPath'
              value: '/signout-callback-oidc'
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
              name: 'DownstreamApis__ChatApi__BaseUrl'
              value: apiUrl
            }
            {
              name: 'DownstreamApis__ChatApi__Scopes__0'
              value: 'api://${agentBlueprintAppId}/access_agent'
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
