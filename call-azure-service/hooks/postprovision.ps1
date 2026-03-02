Write-Host "=== Post-provision: Federated Identity Credential, Agent Identity, Frontend App & RBAC ==="
Write-Host ""

# ── Read required values from azd environment ──────────────────────────────────

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

$containerAppFrontendUrl = azd env get-value containerAppFrontendUrl 2>$null
if ($LASTEXITCODE -ne 0 -or -not $containerAppFrontendUrl) {
    Write-Error "containerAppFrontendUrl not set in azd environment. Provisioning may have failed."
    exit 1
}

# ── Install required modules ───────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.Applications)) {
    Install-Module Microsoft.Graph.Beta.Applications -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.Identity.SignIns)) {
    Install-Module Microsoft.Graph.Beta.Identity.SignIns -Scope CurrentUser -Force
}

# Connect to Graph with scopes for federated cred, app registration, and consent.
# Note: Agent identity creation uses the blueprint's own client credentials (not a delegated scope).
Write-Host "Connecting to Microsoft Graph (device code flow)..."
Write-Host "You have 300 seconds to complete the device code login."

Connect-MgGraph -Scopes @(
    "AgentIdentityBlueprint.AddRemoveCreds.All",
    "Application.ReadWrite.All",
    "DelegatedPermissionGrant.ReadWrite.All"
) -TenantId $tenantId -UseDeviceCode -NoWelcome

# Verify the connection succeeded
$mgContext = Get-MgContext
if (-not $mgContext) {
    Write-Error "Failed to connect to Microsoft Graph. Please try again and complete the device code login promptly."
    exit 1
}
Write-Host "Connected to Microsoft Graph as $($mgContext.Account)"

# ── Step 1: Federated Identity Credential ──────────────────────────────────────
# Links the managed identity to the agent identity blueprint so Container Apps
# can authenticate as the blueprint using the managed identity's assertion.

Write-Host "── Step 1: Federated Identity Credential ──"

$federatedCredential = @{
    Name      = "container-app-msi"
    Issuer    = "https://login.microsoftonline.com/$tenantId/v2.0"
    Subject   = $managedIdentityPrincipalId
    Audiences = @("api://AzureADTokenExchange")
}

Write-Host "  AppId: $appId"
Write-Host "  MSI Client ID: $managedIdentityClientId"
Write-Host "  MSI Principal ID (Subject): $managedIdentityPrincipalId"

