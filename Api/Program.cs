var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// Root stays unversioned: the App Gateway health probe targets "/".
app.MapGet("/", () => "Hello World!");

// API endpoints are versioned by URL segment; breaking changes go in /v2
// while /v1 keeps serving existing clients from the same deployment.
var v1 = app.MapGroup("/v1");
v1.MapGet("/hello", () => "Hello World!");

app.Run();

public partial class Program { }
