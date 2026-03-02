using ChatAgentApi.Models;
using Microsoft.Azure.Cosmos;
using Microsoft.Identity.Web;

namespace ChatAgentApi.Services;

/// <summary>
/// Manages conversation documents in Azure Cosmos DB using an agent identity credential.
/// The agent identity token is obtained via MicrosoftIdentityTokenCredential with
/// WithAgentIdentity() and RequestAppToken = true (autonomous agent pattern).
/// </summary>
public class ConversationService
{
    private readonly MicrosoftIdentityTokenCredential _credential;
    private readonly IConfiguration _config;
    private readonly ILogger<ConversationService> _logger;

    private readonly string _databaseName;
    private readonly string _containerName;

    public ConversationService(
        MicrosoftIdentityTokenCredential credential,
        IConfiguration config,
        ILogger<ConversationService> logger)
    {
        _credential = credential;
        _config = config;
        _logger = logger;
        _databaseName = config["Cosmos:DatabaseName"] ?? "chat-db";
        _containerName = config["Cosmos:ContainerName"] ?? "conversations";
    }

    /// <summary>
    /// Creates a CosmosClient authenticated with the agent identity credential.
    /// Each call configures the credential to use the agent identity and request an app token.
    /// </summary>
    private CosmosClient GetCosmosClient()
    {
        var agentIdentityId = _config["AgentIdentity:AgentIdentityId"]
            ?? throw new InvalidOperationException("AgentIdentity:AgentIdentityId is not configured.");

        _credential.Options.WithAgentIdentity(agentIdentityId);
        _credential.Options.RequestAppToken = true;

        var endpoint = _config["Cosmos:Endpoint"]
            ?? throw new InvalidOperationException("Cosmos:Endpoint is not configured.");

        return new CosmosClient(endpoint, _credential, new CosmosClientOptions
        {
            SerializerOptions = new CosmosSerializationOptions
            {
                PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase
            }
        });
    }

    private Container GetContainer()
    {
        var client = GetCosmosClient();
        return client.GetContainer(_databaseName, _containerName);
    }

    /// <summary>
    /// Lists all conversations for a given user, ordered by most recent first.
    /// </summary>
    public async Task<List<ConversationSummary>> ListConversationsAsync(string userId)
    {
        _logger.LogInformation("Listing conversations for user {UserId}", userId);

        var container = GetContainer();
        var query = new QueryDefinition(
            "SELECT c.sessionId, c.title, c.lastUpdated FROM c WHERE c.userId = @userId ORDER BY c.lastUpdated DESC")
            .WithParameter("@userId", userId);

        var results = new List<ConversationSummary>();
        using var feed = container.GetItemQueryIterator<ConversationSummary>(query);
        while (feed.HasMoreResults)
        {
            var response = await feed.ReadNextAsync();
            results.AddRange(response);
        }

        _logger.LogInformation("Found {Count} conversations for user {UserId}", results.Count, userId);
        return results;
    }

    /// <summary>
    /// Retrieves a specific conversation by session ID.
    /// </summary>
    public async Task<ConversationDocument?> GetConversationAsync(string sessionId)
    {
        _logger.LogInformation("Getting conversation {SessionId}", sessionId);

        var container = GetContainer();
        try
        {
            var response = await container.ReadItemAsync<ConversationDocument>(
                sessionId, new PartitionKey(sessionId));
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            _logger.LogInformation("Conversation {SessionId} not found", sessionId);
            return null;
        }
    }

    /// <summary>
    /// Saves a message to a conversation. Creates the conversation document if it doesn't exist.
    /// </summary>
    public async Task<ConversationDocument> SaveMessageAsync(
        string sessionId,
        string userId,
        string role,
        string content,
        string? title = null)
    {
        _logger.LogInformation("Saving {Role} message to conversation {SessionId}", role, sessionId);

        var container = GetContainer();

        ConversationDocument conversation;
        try
        {
            var response = await container.ReadItemAsync<ConversationDocument>(
                sessionId, new PartitionKey(sessionId));
            conversation = response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            conversation = new ConversationDocument
            {
                Id = sessionId,
                SessionId = sessionId,
                UserId = userId,
                Title = title ?? "New conversation"
            };
        }

        conversation.Messages.Add(new ConversationMessage
        {
            Role = role,
            Content = content,
            Timestamp = DateTime.UtcNow
        });
        conversation.LastUpdated = DateTime.UtcNow;

        if (conversation.Title == "New conversation" && role == "user")
        {
            conversation.Title = content.Length > 50 ? content[..50] + "..." : content;
        }

        await container.UpsertItemAsync(conversation, new PartitionKey(sessionId));

        _logger.LogInformation("Saved message to conversation {SessionId}, total messages: {Count}",
            sessionId, conversation.Messages.Count);

        return conversation;
    }

    /// <summary>
    /// Searches across all conversations for a user by keyword.
    /// </summary>
    public async Task<List<ConversationSummary>> SearchConversationsAsync(string userId, string query)
    {
        _logger.LogInformation("Searching conversations for user {UserId} with query '{Query}'", userId, query);

        var container = GetContainer();
        var queryDefinition = new QueryDefinition(
            "SELECT c.sessionId, c.title, c.lastUpdated FROM c WHERE c.userId = @userId AND (CONTAINS(LOWER(c.title), LOWER(@query)) OR EXISTS(SELECT VALUE m FROM m IN c.messages WHERE CONTAINS(LOWER(m.content), LOWER(@query)))) ORDER BY c.lastUpdated DESC")
            .WithParameter("@userId", userId)
            .WithParameter("@query", query);

        var results = new List<ConversationSummary>();
        using var feed = container.GetItemQueryIterator<ConversationSummary>(queryDefinition);
        while (feed.HasMoreResults)
        {
            var response = await feed.ReadNextAsync();
            results.AddRange(response);
        }

        _logger.LogInformation("Found {Count} conversations matching query for user {UserId}", results.Count, userId);
        return results;
    }
}
