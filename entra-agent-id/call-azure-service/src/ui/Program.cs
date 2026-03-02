using ChatFrontend.Components;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;

var builder = WebApplication.CreateBuilder(args);

// Configure forwarded headers so that behind a TLS-terminating reverse proxy
// (like Azure Container Apps), the app knows the original scheme was https.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

// Authentication — MSAL for Blazor Server
// Request the downstream API scope during initial sign-in so the token is cached
// immediately. Without this, Blazor Server's SignalR connection can't trigger
// incremental consent and throws IDW10502 / MsalUiRequiredException.
var initialScopes = builder.Configuration.GetSection("DownstreamApis:ChatApi:Scopes").Get<string[]>();
builder.Services.AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApp(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi(initialScopes)
    .AddInMemoryTokenCaches();

// Register the backend Chat API as a downstream API
builder.Services.AddDownstreamApi("ChatApi", builder.Configuration.GetSection("DownstreamApis:ChatApi"));

// Application Insights
builder.Services.AddApplicationInsightsTelemetry();

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Required for MicrosoftIdentityConsentAndConditionalAccessHandler in Blazor Server
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<MicrosoftIdentityConsentAndConditionalAccessHandler>();

builder.Services.AddControllersWithViews()
    .AddMicrosoftIdentityUI();

builder.Services.AddAuthorization(options =>
{
    // By default, all incoming requests will be authorized according to the default policy.
    options.FallbackPolicy = options.DefaultPolicy;
});

builder.Services.AddCascadingAuthenticationState();

var app = builder.Build();

// Must be first in the pipeline so all subsequent middleware sees the correct scheme/host.
app.UseForwardedHeaders();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

app.UseStaticFiles();
app.UseAntiforgery();
app.UseAuthentication();
app.UseAuthorization();

app.MapStaticAssets();
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();
app.MapControllers(); // For MSAL sign-in/sign-out endpoints

app.Run();
