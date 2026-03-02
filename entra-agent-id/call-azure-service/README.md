# Call Azure Service with Entra Agent Identity

This sample demonstrates how to use **Microsoft Entra Agent Identities** to give an AI agent its own discrete identity when calling Azure services. The agent authenticates to **Azure Cosmos DB** under its own identity — separate from the user and the hosting application — providing fine-grained authorization and auditable access.

The sample implements an interactive chat application powered by **Azure OpenAI** that persists conversation history in Cosmos DB. The agent uses its own identity (not the user's) to read and write data, showcasing the **autonomous agent** token pattern.

## Architecture

```
┌─────────────────────┐       ┌──────────────────┐       ┌──────────────────────────┐
│                     │       │                  │       │                          │
│   Blazor Frontend   │──────►│   Chat Agent API │──────►│   Azure OpenAI Service   │
│   (Container App)   │ HTTPS │  (Container App) │       │   (GPT-4o)               │
│                     │       │                  │       │                          │
│  • MSAL auth        │       │  • JWT validation│       └──────────────────────────┘
│  • Chat UI          │       │  • Agent ID      │
│  • App Insights     │       │    token cred    │       ┌──────────────────────────┐
│                     │       │  • Tool calling  │──────►│   Azure Cosmos DB        │
└─────────────────────┘       │  • App Insights  │ Agent │   (conversations db)     │
                              │                  │  ID   │                          │
                              └──────────────────┘       └──────────────────────────┘
                                       │
                                       │ Federated Identity Credential
                                       ▼
                              ┌──────────────────┐
                              │  User-Assigned   │
                              │  Managed Identity│
                              └──────────────────┘
                                       │
                                       ▼
                              ┌──────────────────┐
                              │   Entra ID       │
                              │  • Blueprint     │
                              │  • Agent Identity│
                              └──────────────────┘
```

### How the agent identity works

1. **User authenticates** to the Blazor frontend via MSAL (OpenID Connect).
2. **Frontend calls the API** with an access token scoped to the blueprint's `access_agent` permission.
3. **API validates the token** against the agent identity blueprint's app registration.
4. **API calls Azure OpenAI** using the managed identity for chat completions with tool definitions.
5. **When a tool is invoked** (e.g., "show my history"), the API uses `MicrosoftIdentityTokenCredential` with `.WithAgentIdentity()` and `RequestAppToken = true` to obtain a token scoped to Cosmos DB.
6. **The agent identity token** authenticates to Cosmos DB — the agent has its own Cosmos DB data-plane role assignment.

The agent acts under its **own identity** (not on behalf of the user) when calling Cosmos DB. This is the autonomous agent pattern.

## What's in this sample

| Component | Technology | Description |
|---|---|---|
| **Frontend** (`src/ui/`) | .NET 10, Blazor Server | Chat UI with MSAL authentication and conversation history |
| **API** (`src/api/`) | .NET 10, Minimal API | Chat orchestration with Azure OpenAI tool calling and Cosmos DB persistence |
| **Infrastructure** (`infra/`) | Bicep | All Azure resources: Container Apps, Cosmos DB, OpenAI, Container Registry, Managed Identity, App Insights |
| **Identity setup** (`setup.ps1`, `hooks/`) | PowerShell + Microsoft Graph | Creates the agent identity blueprint, agent identity, federated credentials, and app registrations |

### Key technologies

- [Microsoft Entra Agent Identity](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/what-is-agent-id) — discrete identity for the AI agent
- [Microsoft Identity Web](https://github.com/AzureAD/microsoft-identity-web) — `MicrosoftIdentityTokenCredential` with `.WithAgentIdentity()`
- [Microsoft Agent Framework](https://learn.microsoft.com/en-us/agent-framework/overview/) — `ChatClientAgent` with `AIFunctionFactory` for automatic tool calling
- [Azure Developer CLI (azd)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/) — one-command provisioning and deployment

## Prerequisites

- **Azure subscription** — [Create one for free](https://azure.microsoft.com/free/)
- **Microsoft Entra ID tenant** — with permissions to create app registrations and service principals
- [**.NET 10 SDK**](https://dotnet.microsoft.com/download/dotnet/10.0)
- [**Azure Developer CLI (azd)**](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [**Azure CLI**](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [**PowerShell 7+**](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) — required for the identity setup scripts
- **Microsoft Graph PowerShell modules** — installed automatically by the setup scripts

### Required Entra permissions

The setup scripts use Microsoft Graph with **delegated** permissions. You'll need to consent to:

- `AgentIdentityBlueprint.Create`
- `AgentIdentityBlueprint.AddRemoveCreds.All`
- `AgentIdentityBlueprint.ReadWrite.All`
- `AgentIdentityBlueprintPrincipal.Create`
- `Application.ReadWrite.All`
- `DelegatedPermissionGrant.ReadWrite.All`

## Getting started

### 1. Clone the repository

```bash
git clone https://github.com/Azure-Samples/agent-identity-samples.git
cd agent-identity-samples/call-azure-service
```

### 2. Log in to Azure

```bash
azd auth login
az login
```

### 3. Deploy with Azure Developer CLI

```bash
azd up
```

This single command runs the full deployment pipeline:

1. **Pre-provision hook** (`hooks/preprovision.ps1`) — Prompts for your tenant ID and blueprint name, then runs `setup.ps1` to create the agent identity blueprint in Entra ID via Microsoft Graph. You'll complete a **device code login** to authenticate with Graph.

2. **Provision** (`azd provision`) — Deploys all Azure infrastructure via Bicep:
   - User-assigned managed identity
   - Azure Container Registry
   - Azure Cosmos DB (serverless, local auth disabled)
   - Azure OpenAI (GPT-4o deployment)
   - Azure Container Apps environment
   - Container Apps for the API and frontend
   - Log Analytics + Application Insights

3. **Post-provision hook** (`hooks/postprovision.ps1`) — Completes the identity setup (requires another **device code login**):
   - Creates a federated identity credential linking the managed identity to the blueprint
   - Creates the agent identity using the blueprint's client credentials
   - Assigns the Cosmos DB Built-in Data Contributor role to the agent identity
   - Registers the frontend app registration with the `access_agent` scope
   - Re-provisions to inject the new app IDs into the container apps

4. **Deploy** (`azd deploy`) — Builds and pushes the Docker images, then deploys both container apps.

### 4. Open the application

After deployment completes, `azd` outputs the frontend URL:

```bash
azd env get-value containerAppFrontendUrl
```

Open the URL in your browser. You'll be prompted to sign in with your Entra ID account, then you can start chatting with the agent.

## Project structure

```
call-azure-service/
├── azure.yaml                    # azd project configuration
├── setup.ps1                     # Creates the agent identity blueprint in Entra ID
├── hooks/
│   ├── preprovision.ps1          # Runs setup.ps1 before infrastructure provisioning
│   └── postprovision.ps1         # Creates agent identity, FIC, frontend app, RBAC
├── infra/
│   ├── main.bicep                # Main infrastructure template
│   ├── main.bicepparam           # Parameters (reads from azd environment)
│   └── modules/
│       ├── app-insights.bicep
│       ├── container-app-api.bicep
│       ├── container-app-frontend.bicep
│       ├── container-apps-env.bicep
│       ├── container-registry.bicep
│       ├── cosmos-db.bicep
│       ├── log-analytics.bicep
│       ├── managed-identity.bicep
│       └── openai.bicep
├── src/
│   ├── api/                      # Chat Agent API
│   │   ├── Program.cs            # Minimal API with auth, CORS, endpoints
│   │   ├── Services/
│   │   │   ├── ChatService.cs    # AI orchestration with tool calling
│   │   │   └── ConversationService.cs  # Cosmos DB access via agent identity
│   │   └── Models/               # Request/response DTOs
│   └── ui/                       # Blazor Server frontend
│       ├── Program.cs            # Auth, downstream API, App Insights
│       └── Components/Pages/
│           └── Chat.razor        # Chat UI component
└── docs/
    ├── HOW-AGENT-ID-WORKS.md     # Deep dive into the identity flow
    ├── IMPLEMENTATION-PLAN.md    # Detailed design document
    └── SECURITY-REVIEW.md        # Security analysis and recommendations
```

## How the agent identity is used in code

### Configuring agent identity services (`Program.cs`)

```csharp
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddMicrosoftIdentityAzureTokenCredential();
builder.Services.AddAgentIdentities();
```

### Calling Cosmos DB with the agent identity (`ConversationService.cs`)

```csharp
private CosmosClient GetCosmosClient()
{
    var agentIdentityId = _config["AgentIdentity:AgentIdentityId"]!;
    _credential.Options.WithAgentIdentity(agentIdentityId);
    _credential.Options.RequestAppToken = true;

    return new CosmosClient(_config["Cosmos:Endpoint"]!, _credential);
}
```

The `MicrosoftIdentityTokenCredential` uses the managed identity's federated identity credential to authenticate as the blueprint, then requests an app token scoped to the agent identity. The resulting token carries the agent's identity — Cosmos DB sees the agent, not the app or user.

## API endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/chat` | Send a message and get an AI response (with tool calling) |
| `GET` | `/api/conversations` | List the authenticated user's conversation sessions |
| `GET` | `/api/conversations/{sessionId}` | Retrieve a specific conversation |

All endpoints require a bearer token with the `access_agent` scope.

### Agent tools

The AI agent has access to these tools (invoked automatically by the LLM):

| Tool | Description |
|---|---|
| `GetConversationHistoryAsync` | Retrieve messages from a previous conversation by session ID |
| `ListConversationsAsync` | List the user's conversation sessions with titles and dates |
| `SearchConversationsAsync` | Search across past conversations for a keyword or topic |

## Clean up

To delete all Azure resources created by this sample:

```bash
azd down --purge
```

The `--purge` flag ensures soft-deleted resources (like Azure OpenAI) are fully removed.

To also clean up the Entra ID app registrations (blueprint, frontend, test client), delete them manually in the [Azure portal](https://portal.azure.com) under **Entra ID > App registrations**.

## Learn more

- [What is Entra Agent ID](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/what-is-agent-id)
- [Agent identity blueprint](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/agent-blueprint)
- [Create a blueprint](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/create-blueprint?tabs=microsoft-graph-api)
- [Create agent identities](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/create-delete-agent-identities?tabs=microsoft-graph-api)
- [Call Azure services with agent identity (.NET)](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/call-api-azure-services)
- [Autonomous agent tokens](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/autonomous-agent-request-tokens)
- [Agent token claims reference](https://learn.microsoft.com/en-us/entra/agent-id/identity-platform/agent-token-claims)
- [How Agent ID works in this sample](docs/HOW-AGENT-ID-WORKS.md) — detailed walkthrough of the identity plumbing
