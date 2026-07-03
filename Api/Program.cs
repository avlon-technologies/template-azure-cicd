var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOpenApi();

var app = builder.Build();

// Root stays unversioned: the App Gateway health probe targets "/".
app.MapGet("/", () => "Hello World!").ExcludeFromDescription();

// API endpoints are versioned by URL segment; breaking changes go in /v2
// while /v1 keeps serving existing clients from the same deployment.
var v1 = app.MapGroup("/v1");
v1.MapGet("/hello", () => "Hello World!")
    .WithName("HelloWorld")
    .WithSummary("Returns the hello-world greeting.");

// OpenAPI spec + Swagger UI are deliberately enabled in every environment,
// including prod (this is a demo API with no sensitive surface).
app.MapOpenApi(); // serves /openapi/v1.json
app.UseSwaggerUI(options =>
{
    options.SwaggerEndpoint("/openapi/v1.json", "cicd-demo v1");
}); // serves /swagger

app.Run();

public partial class Program { }
