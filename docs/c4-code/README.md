# C4 — Code

The deepest zoom: how the key components are actually implemented. C4 keeps this level deliberately sparse — only the code worth a diagram gets one. This document walks the parts of the implementation where a design decision is embedded *in the code itself* and points at the source with `file:line` references.

← [C3 — Components](../c3-components/README.md) · [Architecture overview](../ARCHITECTURE.md)

> These are concrete realizations of the specification. The file paths reflect the current .NET implementation; the *shape* (self-identifying build, versioned routing, verified deploy, secretless auth) is what the spec requires — a different stack would implement the same shapes elsewhere.

---

## Code map

| Element | File | Realizes (C3 component) |
|---|---|---|
| Application composition root | `Api/Program.cs` | The entire API application |
| Test-visibility shim | `Api/Program.cs:110` | app↔test contract |
| Endpoint contract tests | `Api.Test/HelloWorldEndpointTests.cs` | verification of the API surface |
| Build labelling | `.github/workflows/_build.yml:70-76,100-112` | Build & Test |
| Smoke-test + shift-back | `.github/workflows/_deploy.yml:237-321` | Deploy verification contract |
| Immutable tagging | `.github/workflows/_deploy.yml:341-375` | Artifact gating / audit trail |
| Secretless login | `.github/workflows/_deploy.yml:100-105` | Deploy identity |

---

## 1. The composition root — `Api/Program.cs`

The whole application is one file: a minimal-API startup that wires services, then maps endpoints. Reading it top to bottom traces the C3 components in order.

### 1.1 Build Info Reader — the self-identifying build

```csharp
// Api/Program.cs:12-15 (helpers in Api/BuildInfo.cs)
var (buildLabel, commitSha) = BuildInfo.Split(assembly
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
    .InformationalVersion);
```

The .NET SDK appends the commit SHA to `InformationalVersion` as SemVer build metadata (`<label>+<sha>`). Splitting on `+` recovers the two halves: `buildLabel` becomes the displayed/asserted version, `commitSha` becomes a linked commit reference in the description. **This is the source end of the app↔pipeline contract** — the value the smoke test later asserts against.

### 1.2 API Versioning

```csharp
// Api/Program.cs:20-36
builder.Services.AddApiVersioning(options => {
    options.DefaultApiVersion = new ApiVersion(1);
    options.ApiVersionReader = ApiVersionReader.Combine(
        new UrlSegmentApiVersionReader(),
        new HeaderApiVersionReader("api-version"));
})
```

Version is read from the URL segment (`/v1/…`) *or* an `api-version` header. `GroupNameFormat = "'v'V"` (`:34`) makes the OpenAPI group name (`v1`) line up with the default document name, and `SubstituteApiVersionInUrl` expands the `{version:apiVersion}` route token to a literal path in the spec — which is why the smoke test can grep for the literal `/v1/hello`.

### 1.3 OpenAPI Document Provider — making the build observable

```csharp
// Api/Program.cs:40-50
builder.Services.AddOpenApi(options => {
    options.AddDocumentTransformer((document, context, ct) => {
        document.Info.Title = "cicd-demo API";
        document.Info.Version = buildLabel;                    // ← asserted by the pipeline
        document.Info.Description =
            $"Deployed build: **{buildLabel}**{commitNote} — environment: **{builder.Environment.EnvironmentName}**";
        return Task.CompletedTask;
    });
});
```

`document.Info.Version = buildLabel` is the **sink end of the contract**: the deploy job reads exactly this via `jq -r '.info.version'`. The environment name and commit link make the running build fully identifiable to a human at `/swagger`.

### 1.4 Endpoints and probes

```csharp
// Api/Program.cs:55-86
app.MapGet("/", () => "Hello World!").ExcludeFromDescription();      // unversioned greeting
app.MapHealthChecks("/healthz").ExcludeFromDescription();            // liveness probe (gateway target)
var api = app.MapGroup("/v{version:apiVersion}").WithApiVersionSet(apiVersions);
api.MapGet("/hello", () => "Hello World!").MapToApiVersion(new ApiVersion(1));  // smoke-test target
app.MapOpenApi();          // /openapi/v1.json
app.UseSwaggerUI(...);     // /swagger
```

`/healthz` is deliberately decoupled from the greeting (C3): the gateway probe must not depend on business responses, and dependency checks (Key Vault, etc.) can be registered on `AddHealthChecks()` at `:38` to surface as Degraded/Unhealthy.

### 1.5 The test-visibility shim — don't delete this

```csharp
// Api/Program.cs:110
public partial class Program { }
```

Minimal-API programs have an implicit, internal entry point. This partial declaration makes `Program` visible so the test project's `WebApplicationFactory<Program>` can boot the *real* app in-process. Removing it breaks every integration test.

---

## 2. Endpoint contract tests — `Api.Test/HelloWorldEndpointTests.cs`

The tests boot the real app via `WebApplicationFactory<Program>` and exercise the HTTP surface — the same surface the deploy smoke test hits, verified before the artifact is ever published:

