using System.Text.Json.Serialization;

namespace AgentIdentityApi.Models;

public class AgentIdentity
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "#Microsoft.Graph.AgentIdentity";

    [JsonPropertyName("displayName")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DisplayName { get; set; }

    [JsonPropertyName("agentIdentityBlueprintId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AgentIdentityBlueprintId { get; set; }

    [JsonPropertyName("id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Id { get; set; }

    [JsonPropertyName("sponsors@odata.bind")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string[]? SponsorsOdataBind { get; set; }

    [JsonPropertyName("owners@odata.bind")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string[]? OwnersOdataBind { get; set; }
}