$existing = Get-MgBetaApplicationFederatedIdentityCredential -ApplicationId $appId -Filter "name eq 'container-app-msi'" -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "  Federated credential already exists, updating..."
    Update-MgBetaApplicationFederatedIdentityCredential `
        -ApplicationId $appId `
        -FederatedIdentityCredentialId $existing.Id `
        -BodyParameter $federatedCredential
} else {
    New-MgBetaApplicationFederatedIdentityCredential `
        -ApplicationId $appId `
        -BodyParameter $federatedCredential
}

Write-Host "  Federated identity credential configured successfully."
Write-Host ""

# ── Step 2: Create Agent Identity ──────────────────────────────────────────────
# Creates a single shared agent identity for the chat agent. This identity will
# be used by the API to call Cosmos DB via MicrosoftIdentityTokenCredential.

Write-Host "── Step 2: Agent Identity ──"

$existingAgentId = azd env get-value AGENT_IDENTITY_ID 2>$null
if ($LASTEXITCODE -ne 0) { $existingAgentId = $null }

if ($existingAgentId) {
    Write-Host "  Agent identity already created (appId: $existingAgentId). Skipping."
} else {
    # Agent identity creation requires the blueprint's own access token (client credentials flow),
    # not a user delegated permission. See:
    # https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/create-delete-agent-identities

    $blueprintSecret = azd env get-value AGENT_BLUEPRINT_CLIENT_SECRET 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $blueprintSecret) {
        Write-Error "AGENT_BLUEPRINT_CLIENT_SECRET not set. Re-run setup.ps1 to create a client secret for the blueprint."
        exit 1
    }

    # Get the sponsor user ID saved during setup.ps1
    $sponsorUserId = azd env get-value SPONSOR_USER_ID 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sponsorUserId) {
        Write-Error "SPONSOR_USER_ID not set. Re-run setup.ps1 to save the sponsor user ID."
        exit 1
    }

    # Get an access token as the blueprint using client credentials grant
    $tokenBody = @{
        client_id     = $appId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $blueprintSecret
        grant_type    = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $tokenBody

    if (-not $tokenResponse.access_token) {
        Write-Error "Failed to acquire blueprint access token."
        exit 1
    }

    $blueprintToken = $tokenResponse.access_token
    Write-Host "  Acquired blueprint access token."

    $agentBody = @{
        "@odata.type"              = "#Microsoft.Graph.AgentIdentity"
        "displayName"              = "chat-agent-cosmos"
        "agentIdentityBlueprintId" = $appId
        "sponsors@odata.bind"      = @("https://graph.microsoft.com/v1.0/users/$sponsorUserId")
    } | ConvertTo-Json -Depth 5

    Write-Host "  Creating agent identity with sponsor: $sponsorUserId"

    # Call Graph beta API using the blueprint's own token
    $agentResponse = Invoke-RestMethod -Method POST `
        -Uri "https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" `
        -Headers @{
            "Authorization" = "Bearer $blueprintToken"
            "OData-Version" = "4.0"
        } `
        -Body $agentBody `
        -ContentType "application/json"

    $agentIdentityId = $agentResponse.appId
    if (-not $agentIdentityId) {
        Write-Error "Failed to create agent identity — no appId returned."
        exit 1
    }

    azd env set AGENT_IDENTITY_ID $agentIdentityId
    Write-Host "  Agent identity created: $agentIdentityId"
}

$agentIdentityId = azd env get-value AGENT_IDENTITY_ID
Write-Host ""

# ── Step 2b: Assign Cosmos DB RBAC role to Agent Identity ──────────────────────
# The agent identity needs data-plane access to Cosmos DB since the API uses
# MicrosoftIdentityTokenCredential.WithAgentIdentity() to authenticate.

Write-Host "── Step 2b: Cosmos DB Role Assignment for Agent Identity ──"

$cosmosEndpoint = azd env get-value cosmosDbEndpoint 2>$null
if ($cosmosEndpoint) {
    # Extract account name from endpoint URL
    $cosmosAccountName = ([System.Uri]$cosmosEndpoint).Host.Split('.')[0]
    $subscriptionId = azd env get-value AZURE_SUBSCRIPTION_ID 2>$null
    $rgName = azd env get-value AZURE_RESOURCE_GROUP 2>$null
    if (-not $rgName) { $rgName = "rg-agentid-dev" }

    # Look up the agent identity's service principal object ID
    $agentSpObjectId = (az ad sp show --id $agentIdentityId --query id -o tsv 2>$null)
    if ($agentSpObjectId) {
        $cosmosScope = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccountName"
        $existingAssignment = az cosmosdb sql role assignment list `
            --account-name $cosmosAccountName `
            --resource-group $rgName `
            --query "[?principalId=='$agentSpObjectId']" -o json 2>$null | ConvertFrom-Json

        if ($existingAssignment -and $existingAssignment.Count -gt 0) {
            Write-Host "  Cosmos DB role already assigned to agent identity. Skipping."
        } else {
            Write-Host "  Assigning Cosmos DB Built-in Data Contributor role to agent identity ($agentSpObjectId)..."
            az cosmosdb sql role assignment create `
                --account-name $cosmosAccountName `
                --resource-group $rgName `
                --role-definition-id "00000000-0000-0000-0000-000000000002" `
                --principal-id $agentSpObjectId `
                --scope $cosmosScope 2>&1 | Out-Null
            Write-Host "  Cosmos DB role assigned successfully."
        }
    } else {
        Write-Warning "  Could not find service principal for agent identity $agentIdentityId. Cosmos RBAC not assigned."
    }
} else {
    Write-Warning "  cosmosDbEndpoint not set. Skipping Cosmos DB role assignment."
}
Write-Host ""

# ── Step 3: Register Frontend App ─────────────────────────────────────────────
# Creates a public client app registration for the Blazor frontend with
# the correct redirect URI and a delegated permission to the blueprint's
# access_agent scope.

Write-Host "── Step 3: Frontend App Registration ──"

$existingFrontendId = azd env get-value FRONTEND_APP_ID 2>$null
if ($LASTEXITCODE -ne 0) { $existingFrontendId = $null }

if ($existingFrontendId) {
    Write-Host "  Frontend app already registered (clientId: $existingFrontendId). Skipping app creation."
    $frontendAppId = $existingFrontendId
} else {
    # Look up the blueprint's service principal and access_agent scope
    $blueprintSp = Get-MgBetaServicePrincipal -Filter "appId eq '$appId'"
    if (-not $blueprintSp) {
        Write-Error "Could not find service principal for blueprint appId: $appId"
        exit 1
    }

    $blueprintApp = Get-MgBetaApplication -ApplicationId $appId
    $accessAgentScope = $blueprintApp.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "access_agent" }
    if (-not $accessAgentScope) {
        Write-Error "Could not find 'access_agent' scope on blueprint app."
        exit 1
    }

    # Redirect URIs for the Blazor Server app (deployed + localhost for dev)
    $redirectUris = @(
        "$containerAppFrontendUrl/signin-oidc",
        "https://localhost:7001/signin-oidc"
    )

    $frontendApp = New-MgBetaApplication -DisplayName "call-azure-service-frontend" `
        -SignInAudience "AzureADMyOrg" `
        -Web @{
            RedirectUris = $redirectUris
        } `
        -RequiredResourceAccess @(
            @{
                ResourceAppId  = $appId
                ResourceAccess = @(
                    @{
                        Id   = $accessAgentScope.Id
                        Type = "Scope"
                    }
                )
            }
        )

    $frontendAppId = $frontendApp.AppId
    Write-Host "  Frontend app registered: $frontendAppId (objectId: $($frontendApp.Id))"

    # Create a service principal for the frontend app
    $frontendSp = New-MgBetaServicePrincipal -AppId $frontendAppId
    Write-Host "  Frontend service principal created: $($frontendSp.Id)"

    # Grant admin consent for the access_agent delegated permission
    New-MgBetaOauth2PermissionGrant -ClientId $frontendSp.Id `
        -ConsentType "AllPrincipals" `
        -ResourceId $blueprintSp.Id `
        -Scope "access_agent" `
        -ExpiryTime (Get-Date).AddYears(1) | Out-Null

    Write-Host "  Admin consent granted for 'access_agent' scope."

    azd env set FRONTEND_APP_ID $frontendAppId
    Write-Host "  Frontend app ID saved to azd environment: $frontendAppId"
}