```csharp
// Api.Test/HelloWorldEndpointTests.cs — one assertion per surface element
Root_ReturnsHelloWorld        → GET /               == "Hello World!"
Healthz_ReportsHealthy        → GET /healthz        == "Healthy"
V1Hello_ReturnsHelloWorld     → GET /v1/hello       == "Hello World!"
OpenApiSpec_IsServed          → GET /openapi/v1.json contains /v1/hello, title, "Deployed build:"
SwaggerUi_IsServed            → GET /swagger/index.html contains "swagger-ui"
```

The OpenAPI test asserts the *shape* of the stamped document (`:56-59`), so a regression in the Build Info / OpenAPI wiring fails the build rather than surfacing only after deploy.

---

## 3. Build labelling — `.github/workflows/_build.yml`

The label is resolved once and stamped into the assembly **at build time** (publish runs `--no-build`, so a later stamp would be too late):

```yaml
# _build.yml:70-76 — resolve the label (explicit input, else date-based)
if [ -n "$INPUT_VERSION" ]; then echo "value=$INPUT_VERSION" >> "$GITHUB_OUTPUT"
else echo "value=$(date +'%Y%m%d').$RUN_NUMBER" >> "$GITHUB_OUTPUT"; fi

# _build.yml:100-112 — compile it into InformationalVersion
dotnet build ... /p:InformationalVersion="$BUILD_LABEL"
```

This is the origin of the value that flows: **build label → `InformationalVersion` → `document.Info.Version` → smoke-test assertion → git tag.** Inputs are passed via `env:` and never interpolated into the shell script (injection-safe).

---

## 4. Deploy verification — `.github/workflows/_deploy.yml`

### 4.1 Secretless login

```yaml
# _deploy.yml:100-105
- uses: azure/login@... 
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}      # per-environment, from the env's variables
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

No secret appears anywhere. The job's `environment: ${{ inputs.environment }}` (`:91`) sets the OIDC token's `sub` claim, which Entra ID matches against a per-environment federated credential. Full mechanism: [`workload-identity-federation.md`](../workload-identity-federation.md).

### 4.2 The smoke test — the deploy verification contract in code

```bash
# _deploy.yml:242-265 (staged revision) and 285-306 (post-deploy) — same contract
for i in $(seq 1 15); do
  BODY=$(curl -fsS --max-time 30 "$URL/v1/hello" || true)
  if [ "$BODY" = "Hello World!" ]; then
    DEPLOYED=$(curl -fsS --max-time 30 "$URL/openapi/v1.json" | jq -r '.info.version // empty')
    if [ "$DEPLOYED" = "$EXPECTED" ] || [[ "$DEPLOYED" == "$EXPECTED"-* ]]; then
      exit 0        # healthy: right answer AND right build
    fi
  fi
  sleep 10
done
exit 1              # timed out → fail the deploy
```

`[[ "$DEPLOYED" == "$EXPECTED"-* ]]` accepts a pre-release of the expected label — a promoted image keeps its candidate stamp (e.g. prod expects `1.6.0`, the byte-identical stg-tested image reports `1.6.0-build.187`), which is *correct* and must pass. A mismatch is retried (warm-up, and scale-to-zero cold starts), not failed immediately.

### 4.3 Blue/green auto-shift-back

```yaml
# _deploy.yml:308-321
- name: Shift traffic back after failed post-shift smoke test
  if: ${{ failure() && steps.shift.outcome == 'success' }}
  run: az containerapp ingress traffic set ... --revision-weight "$PREVIOUS=100"
```

The guard `steps.shift.outcome == 'success'` is load-bearing: a *pre*-shift failure (bad image caught on the zero-traffic staged revision) must **not** touch traffic, and a single-revision deploy has nothing to shift back to. Recovery is automatic — the previous prod revision takes traffic again without a human.

### 4.4 Immutable deployment tags

```javascript
// _deploy.yml:341-375 (github-script) — create-or-verify, never move
try {
  await github.rest.git.createRef({ ref: `refs/tags/build/<env>/<label>`, sha });
} catch (err) {
  if (err.status !== 422) throw err;                 // 422 = tag already exists
  const existing = await github.rest.git.getRef(...);
  if (existing.data.object.sha === sha) core.info('already correct — no-op');
  else core.setFailed('tags are immutable — use a new label');
}
```

The tag is written on the commit the artifact was **built from** (`SOURCE_SHA`, the release-branch head on the promotion path — not the merge commit). A `build/stg/*` tag is the promotion gate's proof of a green staging deploy; reusing a label for different code fails the deploy rather than silently rewriting history.

---

## Key decisions at this level

- **One value, threaded through every layer.** The build label is chosen in shell (`_build.yml`), compiled into the binary (`InformationalVersion`), re-emitted over HTTP (`Program.cs`), asserted by the deploy (`_deploy.yml`), and frozen as an immutable git tag. The code at each hop preserves that identity exactly.
- **The contract is enforced by real HTTP, not mocks.** Integration tests and the deploy smoke test hit the same endpoints the same way, so "passes CI" and "works when deployed" test the same surface.
- **Security properties live in small, load-bearing lines.** No stored secret (`vars.*` + `environment:`), no privilege to move a tag (create-or-verify), no shift-back on a pre-shift failure (the `steps.shift.outcome` guard). Each is a few lines carrying an architectural guarantee — worth reading carefully before editing.
