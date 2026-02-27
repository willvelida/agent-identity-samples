namespace AgentIdentityApi.Models;

/// <summary>
/// Optional request body for creating an agent identity.
/// The sponsor is always derived from the authenticated caller's token.
/// </summary>
public class CreateAgentIdentityRequest
{
    /// <summary>
    /// Optional display name for the agent identity.
    /// If not provided, the caller's name from the token is used.
    /// </summary>
    public string? DisplayName { get; set; }
}
