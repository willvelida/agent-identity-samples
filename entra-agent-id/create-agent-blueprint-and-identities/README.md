# Create Agent Identity Blueprint and Identities

This sample demonstrates how to create and manage [Entra Agent Identities](https://learn.microsoft.com/entra/identity/agent-identities/) using a .NET API deployed to Azure Container Apps. The API uses Microsoft Identity Web to authenticate callers and calls the Microsoft Graph beta API to create and delete agent identities on behalf of the signed-in user.

## What's included

| Component | Description |
|---|---|
| **`src/AgentIdentityApi`** | .NET minimal API that exposes endpoints to create and delete agent identities via Microsoft Graph |
| **`infra/`** | Bicep templates that provision a Container Registry, Container App, Managed Identity, and Log Analytics workspace |
| **`setup.ps1`** | Creates the Agent Identity Blueprint and its service principal in Entra ID |
| **`hooks/preprovision.ps1`** | Runs `setup.ps1` automatically during `azd up` to create the blueprint |
| **`hooks/postprovision.ps1`** | Configures a federated identity credential on the blueprint app and registers a test client app with admin consent |
| **`test-client.ps1`** | Acquires a token via device code flow and tests both the create and delete endpoints |

## Architecture

```
┌──────────────┐   device code    ┌─────────────────┐   bearer token   ┌──────────────────────┐
│  Test Client │  ──────────────► │   Entra ID      │ ◄─────────────── │  Agent Identity API  │
│  (pwsh)      │                  │   (OAuth 2.0)   │                  │  (Container App)     │
└──────┬───────┘                  └─────────────────┘                  └──────────┬───────────┘
       │                                                                         │
       │  POST /create-agent-identity                                            │ app-only token
       │  DELETE /agent-identity/{id}                                            │ (federated credential)
       │ ───────────────────────────────────────────────────────────────────────► │
       │                                                                         ▼
       │                                                               ┌─────────────────────┐
       │                                                               │  Microsoft Graph     │
       │                                                               │  (beta API)          │
       └───────────────────────────────────────────────────────────────►└─────────────────────┘
```

The API authenticates incoming requests using the blueprint's app registration, then acquires an app-only token (via a managed identity federated credential) to call Microsoft Graph and create/delete agent identities.

## Prerequisites

- **Azure subscription** — [Create one for free](https://azure.microsoft.com/free/)
- **Entra ID tenant** — You need sufficient permissions to create app registrations and grant admin consent
- **Azure Developer CLI (`azd`)** — [Install azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- **PowerShell 7+** — [Install PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- **.NET 10 SDK** — [Install .NET](https://dotnet.microsoft.com/download)
- **Docker** — Required for building the container image

## Step 1: Clone the repository

```bash
git clone https://github.com/Azure-Samples/agent-identity-samples.git
cd agent-identity-samples/entra-agent-id/create-agent-blueprint-and-identities
```

## Step 2: Log in to Azure

Log in to both the Azure CLI and the Azure Developer CLI:

```bash
azd auth login
az login
```

## Step 3: Initialize the environment

Create a new azd environment. You'll be prompted for a subscription and location:

```bash
azd init
```

When prompted, select your Azure subscription and a region (e.g., `australiaeast`).

## Step 4: Deploy everything with `azd up`

This single command handles the full setup:

```bash
azd up
```

Here's what happens during `azd up`:

### Pre-provision (automatic)

The `preprovision` hook runs `setup.ps1`, which:

1. Prompts you for your **Entra ID Tenant ID** and a **display name** for the blueprint
2. Connects to Microsoft Graph (via device code flow — you'll need to open a browser and enter a code)
3. Creates an **Agent Identity Blueprint** app registration
4. Configures an `access_agent` OAuth2 scope on the app
5. Creates the **Agent Identity Blueprint service principal**
6. Saves the blueprint's `appId` to the azd environment

### Provision

Bicep templates deploy the following Azure resources:

- **Log Analytics workspace** — for container app logs
- **User-assigned managed identity** — used by the container app to authenticate to Graph
- **Azure Container Registry** — hosts the API container image
- **Container Apps Environment + Container App** — runs the API

### Post-provision (automatic)

The `postprovision` hook:

1. Connects to Microsoft Graph (device code flow — enter a code again)
2. Creates a **federated identity credential** on the blueprint app, linking the managed identity to the app registration
3. Registers a **test client app** (public client with device code flow enabled)
4. Grants **admin consent** for the `access_agent` delegated permission
5. Saves the test client's `appId` to the azd environment

### Deploy

The API is built as a Docker image, pushed to the Container Registry, and deployed to the Container App.

## Step 5: Test the API

Run the test client:

```bash
pwsh ./test-client.ps1
```

The script will:

1. Read configuration from the azd environment
2. Acquire a token via **device code flow** (open the link and enter the code shown)
3. **Create** an agent identity by calling `POST /create-agent-identity`
4. Prompt you whether to **delete** the agent identity
5. If confirmed, call `DELETE /agent-identity/{id}` to remove it

Expected output on success:

```
=== Agent Identity API Test Client ===

  Tenant:      <your-tenant-id>
  Blueprint:   <blueprint-app-id>
  Test Client: <test-client-app-id>
  API URL:     https://<your-container-app>.azurecontainerapps.io
  Scope:       api://<blueprint-app-id>/access_agent

Acquiring token (device code flow)...
Token acquired for: user@example.com

Creating agent identity 'test-agent-20260227-120000'...
  Created agent identity: <agent-identity-id>

Do you want to delete agent identity <agent-identity-id>? (y/N): y
Waiting a few seconds for Graph API replication...
Deleting agent identity <agent-identity-id>...
  Deleted agent identity: <agent-identity-id>

=== Test complete ===
```

## API Endpoints

### Create an Agent Identity

```http
POST /create-agent-identity
Authorization: Bearer <access-token>
Content-Type: application/json

{
  "displayName": "my-agent"  // optional — defaults to the caller's name
}
```

**Response:**

```json
{
  "agentIdentityId": "<new-agent-identity-id>"
}
```

The sponsor is automatically set to the authenticated caller (derived from the `oid` claim in the token).

### Delete an Agent Identity

```http
DELETE /agent-identity/{id}
Authorization: Bearer <access-token>
```

**Response:**

```json
{
  "deleted": "<agent-identity-id>"
}
```

## Clean up

To remove all Azure resources:

```bash
azd down --force --purge
```

> **Note:** This removes only the Azure infrastructure. The Entra ID app registrations (blueprint and test client) are not deleted by `azd down`. You can remove them manually from the [Azure Portal > App registrations](https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps).

## Re-running `azd up`

If you need to re-provision from scratch, clear the saved blueprint app ID first so the pre-provision hook creates a new one:

```bash
azd env set AGENT_BLUEPRINT_APP_ID ""
azd env set TEST_CLIENT_APP_ID ""
azd up
```

## Project structure

```
├── azure.yaml                  # azd project configuration
├── setup.ps1                   # Creates the Agent Identity Blueprint in Entra ID
├── test-client.ps1             # Test script for the deployed API
├── hooks/
│   ├── preprovision.ps1        # Pre-provision hook (runs setup.ps1)
│   └── postprovision.ps1       # Post-provision hook (federated cred + test client)
├── infra/
│   ├── main.bicep              # Main Bicep template
│   ├── main.bicepparam         # Bicep parameters
│   └── modules/
│       ├── container-app.bicep
│       ├── container-registry.bicep
│       ├── log-analytics.bicep
│       └── managed-identity.bicep
└── src/
    └── AgentIdentityApi/
        ├── Program.cs              # API endpoints (create + delete)
        ├── Dockerfile              # Container build definition
        ├── appsettings.json        # Configuration (populated at deploy time)
        └── Models/
            ├── AgentIdentity.cs
            └── CreateAgentIdentityRequest.cs
```
