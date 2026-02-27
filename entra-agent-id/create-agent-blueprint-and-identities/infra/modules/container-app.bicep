@description('Name of the Container App')
param name string

@description('Azure region')
param location string

@description('Name of the Container Apps Environment')
param environmentName string

@description('Log Analytics workspace customer ID')
param logAnalyticsCustomerId string

@description('Log Analytics workspace shared key')
@secure()
param logAnalyticsSharedKey string

@description('Container image to deploy')
param containerImage string

@description('Display name for the container')
param containerDisplayName string

@description('Resource ID of the user-assigned managed identity')
param managedIdentityId string

@description('ACR login server (e.g. myacr.azurecr.io)')
param acrLoginServer string

@description('Tenant ID for the Entra ID configuration')
param tenantId string

@description('The agent identity blueprint app ID')
param agentBlueprintAppId string

@description('Client ID of the user-assigned managed identity')
param managedIdentityClientId string

// Container Apps Environment
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

// Container App
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
    managedEnvironmentId: containerAppsEnvironment.id
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
          name: containerDisplayName
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
              name: 'AgentIdentity__BlueprintId'
              value: agentBlueprintAppId
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

output fqdn string = containerApp.properties.configuration.ingress.?fqdn ?? ''
output url string = 'https://${containerApp.properties.configuration.ingress.?fqdn ?? ''}'
