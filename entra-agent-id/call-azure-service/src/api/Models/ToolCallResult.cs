namespace ChatAgentApi.Models;

public class ToolCallResult
{
    public string Tool { get; set; } = string.Empty;
    public string? SessionId { get; set; }
    public string? Query { get; set; }
}