# Always ensure the frontend app has a federated identity credential
# (This runs even if the app already existed, in case the FIC was missed)
$frontendAppObj = Get-MgBetaApplication -Filter "appId eq '$frontendAppId'"
if ($frontendAppObj) {
    $frontendObjectId = $frontendAppObj.Id
    $existingFic = Get-MgBetaApplicationFederatedIdentityCredential `
        -ApplicationId $frontendObjectId `
        -Filter "name eq 'frontend-msi'" -ErrorAction SilentlyContinue

    if ($existingFic) {
        Write-Host "  Frontend FIC already exists. Skipping."
    } else {
        $frontendFic = @{
            Name      = "frontend-msi"
            Issuer    = "https://login.microsoftonline.com/$tenantId/v2.0"
            Subject   = $managedIdentityPrincipalId
            Audiences = @("api://AzureADTokenExchange")
        }

        New-MgBetaApplicationFederatedIdentityCredential `
            -ApplicationId $frontendObjectId `
            -BodyParameter $frontendFic

        Write-Host "  Federated identity credential added to frontend app."
    }
} else {
    Write-Warning "  Could not find frontend app object to add FIC."
}

Write-Host ""

# ── Step 4: Register Test Client App ──────────────────────────────────────────
# Creates a public client app (device code flow) for testing the API from the
# command line via test-client.ps1.

Write-Host "── Step 4: Test Client App Registration ──"

$existingTestClientId = azd env get-value TEST_CLIENT_APP_ID 2>$null
if ($LASTEXITCODE -ne 0) { $existingTestClientId = $null }

if ($existingTestClientId) {
    Write-Host "  Test client app already registered (clientId: $existingTestClientId). Skipping."
} else {
    $blueprintSp = Get-MgBetaServicePrincipal -Filter "appId eq '$appId'"
    $blueprintApp = Get-MgBetaApplication -ApplicationId $appId
    $accessAgentScope = $blueprintApp.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq "access_agent" }

    $testApp = New-MgBetaApplication -DisplayName "call-azure-service-test-client" `
        -SignInAudience "AzureADMyOrg" `
        -IsFallbackPublicClient `
        -PublicClient @{ RedirectUris = @("https://login.microsoftonline.com/common/oauth2/nativeclient") } `
        -RequiredResourceAccess @(
            @{
                ResourceAppId  = $appId
                ResourceAccess = @(
                    @{
                        Id   = $accessAgentScope.Id
                        Type = "Scope"
                    }
                )
            }
        )

    $testClientAppId = $testApp.AppId
    Write-Host "  Test client app registered: $testClientAppId"

    $testSp = New-MgBetaServicePrincipal -AppId $testClientAppId
    Write-Host "  Test client service principal created: $($testSp.Id)"

    New-MgBetaOauth2PermissionGrant -ClientId $testSp.Id `
        -ConsentType "AllPrincipals" `
        -ResourceId $blueprintSp.Id `
        -Scope "access_agent" `
        -ExpiryTime (Get-Date).AddYears(1) | Out-Null

    Write-Host "  Admin consent granted for 'access_agent' scope."

    azd env set TEST_CLIENT_APP_ID $testClientAppId
    Write-Host "  Test client app ID saved to azd environment: $testClientAppId"
}

Write-Host ""

Write-Host "=== Post-provision complete ==="
Write-Host ""

# Re-provision to inject FRONTEND_APP_ID (and AGENT_IDENTITY_ID) into the container apps.
# These values were created during postprovision and are now in the azd env.
# Use a guard to prevent infinite recursion (azd provision triggers postprovision again).
$alreadyReprovisioned = $env:POSTPROVISION_REPROVISION_DONE
if (-not $alreadyReprovisioned) {
    Write-Host "Re-provisioning to update container apps with new app registration IDs..."
    $env:POSTPROVISION_REPROVISION_DONE = "1"
    azd provision --no-prompt
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Re-provision failed. You can manually run 'azd provision' and then 'azd deploy'."
    }
} else {
    Write-Host "Skipping re-provision (already done in this session)."
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Deploy the application:  azd deploy"
Write-Host "  2. Test the API:            pwsh ./test-client.ps1"
Write-Host "  3. Open the frontend:       $(azd env get-value containerAppFrontendUrl 2>$null)"
