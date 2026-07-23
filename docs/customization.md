# Customizing the Template

Everything you need to rename, reconfigure, or rethink when adapting this template to your own project. Work top to bottom: application, workflows, Azure, GitHub, docs.

The pipeline's one hard contract with the application is worth understanding first — see [the smoke-test contract](#3-the-smoke-test-contract) before swapping in your own app.

## 1. Application code and solution

| What | Where | Change to |
|---|---|---|
| Solution name | `cicd-demo.sln` | Your solution. Also update the `solution` input default in `_build.yml` if you rename it |
| Project names/paths | `Api/`, `Api.Test/` | Your projects. The test and publish paths are **hardcoded** in `_build.yml` (`dotnet test Api.Test/Api.Test.csproj`, `dotnet publish Api/Api.csproj`) — update both steps |
| Target framework | `Directory.Build.props` (`net10.0`) and `dotnet-version: '10.x'` in `_build.yml` | Your .NET version — keep the two in sync, and match the Dockerfile base image |
| Commit link in Swagger | `Api/Program.cs` (`commitNote`) | Nothing to change — CI stamps the repository URL into assembly metadata (`/p:RepositoryUrl` in `_build.yml` → `AssemblyMetadata` in `Api.csproj`), so the link follows your repo automatically; local builds show the SHA unlinked |
| OpenAPI title | `Api/Program.cs` (`document.Info.Title = "cicd-demo API"`) | Your API's name |
| Test expectations | `Api.Test/HelloWorldEndpointTests.cs` | Tests assert the sample endpoints — replace alongside the app |
| `public partial class Program { }` | End of `Api/Program.cs` | **Keep it** (adapted to your entry point). It makes the entry point visible to `WebApplicationFactory<Program>` — removing it breaks the integration tests |

## 2. Workflow values

