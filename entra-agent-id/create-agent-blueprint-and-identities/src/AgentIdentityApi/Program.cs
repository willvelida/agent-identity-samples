using System.Security.Claims;
using AgentIdentityApi.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Identity.Abstractions;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.TokenCacheProviders.InMemory;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddMicrosoftIdentityWebApiAuthentication(builder.Configuration)
    .EnableTokenAcquisitionToCallDownstreamApi();
builder.Services.AddDownstreamApis(builder.Configuration.GetSection("DownstreamApis"));
builder.Services.AddInMemoryTokenCaches();
builder.Services.AddAuthorizationBuilder();

var app = builder.Build();

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();

// Create an agent identity.
// The sponsor is the authenticated caller (derived from the "oid" claim in the token).
// An optional displayName can be provided in the request body; otherwise, the caller's
// name from the token is used.
app.MapPost("/create-agent-identity", async (HttpContext httpContext, [FromBody] CreateAgentIdentityRequest? request) =>
{
    try
    {
        var config = httpContext.RequestServices.GetRequiredService<IConfiguration>();
        var blueprintId = config["AgentIdentity:BlueprintId"]
            ?? throw new InvalidOperationException("AgentIdentity:BlueprintId is not configured.");

        // Derive sponsor from the authenticated user's object ID claim
        var sponsorUserId = httpContext.User.FindFirstValue("http://schemas.microsoft.com/identity/claims/objectidentifier")
            ?? httpContext.User.FindFirstValue(ClaimTypes.NameIdentifier)
            ?? throw new InvalidOperationException("Could not determine the caller's object ID from the token.");

        // Use the display name from the request body, or fall back to the token's name claim
        var displayName = request?.DisplayName
            ?? httpContext.User.FindFirstValue("name")
            ?? httpContext.User.Identity?.Name
            ?? "My agent identity";

        // Get the service to call the downstream API
        IDownstreamApi downstreamApi = httpContext.RequestServices.GetRequiredService<IDownstreamApi>();

        // Call the downstream API with a POST request to create the agent identity
        var jsonResult = await downstreamApi.PostForAppAsync<AgentIdentity, AgentIdentity>(
            "agent-identity",
            new AgentIdentity {
                DisplayName = displayName,
                AgentIdentityBlueprintId = blueprintId,
                SponsorsOdataBind = new [] { $"https://graph.microsoft.com/v1.0/users/{sponsorUserId}" }
            }
          );
        return Results.Ok(new { agentIdentityId = jsonResult?.Id });
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message);
    }
}).RequireAuthorization();

// Delete an Agent Identity
app.MapDelete("/agent-identity/{id}", async (HttpContext httpContext, string id) =>
{
    try
    {
        // Get the service to call the downstream API (preconfigured in the appsettings.json file)
        IDownstreamApi downstreamApi = httpContext.RequestServices.GetRequiredService<IDownstreamApi>();

        // Call the downstream API with a DELETE request to remove an Agent Identity
        // Delete goes to /beta/serviceprincipals/{id} directly (no OData type cast)
        await downstreamApi.DeleteForAppAsync<string, string>(
            "agent-identity",
            null!,
            options =>
            {
                options.RelativePath = $"/beta/serviceprincipals/{id}";
            });
        return Results.Ok(new { deleted = id });
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message);
    }
}).RequireAuthorization();

app.Run();
