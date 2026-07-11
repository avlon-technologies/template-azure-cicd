# Customizing the Template

Everything you need to rename, reconfigure, or rethink when adapting this template to your own project. Work top to bottom: application, workflows, Azure, GitHub, docs.

The pipeline's one hard contract with the application is worth understanding first — see [the smoke-test contract](#3-the-smoke-test-contract) before swapping in your own app.

## 1. Application code and solution

| What | Where | Change to |
|---|---|---|
| Solution name | `cicd-demo.sln` | Your solution. Also update the `solution` input default in `_build.yml` if you rename it |
| Project names/paths | `Api/`, `Api.Test/` | Your projects. The test and publish paths are **hardcoded** in `_build.yml` (`dotnet test Api.Test/Api.Test.csproj`, `dotnet publish Api/Api.csproj`) — update both steps |
| Target framework | `Directory.Build.props` (`net10.0`) and `dotnet-version: '10.x'` in `_build.yml` | Your .NET version — keep the two in sync, and match the App Service runtime stack |
| Commit link in Swagger | `Api/Program.cs` (`commitNote`) | Points at `https://github.com/pixelbits-mk/cicd-demo/commit/…` — a **stale repo URL**; change it to your repository |
| OpenAPI title | `Api/Program.cs` (`document.Info.Title = "cicd-demo API"`) | Your API's name |
| Test expectations | `Api.Test/HelloWorldEndpointTests.cs` | Tests assert the sample endpoints — replace alongside the app |
| `public partial class Program { }` | End of `Api/Program.cs` | **Keep it** (adapted to your entry point). It makes the entry point visible to `WebApplicationFactory<Program>` — removing it breaks the integration tests |

## 2. Workflow values

| What | Where | Notes |
|---|---|---|
| Resource-group name pattern | `_deploy.yml`, slot-swap and swap-back steps: `--resource-group ${{ inputs.environment }}-demo-helloworld-rg` (two occurrences) | Replace `demo-helloworld` with your project name, or parameterize. Only exercised when `slot-swap: true` (prod), but keep it consistent everywhere |
| Smoke-test hostnames | `_deploy.yml`: `https://${{ vars.WEBAPP_NAME }}.azurewebsites.net` and `…-staging.azurewebsites.net` | Assumes default App Service hostnames. Using a custom domain, a different slot name, or private networking? Update these URLs — and remember GitHub-hosted runners must be able to reach them |
| Slot name | `_deploy.yml` (`slot-name: staging`, plus the swap/swap-back commands and the `-staging` hostname) | `staging` is assumed throughout; rename in all places or keep it |
| Artifact name prefix | `webapp-publish` / `webapp-<sha>` in `_build.yml` defaults, `on-release.yml`, `on-main.yml`, `_hotfix-support.yml` | Cosmetic; safe to keep |
| Branch names | Workflow `on.push.branches` triggers, `on-pr.yml` guard, `on-main.yml` version regex (`release|hotfix|support`) | Only if your branch model differs. The version-detection regex and the ruleset configuration must stay in agreement with the triggers |
| Concurrency groups | `deploy-dev` / `deploy-stg` / `deploy-prod` in the entry workflows | Keep — they serialize deploys per environment |

## 3. The smoke-test contract

Every deploy is verified by two assertions in `_deploy.yml` (both the slot and post-deploy smoke tests):

1. `GET /v1/hello` returns exactly `Hello World!`
2. `GET /openapi/v1.json` has `.info.version` equal to the deployed build label (or a pre-release of it — promoted binaries keep their rc stamp)

When you replace the sample app, either:

- **Keep the contract shape (recommended):** expose a cheap health/greeting endpoint and an OpenAPI document whose `info.version` reflects `InformationalVersion` — the wiring to copy is in `Api/Program.cs` (read the assembly attribute, split on `+`, stamp the OpenAPI document). This preserves the pipeline's strongest guarantee: a deploy only reports success when the *right build* is serving.
- **Or edit both smoke-test steps** in `_deploy.yml` to assert whatever your app can answer. Don't delete the version assertion casually — without it, a swap that silently didn't take effect, or a wrong-artifact deploy, reports green.

Also note: Swagger UI and the OpenAPI document are enabled in **all environments including prod** (`Api/Program.cs`) because this sample has no sensitive surface. For a real API, consider restricting them — but the smoke test reads `/openapi/v1.json`, so if you lock the spec down, adjust the version assertion too.

## 4. Azure resources and identities

| What | Default | Notes |
|---|---|---|
| Resource groups | `<env>-demo-helloworld-rg` | Your naming — must match the pattern in `_deploy.yml` (section 2) |
| App Services | `<env>-demo-helloworld-api` | Names live only in each GitHub environment's `WEBAPP_NAME` variable — no code change needed |
| App registrations | `demo-helloworld-github-deploy-<env>` | Any name; referenced only via the `AZURE_CLIENT_ID` environment variables |
| Federated credential subjects | `repo:<owner>/<repo>:environment:<env>` | Must reference **your** repository and match the GitHub environment names exactly |
| RBAC | Website Contributor per environment resource group | Widen only deliberately — per-environment scoping is the blast-radius boundary |
| Plan tiers | B1 (dev/stg), P0v3 + slots (prod) | Anything works for dev/stg; prod needs slot support for blue/green |

If you rename the GitHub environments (`dev` / `stg` / `prod`), you must update them everywhere at once: the entry workflows' `environment:` inputs, the GitHub environment names, the federated credential subjects, and the resource-group pattern in `_deploy.yml`.

## 5. GitHub configuration

Covered step-by-step in [getting-started.md](getting-started.md#step-4--configure-github). When adapting, re-check:

- Environment variables (`AZURE_CLIENT_ID`, `WEBAPP_NAME`) point at *your* identities and apps
- Repo variables `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` point at *your* tenant/subscription
- Rulesets name the same required checks (`build / Build & Test`, `Guard main source branch`) — if you rename the `_build.yml` job or the guard job, the ruleset check names must follow
- Version labels are restricted to letters, digits, `.` and `-` (they become artifact names and git tags) — keep that in mind if you script label generation

## 6. Documentation

After adapting, sweep the docs for values that describe the reference deployment: app/resource names in the [operations manual](operations-manual.md) environment table, the repository name in [workload-identity-federation.md](workload-identity-federation.md) examples, badge URLs and clone commands in the root [README](../README.md), and `CLAUDE.md` if you use AI-assisted tooling.

## Out of scope for this repo

The reference deployment's infrastructure (App Services, VNets, Key Vaults, shared Application Gateway, deploy identities) is provisioned by Terraform in a **separate infrastructure repository** — this repo contains no IaC. The pipeline only requires the resources listed in [getting-started — Step 2](getting-started.md#step-2--provision-azure-resources); provision them however your team prefers.
