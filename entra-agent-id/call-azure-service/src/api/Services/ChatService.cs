using System.ComponentModel;
using System.Text.Json;
using Azure.AI.OpenAI;
using Azure.Identity;
using ChatAgentApi.Models;
using Microsoft.Agents.AI;
using Microsoft.ApplicationInsights;
using Microsoft.Extensions.AI;

using ChatMessage = Microsoft.Extensions.AI.ChatMessage;
using ChatRole = Microsoft.Extensions.AI.ChatRole;

namespace ChatAgentApi.Services;

/// <summary>
/// Orchestrates chat interactions using the Microsoft Agent Framework with Azure OpenAI.
/// Tools are defined as regular C# methods with [Description] attributes and automatically
/// wired up via AIFunctionFactory. The framework handles the tool calling loop — no manual
/// FinishReason.ToolCalls checking needed.
///
/// Tool methods delegate to ConversationService, which uses MicrosoftIdentityTokenCredential
/// with .WithAgentIdentity() to call Cosmos DB — the core Entra Agent Identity pattern
/// this sample demonstrates.
/// </summary>
public class ChatService
{
    private readonly ConversationService _conversationService;
    private readonly IConfiguration _config;
    private readonly ILogger<ChatService> _logger;
    private readonly TelemetryClient _telemetry;

    private const string SystemPrompt =
        """
        You are a helpful AI assistant. You have access to the user's conversation history
        stored in Azure Cosmos DB. You can retrieve past conversations, list all conversations,
        and search through them. When the user asks about past discussions or wants to resume
        a previous conversation, use the available tools to look up their history.

        Always be helpful, concise, and accurate. When providing information from past
        conversations, quote or summarize the relevant parts.
        """;

    public ChatService(
        ConversationService conversationService,
        IConfiguration config,
        ILogger<ChatService> logger,
        TelemetryClient telemetry)
    {
        _conversationService = conversationService;
        _config = config;
        _logger = logger;
        _telemetry = telemetry;
    }

    /// <summary>
    /// Processes a chat message: persists it, runs the agent (which automatically handles
    /// tool calling), and returns the final response.
    /// </summary>
    public async Task<Models.ChatResponse> ChatAsync(string message, string? sessionId, string userId)
    {
        sessionId ??= Guid.NewGuid().ToString();

        _telemetry.TrackEvent("ChatRequest", new Dictionary<string, string>
        {
            { "SessionId", sessionId },
            { "AgentIdentityId", _config["AgentIdentity:AgentIdentityId"] ?? "not-configured" }
        });

        _logger.LogInformation("Processing chat for session {SessionId}, user {UserId}", sessionId, userId);

        await _conversationService.SaveMessageAsync(sessionId, userId, "user", message);

        var conversation = await _conversationService.GetConversationAsync(sessionId);
        var inputMessages = BuildInputMessages(conversation);

        var agent = CreateAgent(userId);
        var agentSession = await agent.CreateSessionAsync();
        var response = await agent.RunAsync(inputMessages, agentSession);

        var reply = response.Text
            ?? "I apologize, but I wasn't able to complete your request. Please try again.";

        var toolCalls = ExtractToolCalls(response, sessionId);

        await _conversationService.SaveMessageAsync(sessionId, userId, "assistant", reply);

        _logger.LogInformation("Chat completed for session {SessionId}", sessionId);

        return new Models.ChatResponse
        {
            Reply = reply,
            SessionId = sessionId,
            ToolCalls = toolCalls
        };
    }

