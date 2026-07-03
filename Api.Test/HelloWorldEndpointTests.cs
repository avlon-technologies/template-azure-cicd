using Microsoft.AspNetCore.Mvc.Testing;

namespace Api.Test;

public class HelloWorldEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HelloWorldEndpointTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task Root_ReturnsHelloWorld()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task V1Hello_ReturnsHelloWorld()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/v1/hello");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task OpenApiSpec_IsServed()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/openapi/v1.json");

        response.EnsureSuccessStatusCode();
        var spec = await response.Content.ReadAsStringAsync();
        // Version token substituted to a literal path, doc stamped with build info.
        Assert.Contains("/v1/hello", spec);
        Assert.Contains("cicd-demo API", spec);
        Assert.Contains("Deployed build:", spec);
    }

    [Fact]
    public async Task SwaggerUi_IsServed()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/swagger/index.html");

        response.EnsureSuccessStatusCode();
        Assert.Contains("swagger-ui", await response.Content.ReadAsStringAsync());
    }
}
