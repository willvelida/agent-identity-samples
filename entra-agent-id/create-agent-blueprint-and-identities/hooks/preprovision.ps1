Write-Host "=== Pre-provision: Agent Identity Blueprint Setup ==="
Write-Host ""

# Check if blueprint has already been created (skip if appId is already set as an azd env variable)
$existingAppId = azd env get-value AGENT_BLUEPRINT_APP_ID 2>$null
if ($LASTEXITCODE -ne 0) { $existingAppId = $null }

if ($existingAppId) {
    Write-Host "Blueprint already configured (appId: $existingAppId). Skipping setup."
    Write-Host "To re-run, clear the value with: azd env set AGENT_BLUEPRINT_APP_ID ''"
    return
}

# Get tenant ID from azd environment or prompt
$tenantId = azd env get-value AZURE_TENANT_ID 2>$null
if ($LASTEXITCODE -ne 0) { $tenantId = $null }
if (-not $tenantId) {
    $tenantId = Read-Host "Enter your Entra ID Tenant ID"
    azd env set AZURE_TENANT_ID $tenantId
}

$blueprintName = azd env get-value AGENT_BLUEPRINT_NAME 2>$null
if ($LASTEXITCODE -ne 0) { $blueprintName = $null }
if (-not $blueprintName) {
    $blueprintName = Read-Host "Enter a display name for the Agent Identity Blueprint"
    azd env set AGENT_BLUEPRINT_NAME $blueprintName
}

Write-Host ""
Write-Host "Running setup.ps1 to create the agent identity blueprint..."
Write-Host ""

# Run the blueprint setup script and capture output
& "$PSScriptRoot/../setup.ps1" -TenantId $tenantId -AgentBlueprintPrincipalName $blueprintName
if ($LASTEXITCODE -ne 0) {
    Write-Error "setup.ps1 failed with exit code $LASTEXITCODE"
    exit 1
}

# Read the appId that setup.ps1 wrote to the azd environment
$appId = azd env get-value AGENT_BLUEPRINT_APP_ID 2>$null
if ($LASTEXITCODE -ne 0 -or -not $appId) {
    Write-Error "Failed to get AGENT_BLUEPRINT_APP_ID from azd environment. setup.ps1 may have failed."
    exit 1
}

Write-Host ""
Write-Host "Blueprint appId saved to azd environment: $appId"
Write-Host "=== Pre-provision complete ==="