    /// <summary>
    /// Creates an AIAgent backed by Azure OpenAI with conversation tools.
    /// The tools are plain C# methods — the framework converts them to function tool
    /// definitions and handles the calling loop automatically.
    /// </summary>
    private AIAgent CreateAgent(string userId)
    {
        var endpoint = _config["OpenAI:Endpoint"]
            ?? throw new InvalidOperationException("OpenAI:Endpoint is not configured.");
        var deploymentName = _config["OpenAI:DeploymentName"] ?? "gpt-4o";

        // Use the user-assigned managed identity for Azure OpenAI authentication
        var managedIdentityClientId = _config["AzureAd:ClientCredentials:0:ManagedIdentityClientId"];
        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = managedIdentityClientId
        });

        var azureClient = new AzureOpenAIClient(
            new Uri(endpoint),
            credential);

        var tools = new[]
        {
            AIFunctionFactory.Create(
                (string sessionId) => GetConversationHistoryAsync(sessionId, userId),
                nameof(GetConversationHistoryAsync),
                "Retrieve messages from a previous conversation session by its session ID."),

            AIFunctionFactory.Create(
                () => ListConversationsAsync(userId),
                nameof(ListConversationsAsync),
                "List the current user's conversation sessions with titles and dates."),

            AIFunctionFactory.Create(
                (string query) => SearchConversationsAsync(query, userId),
                nameof(SearchConversationsAsync),
                "Search across the user's past conversations for a keyword or topic.")
        };

        return azureClient
            .GetChatClient(deploymentName)
            .AsIChatClient()
            .AsAIAgent(
                instructions: SystemPrompt,
                name: "ChatAgent",
                tools: tools);
    }

    // Tool methods — called by the Agent Framework when the LLM requests a tool call.
    // Each delegates to ConversationService, which authenticates to Cosmos DB using
    // MicrosoftIdentityTokenCredential with .WithAgentIdentity().

    private async Task<string> GetConversationHistoryAsync(string sessionId, string userId)
    {
        _logger.LogInformation("Tool call: GetConversationHistory for session {SessionId}, user {UserId}", sessionId, userId);

        var conversation = await _conversationService.GetConversationAsync(sessionId);
        if (conversation == null || conversation.UserId != userId)
        {
            return JsonSerializer.Serialize(new { error = "Conversation not found", sessionId });
        }

        return JsonSerializer.Serialize(new
        {
            sessionId = conversation.SessionId,
            title = conversation.Title,
            lastUpdated = conversation.LastUpdated,
            messages = conversation.Messages.Select(m => new { m.Role, m.Content, m.Timestamp })
        });
    }

    private async Task<string> ListConversationsAsync(string userId)
    {
        _logger.LogInformation("Tool call: ListConversations for user {UserId}", userId);

        var conversations = await _conversationService.ListConversationsAsync(userId);
        return JsonSerializer.Serialize(new
        {
            conversations = conversations.Select(c => new { c.SessionId, c.Title, c.LastUpdated })
        });
    }

    private async Task<string> SearchConversationsAsync(string query, string userId)
    {
        _logger.LogInformation("Tool call: SearchConversations query '{Query}' for user {UserId}", query, userId);

        var results = await _conversationService.SearchConversationsAsync(userId, query);
        return JsonSerializer.Serialize(new
        {
            query,
            results = results.Select(c => new { c.SessionId, c.Title, c.LastUpdated })
        });
    }

    /// <summary>
    /// Builds the list of input messages from a Cosmos DB conversation document
    /// to provide conversation context to the agent.
    /// </summary>
    private static IEnumerable<ChatMessage> BuildInputMessages(ConversationDocument? conversation)
    {
        if (conversation?.Messages is not { Count: > 0 } existingMessages)
        {
            yield break;
        }

        // Include existing messages as context (skip the last one since we just saved it)
        foreach (var msg in existingMessages.SkipLast(1))
        {
            yield return msg.Role switch
            {
                "user" => new ChatMessage(ChatRole.User, msg.Content),
                "assistant" => new ChatMessage(ChatRole.Assistant, msg.Content),
                _ => new ChatMessage(ChatRole.User, msg.Content)
            };
        }

        // Add the latest user message
        var lastMessage = existingMessages[^1];
        if (lastMessage.Role == "user")
        {
            yield return new ChatMessage(ChatRole.User, lastMessage.Content);
        }
    }

    /// <summary>
    /// Extracts tool call information from the AgentResponse for telemetry and the API response.
    /// The Agent Framework records FunctionCallContent items in the response messages.
    /// </summary>
    private List<ToolCallResult> ExtractToolCalls(AgentResponse response, string sessionId)
    {
        var toolCalls = new List<ToolCallResult>();
        var agentIdentityId = _config["AgentIdentity:AgentIdentityId"] ?? "not-configured";

        foreach (var msg in response.Messages)
        {
            foreach (var content in msg.Contents.OfType<FunctionCallContent>())
            {
                _telemetry.TrackEvent("ToolCall", new Dictionary<string, string>
                {
                    { "ToolName", content.Name },
                    { "SessionId", sessionId },
                    { "AgentIdentityId", agentIdentityId }
                });

                toolCalls.Add(new ToolCallResult
                {
                    Tool = content.Name,
                    SessionId = content.Arguments?.TryGetValue("sessionId", out var sid) == true
                        ? sid?.ToString() : null,
                    Query = content.Arguments?.TryGetValue("query", out var q) == true
                        ? q?.ToString() : null
                });
            }
        }

        return toolCalls;
    }
}
