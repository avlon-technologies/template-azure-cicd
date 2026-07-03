using System.Reflection;
using Asp.Versioning;

var builder = WebApplication.CreateBuilder(args);

// The CI build stamps its build label (e.g. 1.2.0, 1.2.0-rc.1, 20260703.5)
// into InformationalVersion; the SDK appends the commit SHA as SemVer build
// metadata ("+<sha>"). Split them: the label is the display version, the SHA
// (shortened, linked) goes in the description.
var informationalVersion = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
    .InformationalVersion ?? "unknown";
var labelAndSha = informationalVersion.Split('+', 2);
var buildLabel = labelAndSha[0];
var commitSha = labelAndSha.Length > 1 ? labelAndSha[1] : null;
var commitNote = commitSha is null
    ? ""
    : $" — commit: [`{commitSha[..Math.Min(8, commitSha.Length)]}`](https://github.com/pixelbits-mk/cicd-demo/commit/{commitSha})";

builder.Services
    .AddApiVersioning(options =>
    {
        options.DefaultApiVersion = new ApiVersion(1);
        options.ReportApiVersions = true;
    })
    .AddApiExplorer(options =>
    {
        // Group name "v1" matches the default OpenAPI document name, and the
        // {version:apiVersion} route token is expanded to the literal segment.
        options.GroupNameFormat = "'v'V";
        options.SubstituteApiVersionInUrl = true;
    });

builder.Services.AddOpenApi(options =>
{
    options.AddDocumentTransformer((document, context, cancellationToken) =>
    {
        document.Info.Title = "cicd-demo API";
        document.Info.Version = buildLabel;
        document.Info.Description =
            $"Deployed build: **{buildLabel}**{commitNote} — environment: **{builder.Environment.EnvironmentName}**";
        return Task.CompletedTask;
    });
});

var app = builder.Build();

// Root stays unversioned: the App Gateway health probe targets "/".
app.MapGet("/", () => "Hello World!").ExcludeFromDescription();

// API endpoints are versioned by URL segment; breaking changes are published
// as a new version in this set while old versions keep serving from the same
// deployment.
var apiVersions = app.NewApiVersionSet()
    .HasApiVersion(new ApiVersion(1))
    .ReportApiVersions()
    .Build();

var api = app.MapGroup("/v{version:apiVersion}")
    .WithApiVersionSet(apiVersions);

// hello world endpoint
api.MapGet("/hello", () => "Hello World!")
    .WithName("HelloWorld")
    .WithSummary("Returns the hello-world greeting.")
    .MapToApiVersion(new ApiVersion(1));

// OpenAPI spec + Swagger UI are deliberately enabled in every environment,
// including prod (this is a demo API with no sensitive surface).
app.MapOpenApi(); // serves /openapi/v1.json
app.UseSwaggerUI(options =>
{
    options.SwaggerEndpoint("/openapi/v1.json", "cicd-demo v1");
}); // serves /swagger

app.Run();

public partial class Program { }
