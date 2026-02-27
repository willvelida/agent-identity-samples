<#
.SYNOPSIS
    Tests the Agent Identity API by creating and then deleting an agent identity.
    All configuration is read from the azd environment — just run: pwsh ./test-client.ps1

.DESCRIPTION
    Uses the test client app (registered during azd up) to acquire a token via
    device code flow, then calls the deployed API to create and delete an agent identity.
#>
[CmdletBinding()]
param()

Write-Host "=== Agent Identity API Test Client ==="
Write-Host ""

# ── Read configuration from azd environment ─────────────────────────────────────

$tenantId   = azd env get-value AZURE_TENANT_ID 2>$null
$appId      = azd env get-value AGENT_BLUEPRINT_APP_ID 2>$null
$clientId   = azd env get-value TEST_CLIENT_APP_ID 2>$null
$apiUrl     = azd env get-value containerAppUrl 2>$null

if (-not $tenantId)  { Write-Error "AZURE_TENANT_ID not found in azd env. Run 'azd up' first."; exit 1 }
if (-not $appId)     { Write-Error "AGENT_BLUEPRINT_APP_ID not found in azd env. Run 'azd up' first."; exit 1 }
if (-not $clientId)  { Write-Error "TEST_CLIENT_APP_ID not found in azd env. Run 'azd up' first."; exit 1 }

# If containerAppUrl isn't set, try to build it from the FQDN
if (-not $apiUrl) {
    $fqdn = azd env get-value containerAppFqdn 2>$null
    if ($fqdn) {
        $apiUrl = "https://$fqdn"
    } else {
        Write-Error "Could not determine the API URL. Check azd env for containerAppUrl or containerAppFqdn."
        exit 1
    }
}

$scope = "api://$appId/access_agent"

Write-Host "  Tenant:      $tenantId"
Write-Host "  Blueprint:   $appId"
Write-Host "  Test Client: $clientId"
Write-Host "  API URL:     $apiUrl"
Write-Host "  Scope:       $scope"
Write-Host ""

# ── Acquire token via MSAL device code flow ─────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
    Write-Host "Installing MSAL.PS module..."
    Install-Module MSAL.PS -Scope CurrentUser -Force -AcceptLicense
}

Write-Host "Acquiring token (device code flow)..."
$token = Get-MsalToken -ClientId $clientId -TenantId $tenantId -Scopes $scope -DeviceCode

if (-not $token -or -not $token.AccessToken) {
    Write-Error "Failed to acquire token."
    exit 1
}

Write-Host "Token acquired for: $($token.Account.Username)"
Write-Host ""

$headers = @{
    Authorization  = "Bearer $($token.AccessToken)"
    "Content-Type" = "application/json"
}

# ── Test 1: Create an agent identity ────────────────────────────────────────────

$displayName = "test-agent-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$body = @{ displayName = $displayName } | ConvertTo-Json

Write-Host "Creating agent identity '$displayName'..."
try {
    $createResult = Invoke-RestMethod -Uri "$apiUrl/create-agent-identity" `
        -Method POST -Headers $headers -Body $body
    Write-Host "  Created agent identity: $($createResult.agentIdentityId)" -ForegroundColor Green
} catch {
    Write-Error "  Failed to create agent identity: $_"
    Write-Host "  Status: $($_.Exception.Response.StatusCode)"
    exit 1
}

# ── Test 2: Delete the agent identity ───────────────────────────────────────────

if ($createResult.agentIdentityId) {
    Write-Host ""
    $confirm = Read-Host "Do you want to delete agent identity $($createResult.agentIdentityId)? (y/N)"
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Write-Host "Waiting a few seconds for Graph API replication..."
        Start-Sleep -Seconds 5

        Write-Host "Deleting agent identity $($createResult.agentIdentityId)..."
        try {
            $deleteResult = Invoke-RestMethod -Uri "$apiUrl/agent-identity/$($createResult.agentIdentityId)" `
                -Method DELETE -Headers $headers
            Write-Host "  Deleted agent identity: $($deleteResult.deleted)" -ForegroundColor Green
        } catch {
            Write-Error "  Failed to delete agent identity: $_"
            Write-Host "  Status: $($_.Exception.Response.StatusCode)"
            exit 1
        }
    } else {
        Write-Host "  Skipped deletion. Agent identity $($createResult.agentIdentityId) remains active."
    }
}

Write-Host ""
Write-Host "=== Test complete ===" -ForegroundColor Green
