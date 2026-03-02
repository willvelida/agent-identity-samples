using System.Security.Claims;
using ChatAgentApi.Models;
using ChatAgentApi.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.TokenCacheProviders.InMemory;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddMicrosoftIdentityAzureTokenCredential();
builder.Services.AddAgentIdentities();

builder.Services.AddSingleton<ConversationService>();
builder.Services.AddSingleton<ChatService>();
builder.Services.AddApplicationInsightsTelemetry();

builder.Services.AddCors(options =>
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins(builder.Configuration["Frontend:Url"] ?? "*")
              .AllowAnyHeader()
              .AllowAnyMethod()));

var app = builder.Build();

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

app.MapPost("/api/chat", async (ChatRequest request, ChatService chatService, HttpContext context) =>
{
    var userId = context.User.FindFirstValue("oid")
        ?? context.User.FindFirstValue(ClaimTypes.NameIdentifier)
        ?? throw new InvalidOperationException("Could not determine user ID from token.");

    var reply = await chatService.ChatAsync(request.Message, request.SessionId, userId);
    return Results.Ok(reply);
}).RequireAuthorization();

app.MapGet("/api/conversations", async (ConversationService conversationService, HttpContext context) =>
{
    var userId = context.User.FindFirstValue("oid")
        ?? context.User.FindFirstValue(ClaimTypes.NameIdentifier)
        ?? throw new InvalidOperationException("Could not determine user ID from token.");

    var conversations = await conversationService.ListConversationsAsync(userId);
    return Results.Ok(conversations);
}).RequireAuthorization();

app.MapGet("/api/conversations/{sessionId}", async (string sessionId, ConversationService conversationService, HttpContext context) =>
{
    var userId = context.User.FindFirstValue("oid")
        ?? context.User.FindFirstValue(ClaimTypes.NameIdentifier)
        ?? throw new InvalidOperationException("Could not determine user ID from token.");

    var conversation = await conversationService.GetConversationAsync(sessionId);
    if (conversation is null || conversation.UserId != userId)
        return Results.NotFound();

    return Results.Ok(conversation);
}).RequireAuthorization();

app.Run();
