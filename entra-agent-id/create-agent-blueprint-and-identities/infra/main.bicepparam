using 'main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'australiaeast')
param appName = 'agent-identity-api'
param tenantId = readEnvironmentVariable('AZURE_TENANT_ID', '')
param agentBlueprintAppId = readEnvironmentVariable('AGENT_BLUEPRINT_APP_ID', '')
