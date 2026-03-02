[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $TenantId,

    [Parameter(Mandatory = $true)]
    [string]
    $AgentBlueprintPrincipalName
)

# Install required modules (if not already installed)
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.Applications)) {
    Install-Module Microsoft.Graph.Beta.Applications -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
}

# Connect once with all required scopes
$allScopes = @(
    "AgentIdentityBlueprint.Create",
    "AgentIdentityBlueprint.AddRemoveCreds.All",
    "AgentIdentityBlueprint.ReadWrite.All",
    "AgentIdentityBlueprintPrincipal.Create",
    "User.Read"
)
Connect-MgGraph -Scopes $allScopes -TenantId $TenantId -UseDeviceCode -NoWelcome

# Get current signed-in user via REST (works with WAM where Get-MgContext.Account is empty)
$user = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me" -OutputType PSObject

Write-Host "Current user: $($user.DisplayName) ($($user.Id))"
Write-Host "Sponsor user: $($user.DisplayName) ($($user.Id))"

# Step 1: Create the agent identity blueprint
$body = @{
    "@odata.type" = "Microsoft.Graph.AgentIdentityBlueprint"
    "displayName" = $AgentBlueprintPrincipalName
    "sponsors@odata.bind" = @("https://graph.microsoft.com/v1.0/users/$($user.Id)")
    "owners@odata.bind" = @("https://graph.microsoft.com/v1.0/users/$($user.Id)")
} | ConvertTo-Json -Depth 5

$response = Invoke-MgGraphRequest `
    -Method POST `
    -Uri "https://graph.microsoft.com/beta/applications/graph.agentIdentityBlueprint" `
    -Body $body `
    -ContentType "application/json"

$response

$applicationId = $response.appId
if (-not $applicationId) {
    Write-Error "Failed to create agent identity blueprint — no appId returned from Graph API."
    exit 1
}
Write-Host "Blueprint appId: $applicationId"

# Step 2: Configure identifier URI and OAuth2 scope (access_agent)
$IdentifierUri = "api://$applicationId"
$ScopeId = [guid]::NewGuid()

$scope = @{
    adminConsentDescription = "Allow the application to access the agent on behalf of the signed-in user."
    adminConsentDisplayName = "Access agent"
    id                      = $ScopeId
    isEnabled               = $true
    type                    = "User"
    value                   = "access_agent"
}

Update-MgBetaApplication -ApplicationId $applicationId `
    -IdentifierUris @($IdentifierUri) `
    -Api @{ oauth2PermissionScopes = @($scope) }

Write-Host "Configured identifier URI: $IdentifierUri"
Write-Host "Created scope 'access_agent' with ID: $ScopeId"

# Step 3: Create the agent blueprint principal (service principal)
$spBody = @{
    appId = $applicationId
}

$spResponse = Invoke-MgGraphRequest `
    -Method POST `
    -Uri "https://graph.microsoft.com/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal" `
    -Headers @{ "OData-Version" = "4.0" } `
    -Body ($spBody | ConvertTo-Json)

Write-Host "Agent blueprint principal created for appId: $applicationId"
$spResponse

# Step 4: Add a client secret for local/postprovision use
# (Production should use managed identity + FIC; this secret is for the setup flow)
$secretResult = Add-MgApplicationPassword -ApplicationId $applicationId `
    -PasswordCredential @{
        displayName = "postprovision-setup"
        endDateTime = (Get-Date).AddMonths(6).ToString("o")
    }

if (-not $secretResult.SecretText) {
    Write-Error "Failed to create client secret for blueprint."
    exit 1
}

Write-Host "Client secret created for blueprint (store securely — shown only once)."

# Save appId, secret, and sponsor user ID to azd environment for downstream use
azd env set AGENT_BLUEPRINT_APP_ID $applicationId
azd env set AGENT_BLUEPRINT_CLIENT_SECRET $secretResult.SecretText
azd env set SPONSOR_USER_ID $user.Id

Write-Host "Sponsor user ID saved to azd environment: $($user.Id)"