| What | Where | Notes |
|---|---|---|
| Resource-group / app names | Each GitHub environment's `RESOURCE_GROUP` and `CONTAINERAPP_NAME` variables — read by `_image.yml`/`_deploy.yml` | No workflow edit needed; set the variables per environment |
| Image repository | Set the **required** `IMAGE_REPOSITORY` repo variable; the entry workflows thread it into `_image.yml`/`_deploy.yml`'s `image-repository` input, which the build, digest-marker, attestation-subject, deploy-pin, and verify steps all key off. There is **no default** — an unset/empty variable fails the build and the deploy fast (guards in "Build and push image" / "Resolve deployment target") rather than silently shipping the wrong repository. Registry from the `ACR_NAME` repo variable; `Dockerfile` at the repo root (runtime-only, port 8080 must match the app's ingress target port) | No workflow edit needed — set one variable (required). Keep the Dockerfile runtime-only (`COPY publish/`) — a source-building Dockerfile would break the tested-bytes guarantee |
| Smoke-test URLs | `_deploy.yml` queries the Container App FQDN at deploy time; the post-deploy test prefers the environment's `GATEWAY_URL` variable when set (gateway-only ingress) | Remember the **self-hosted deploy runner** must be able to reach whichever surface is tested |
| Deploy runner | `_deploy.yml` (`runs-on: [self-hosted]`) | Deploy jobs need a registered self-hosted runner with `az`, `gh`, `curl`, `jq` ([setup](getting-started.md#self-hosted-deploy-runner)). If your apps' ingress is publicly reachable and you don't use the IP-allowlist model, switching back to `ubuntu-latest` is a one-line change |
| Failure notifications | `DEPLOY_ALERT_WEBHOOK` environment/repo variable, read by `_deploy.yml` | Optional — Slack/Teams-style `{"text": …}` webhook that failed deploys are pushed to. Unset = no notification |
| Prod revision mode | The prod Container App must run `Multiple` revision mode (`traffic-shift: true` in `on-main.yml` stages zero-traffic revisions and shifts traffic) | dev/stg stay `Single`; enabling traffic-shift against a Single-mode app fails |
| Artifact name prefix | `webapp-publish` / `webapp-<sha>` in `_build.yml` defaults, `on-release.yml`, `on-main.yml`, `_hotfix-support.yml` | Cosmetic; safe to keep |
| Branch names | Workflow `on.push.branches` triggers, `on-pr.yml` guard, `on-main.yml` version regex (`release|hotfix|support`) | Only if your branch model differs. The version-detection regex and the ruleset configuration must stay in agreement with the triggers |
| Trusted artifact producers | The workflow paths passed to `find_verified_artifact` in `on-main.yml`, `on-release.yml`, and `_hotfix-support.yml` (shared logic: `.github/scripts/find-verified-artifact.sh`) | **Renaming or adding an stg entry workflow must update these lists** — the provenance check refuses artifacts from unlisted workflows (prod fails loudly; stg falls back to a rebuild). Deliberately hardcoded in reviewed workflow code, never a repo variable: a mutable setting would let anyone with variables-write extend the trust boundary |
| Concurrency groups | `deploy-dev` / `deploy-stg` / `deploy-prod` in the entry workflows | Keep — they serialize deploys per environment |
| Dependency locks | `packages.lock.json` per project (from `RestorePackagesWithLockFile` in `Directory.Build.props`); CI restores `--locked-mode` | After adding or bumping a package, run `dotnet restore` and commit the updated lock files — CI fails (NU1004) if they drift. Never delete them to silence the error |
| SDK pin | `global.json` (10.0.1xx, `rollForward: latestFeature`) | Keep in step with `dotnet-version` in `_build.yml` and the Dockerfile base image |
| Build + image attestation | `_build.yml` (`attest` input, `SHA256SUMS` manifest, SBOM), `_image.yml` (provenance attestation on the image digest), and the "Verify image attestation" step in `_deploy.yml` | Every deployable build and image is attested, and **every deploy cryptographically verifies** the digest's attestation (signed by this repo's `_image.yml`) before touching the app — mutable tags are never deployed. If you fork the image workflow under a new filename, update the `--signer-workflow` path in `_deploy.yml` |
| Format / CodeQL gates | `format` job in `on-pr.yml` (`dotnet format cicd-demo.sln`); `codeql.yml` (`languages: csharp`) | Update the solution path if renamed; swap the CodeQL language for non-.NET workloads. Add both as required checks in the rulesets once they've run |

## 3. The smoke-test contract

Every deploy is verified by two assertions in `_deploy.yml` (both the staged-revision and post-deploy smoke tests):

1. `GET /v1/hello` returns exactly `Hello World!`
2. `GET /openapi/v1.json` has `.info.version` equal to the deployed build label (or a pre-release of it — promoted binaries keep their rc stamp)

When you replace the sample app, either:

- **Keep the contract shape (recommended):** expose a cheap health/greeting endpoint and an OpenAPI document whose `info.version` reflects `InformationalVersion` — the wiring to copy is in `Api/Program.cs` (read the assembly attribute, split on `+`, stamp the OpenAPI document). This preserves the pipeline's strongest guarantee: a deploy only reports success when the *right build* is serving.
- **Or edit both smoke-test steps** in `_deploy.yml` to assert whatever your app can answer. Don't delete the version assertion casually — without it, a swap that silently didn't take effect, or a wrong-artifact deploy, reports green.

Also note: Swagger UI and the OpenAPI document are enabled in **all environments including prod** (`Api/Program.cs`) because this sample has no sensitive surface. For a real API, consider restricting them — but the smoke test reads `/openapi/v1.json`, so if you lock the spec down, adjust the version assertion too.

## 4. Azure resources and identities

| What | Default | Notes |
|---|---|---|
| Resource groups | `rg-cicd-demo-<env>-cc` | Names live only in each GitHub environment's `RESOURCE_GROUP` variable — no code change needed |
| Container Apps | `ca-cicd-demo-api-<env>-cc` (in environment `cae-cicd-demo-<env>-cc`) | Names live only in each GitHub environment's `CONTAINERAPP_NAME` variable — no code change needed |
| Container registry | `acrplatformsharedcc` (shared) | Name lives only in the `ACR_NAME` repo variable; deploy identities need Tasks Contributor + AcrPull on it, apps need AcrPull |
| Managed identities | `mi-github-cicd-demo-<env>-cc` | Any name; referenced only via the `AZURE_CLIENT_ID` environment variables |
| Federated credential subjects | `repo:<owner>/<repo>:environment:<env>` | Must reference **your** repository and match the GitHub environment names exactly |
| RBAC | Website Contributor per environment resource group | Widen only deliberately — per-environment scoping is the blast-radius boundary |
| Compute | Consumption Container Apps, scale-to-zero (`min_replicas = 0`), 0.25 vCPU / 0.5 Gi | Raise `min_replicas` per environment if cold starts hurt; prod needs `Multiple` revision mode for blue/green |

If you rename the GitHub environments (`dev` / `stg` / `prod`), you must update them everywhere at once: the entry workflows' `environment:` inputs, the GitHub environment names, the federated credential subjects, and each environment's variables (`AZURE_CLIENT_ID`, `CONTAINERAPP_NAME`, `RESOURCE_GROUP`).

## 5. GitHub configuration

Covered step-by-step in [getting-started.md](getting-started.md#step-4--configure-github). When adapting, re-check:

- Environment variables (`AZURE_CLIENT_ID`, `CONTAINERAPP_NAME`, `RESOURCE_GROUP`) point at *your* identities, apps, and resource groups; the `ACR_NAME` repo variable points at *your* registry
- Repo variables `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` point at *your* tenant/subscription
- Rulesets name the same required checks (`build / Build & Test`, `Guard main source branch`) — if you rename the `_build.yml` job or the guard job, the ruleset check names must follow
- Version labels are restricted to letters, digits, `.` and `-` (they become artifact names and git tags) — keep that in mind if you script label generation
- Release, hotfix, and support branch versions must be exactly `X.Y.Z` (e.g. `release/1.2.0`) — enforced by the PR guard and the stg pipelines because the prod pipeline parses that shape from the merge commit subject; milestone branches are exempt (they never promote to prod)

## 6. Documentation

After adapting, sweep the docs for values that describe the reference deployment: app/resource names in the [operations manual](operations-manual.md) environment table, the repository name in [workload-identity-federation.md](workload-identity-federation.md) examples, badge URLs and clone commands in the root [README](../README.md), and `CLAUDE.md` if you use AI-assisted tooling.

## Out of scope for this repo

The reference deployment's infrastructure (resource groups, App Service plans, App Services, managed identities) is provisioned by Terraform in the **platform repo `avlon-technologies/infrastructure`** (module `infra/modules/cicd-demo/`, environment roots `infra/environments/cicd-demo/{dev,stg,prod}/`) — this repo contains no IaC. The pipeline only requires the resources listed in [getting-started — Step 2](getting-started.md#step-2--provision-azure-resources); provision them however your team prefers.
