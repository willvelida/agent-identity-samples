targetScope = 'resourceGroup'

@description('The Azure region for all resources')
param location string = resourceGroup().location

@description('Base name used for generating resource names')
param appName string = 'agent-identity-api'

@description('Container image to deploy. Set automatically by azd deploy.')
param containerImage string = ''

@description('Tenant ID for the Entra ID configuration (set via AZURE_TENANT_ID)')
param tenantId string

@description('The agent identity blueprint app ID (set via AGENT_BLUEPRINT_APP_ID)')
param agentBlueprintAppId string

// Unique suffix for globally unique names
var uniqueSuffix = uniqueString(resourceGroup().id)
var acrName = replace('acr${appName}${uniqueSuffix}', '-', '')
// Use a placeholder image during initial provisioning when no image exists yet
var image = !empty(containerImage) ? containerImage : 'mcr.microsoft.com/dotnet/samples:aspnetapp'

module logAnalytics 'modules/log-analytics.bicep' = {
  params: {
    name: 'log-${appName}'
    location: location
  }
}

module identity 'modules/managed-identity.bicep' = {
  params: {
    name: 'id-${appName}'
    location: location
  }
}

module acr 'modules/container-registry.bicep' = {
  params: {
    name: acrName
    location: location
    acrPullPrincipalId: identity.outputs.principalId
  }
}

module app 'modules/container-app.bicep' = {
  params: {
    name: 'ca-${appName}'
    location: location
    environmentName: 'cae-${appName}'
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalytics.outputs.sharedKey
    containerImage: image
    containerDisplayName: appName
    managedIdentityId: identity.outputs.id
    managedIdentityClientId: identity.outputs.clientId
    acrLoginServer: acr.outputs.loginServer
    tenantId: tenantId
    agentBlueprintAppId: agentBlueprintAppId
  }
}

// Outputs
output containerAppFqdn string = app.outputs.fqdn
output containerAppUrl string = app.outputs.url
output managedIdentityPrincipalId string = identity.outputs.principalId
output managedIdentityClientId string = identity.outputs.clientId

// azd-expected outputs
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acrName
