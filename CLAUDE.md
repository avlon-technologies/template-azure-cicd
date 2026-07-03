# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A CI/CD pipeline demo: a minimal .NET 10 web API (`cicd-demo.sln` — `Api` is a minimal-API project with a hello-world endpoint at `/`; `Api.Test` holds xUnit integration tests using `WebApplicationFactory`) deployed to Azure App Service via GitHub Actions. `Api/Program.cs` ends with `public partial class Program { }` to make the entry point visible to the test project — keep it when editing.

## Build and test commands (as run by CI)

```sh
dotnet restore cicd-demo.sln
dotnet build cicd-demo.sln --configuration Release --no-restore
dotnet test Api.Test/Api.Test.csproj --configuration Release --no-build --logger trx
dotnet publish Api/Api.csproj --configuration Release --no-build --output ./publish
```

Run locally: `dotnet run --project Api`

## Workflow architecture

Two reusable workflows (prefixed `_`) are composed by branch-triggered entry workflows:

- `_build.yml` — build, test, publish, upload `webapp-publish` artifact. Accepts an optional `version` input; otherwise the build label defaults to `YYYYMMDD.<run_number>`. The label is stamped into `InformationalVersion` at the *build* step (publish runs `--no-build`) and surfaces in Swagger. Outputs `build-label`.
- `_deploy.yml` — downloads the artifact, logs into Azure via OIDC (`azure-client-id` input), deploys to App Service (with `slot-swap: true`, used by prod: deploy to `staging` slot → smoke test → swap), smoke-tests `/v1/hello`, prints the URL to the run summary, and tags the commit `build/<environment>/<build-label>`. Requires a GitHub environment (`dev` | `stg` | `prod`).
- `on-pr.yml` — builds/tests PRs to `develop`/`main`; the check is required by rulesets, which also enforce PR-only merges (merge-commit-only on `main`).

Pipeline behavior also depends on repo settings outside these files: rulesets, workflow permissions (default token read-only; "Actions can create PRs" enabled for the back-merge step), and the `AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID` variables — see the "Repository settings" section of `docs/operations-manual.md`. Gotcha: jobs downstream of the promotion path's skipped `build` job need explicit `!failure() && !cancelled()` conditions (implicit `success()` fails on skipped ancestors).

Branch → environment mapping:

| Entry workflow | Trigger branches | Environment / App Service |
|---|---|---|
| `on-develop.yml` | `develop` | dev / `dev-demo-helloworld-api` |
| `on-release.yml` | `release/**`, `milestone/**` | stg / `stg-demo-helloworld-api` |
| `on-hotfix.yml` | `hotfix/**` | stg / `stg-demo-helloworld-api` |
| `on-main.yml` | `main` | prod / `prod-demo-helloworld-api` |

Release specifics (`on-release.yml`): pushes only build (deploy is gated on `workflow_dispatch`). A `prepare` job resolves the version — manual dispatch takes the `version` input; otherwise `release/X.Y.Z` becomes `X.Y.Z-build.<run_number>` and `milestone/<name>` becomes `ms-<name>.<run_number>`. Dispatched rc builds upload commit-keyed artifacts (`webapp-<sha>`, 90-day retention); when the release merges to main, `on-main.yml` **promotes** that exact artifact (build job skipped) — rebuild is only the fallback.

`call-validate-pr.yml` delegates PR title/milestone/issue-link validation to the shared `DBDHub/sna_common_workflows` repo; it needs the `APP_ID` variable and `APP_PEM` secret.

## Infrastructure

Lives in a separate repo: `../cicd-infrastructure` (see its README). Terraform provisions, per environment (`dev` | `stg` | `prod`), a resource group `<env>-demo-helloworld-rg` with its own VNet, an App Service `<env>-demo-helloworld-api` (B1 plan; P0v3 with slots for prod) (the names the deploy workflows target), and a Key Vault — plus one shared Application Gateway exposing all environments (one frontend port per env: prod :80, dev :8081, stg :8082).

## Deploy identity

CI deploys log into Azure via OIDC using one App Registration per environment (`demo-helloworld-github-deploy-<env>`), each with a federated credential for its GitHub environment and Website Contributor scoped to its own resource group only. Client IDs are passed as `azure-client-id` in the `on-*` workflows: dev `f87452ba-…`, stg `e205fdd4-…`, prod `279d0dec-…`. Deploys fail until the Terraform in `../cicd-infrastructure` has been applied for the target environment (the App Service must exist).
