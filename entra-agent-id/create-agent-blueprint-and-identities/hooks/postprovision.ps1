Write-Host "=== Post-provision: Configure Federated Identity Credential & Test Client ==="
Write-Host ""

$tenantId = azd env get-value AZURE_TENANT_ID 2>$null
if ($LASTEXITCODE -ne 0 -or -not $tenantId) {
    Write-Error "AZURE_TENANT_ID not set in azd environment."
    exit 1
}

$appId = azd env get-value AGENT_BLUEPRINT_APP_ID 2>$null
if ($LASTEXITCODE -ne 0 -or -not $appId) {
    Write-Error "AGENT_BLUEPRINT_APP_ID not set in azd environment."
    exit 1
}

$managedIdentityClientId = azd env get-value managedIdentityClientId 2>$null
if ($LASTEXITCODE -ne 0 -or -not $managedIdentityClientId) {
    Write-Error "managedIdentityClientId not set in azd environment. Provisioning may have failed."
    exit 1
}

$managedIdentityPrincipalId = azd env get-value managedIdentityPrincipalId 2>$null
if ($LASTEXITCODE -ne 0 -or -not $managedIdentityPrincipalId) {
    Write-Error "managedIdentityPrincipalId not set in azd environment. Provisioning may have failed."
    exit 1
}

# Install required modules
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.Applications)) {
    Install-Module Microsoft.Graph.Beta.Applications -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
    Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force
}

# Connect to Graph with scopes for federated cred + test client app registration
Connect-MgGraph -Scopes "AgentIdentityBlueprint.AddRemoveCreds.All","Application.ReadWrite.All","DelegatedPermissionGrant.ReadWrite.All" -TenantId $tenantId -UseDeviceCode -NoWelcome

# ── Step 1: Federated Identity Credential ──────────────────────────────────────

$federatedCredential = @{
    Name      = "container-app-msi"
    Issuer    = "https://login.microsoftonline.com/$tenantId/v2.0"
    Subject   = $managedIdentityPrincipalId
    Audiences = @("api://AzureADTokenExchange")
}

Write-Host "Configuring federated identity credential..."
Write-Host "  AppId: $appId"
Write-Host "  MSI Client ID: $managedIdentityClientId"
Write-Host "  MSI Principal ID (Subject): $managedIdentityPrincipalId"

$existing = Get-MgBetaApplicationFederatedIdentityCredential -ApplicationId $appId -Filter "name eq 'container-app-msi'" -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "Federated credential already exists, updating..."
    Update-MgBetaApplicationFederatedIdentityCredential `
        -ApplicationId $appId `
        -FederatedIdentityCredentialId $existing.Id `
        -BodyParameter $federatedCredential
} else {
    New-MgBetaApplicationFederatedIdentityCredential `
        -ApplicationId $appId `
        -BodyParameter $federatedCredential
}

Write-Host "Federated identity credential configured successfully."
Write-Host ""

# ── Step 2: Register Test Client App ───────────────────────────────────────────

$existingTestClientId = azd env get-value TEST_CLIENT_APP_ID 2>$null
if ($LASTEXITCODE -ne 0) { $existingTestClientId = $null }

if ($existingTestClientId) {
    Write-Host "Test client app already registered (clientId: $existingTestClientId). Skipping."
} else {
    Write-Host "Registering test client app..."

    # Look up the blueprint's service principal to get its object ID and scope ID
    $blueprintSp = Get-MgServicePrincipal -Filter "appId eq '$appId'"
    if (-not $blueprintSp) {
        Write-Error "Could not find service principal for blueprint appId: $appId"
        exit 1
    }

    # Get the access_agent scope ID from the blueprint app
    $blueprintApp = Get-MgBetaApplication -ApplicationId $appId
    $accessAgentScope = $blueprintApp.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "access_agent" }
    if (-not $accessAgentScope) {
        Write-Error "Could not find 'access_agent' scope on blueprint app."
        exit 1
    }

    # Create the test client app registration (public client with device code flow)
    $testApp = New-MgApplication -DisplayName "agent-identity-test-client" `
        -SignInAudience "AzureADMyOrg" `
        -IsFallbackPublicClient `
        -PublicClient @{ RedirectUris = @("https://login.microsoftonline.com/common/oauth2/nativeclient") } `
        -RequiredResourceAccess @(
            @{
                ResourceAppId  = $appId
                ResourceAccess = @(
                    @{
                        Id   = $accessAgentScope.Id
                        Type = "Scope"   # Delegated permission
                    }
                )
            }
        )

    $testClientAppId = $testApp.AppId
    $testClientObjectId = $testApp.Id
    Write-Host "Test client app registered: $testClientAppId (objectId: $testClientObjectId)"

    # Create a service principal for the test client so admin consent can be granted
    $testSp = New-MgServicePrincipal -AppId $testClientAppId
    Write-Host "Test client service principal created: $($testSp.Id)"

    # Grant admin consent for the delegated permission (access_agent)
    $me = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me" -OutputType PSObject
    New-MgOauth2PermissionGrant -ClientId $testSp.Id `
        -ConsentType "AllPrincipals" `
        -ResourceId $blueprintSp.Id `
        -Scope "access_agent" | Out-Null

    Write-Host "Admin consent granted for 'access_agent' scope."

    # Save to azd environment
    azd env set TEST_CLIENT_APP_ID $testClientAppId
    Write-Host "Test client app ID saved to azd environment: $testClientAppId"
}

Write-Host ""
Write-Host "=== Post-provision complete ==="
Write-Host ""
Write-Host "To test the API, run:"
Write-Host "  pwsh ./test-client.ps1"
