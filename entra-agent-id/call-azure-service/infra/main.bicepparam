using 'main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'australiaeast')
param appName = 'call-azure-svc'
param tenantId = readEnvironmentVariable('AZURE_TENANT_ID', '')
param agentBlueprintAppId = readEnvironmentVariable('AGENT_BLUEPRINT_APP_ID', '')
param agentIdentityId = readEnvironmentVariable('AGENT_IDENTITY_ID', '')
param frontendAppId = readEnvironmentVariable('FRONTEND_APP_ID', '')
param apiUrl = readEnvironmentVariable('containerAppApiUrl', '')
