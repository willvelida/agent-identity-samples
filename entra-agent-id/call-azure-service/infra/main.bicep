targetScope = 'resourceGroup'

@description('The Azure region for all resources')
param location string = resourceGroup().location

@description('Base name used for generating resource names')
param appName string = 'call-azure-svc'

@description('Tenant ID for the Entra ID configuration (set via AZURE_TENANT_ID)')
param tenantId string

@description('The agent identity blueprint app ID (set via AGENT_BLUEPRINT_APP_ID)')
param agentBlueprintAppId string

@description('The agent identity ID (set via AGENT_IDENTITY_ID)')
param agentIdentityId string

@description('The frontend app registration client ID (set via FRONTEND_APP_ID)')
param frontendAppId string = ''

@description('The API container app URL (set from previous deployment output)')
param apiUrl string = ''

@description('Container image for the API. Set automatically by azd deploy.')
param apiContainerImage string = ''

@description('Container image for the frontend. Set automatically by azd deploy.')
param frontendContainerImage string = ''

// Unique suffix for globally unique names
var uniqueSuffix = uniqueString(resourceGroup().id)
var acrName = replace('acr${appName}${uniqueSuffix}', '-', '')
var cosmosName = 'cosmos-${appName}-${uniqueSuffix}'
var openAiName = 'oai-${appName}-${uniqueSuffix}'

// Use placeholder images during initial provisioning when no image exists yet
var apiImage = !empty(apiContainerImage) ? apiContainerImage : 'mcr.microsoft.com/dotnet/samples:aspnetapp'
var frontendImage = !empty(frontendContainerImage)
  ? frontendContainerImage
  : 'mcr.microsoft.com/dotnet/samples:aspnetapp'

// Log Analytics
module logAnalytics 'modules/log-analytics.bicep' = {
  params: {
    name: 'log-${appName}'
    location: location
  }
}

// Application Insights
module appInsights 'modules/app-insights.bicep' = {
  params: {
    name: 'appi-${appName}'
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// User-Assigned Managed Identity
module identity 'modules/managed-identity.bicep' = {
  params: {
    name: 'id-${appName}'
    location: location
  }
}

// Azure Container Registry
module acr 'modules/container-registry.bicep' = {
  params: {
    name: acrName
    location: location
    acrPullPrincipalId: identity.outputs.principalId
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// Azure Cosmos DB (Serverless)
module cosmos 'modules/cosmos-db.bicep' = {
  params: {
    name: cosmosName
    location: location
    managedIdentityPrincipalId: identity.outputs.principalId
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// Azure OpenAI
module openAi 'modules/openai.bicep' = {
  params: {
    name: openAiName
    location: location
    managedIdentityPrincipalId: identity.outputs.principalId
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// Shared Container Apps Environment
module containerAppsEnv 'modules/container-apps-env.bicep' = {
  params: {
    name: 'cae-${appName}'
    location: location
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalytics.outputs.sharedKey
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// Container App — Frontend (deployed first to avoid circular dependency with API)
module frontendApp 'modules/container-app-frontend.bicep' = {
  params: {
    name: 'ca-${appName}-web'
    location: location
    environmentId: containerAppsEnv.outputs.id
    containerImage: frontendImage
    managedIdentityId: identity.outputs.id
    managedIdentityClientId: identity.outputs.clientId
    acrLoginServer: acr.outputs.loginServer
    tenantId: tenantId
    agentBlueprintAppId: agentBlueprintAppId
    frontendAppId: frontendAppId
    apiUrl: apiUrl // Populated from containerAppApiUrl env var after first deploy
    appInsightsConnectionString: appInsights.outputs.connectionString
  }
}

// Container App — API (references frontend URL for CORS)
module apiApp 'modules/container-app-api.bicep' = {
  params: {
    name: 'ca-${appName}-api'
    location: location
    environmentId: containerAppsEnv.outputs.id
    containerImage: apiImage
    managedIdentityId: identity.outputs.id
    managedIdentityClientId: identity.outputs.clientId
    acrLoginServer: acr.outputs.loginServer
    tenantId: tenantId
    agentBlueprintAppId: agentBlueprintAppId
    agentIdentityId: agentIdentityId
    cosmosDbEndpoint: cosmos.outputs.endpoint
    openAiEndpoint: openAi.outputs.endpoint
    openAiDeploymentName: openAi.outputs.deploymentName
    appInsightsConnectionString: appInsights.outputs.connectionString
    frontendUrl: frontendApp.outputs.url
  }
}

// Outputs for azd env and postprovision hooks
output managedIdentityPrincipalId string = identity.outputs.principalId
output managedIdentityClientId string = identity.outputs.clientId
output containerAppApiUrl string = apiApp.outputs.url
output containerAppFrontendUrl string = frontendApp.outputs.url
output cosmosDbEndpoint string = cosmos.outputs.endpoint
output openAiEndpoint string = openAi.outputs.endpoint
output appInsightsConnectionString string = appInsights.outputs.connectionString

// azd-expected outputs
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acrName
