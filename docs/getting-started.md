# Getting Started

End-to-end setup: from cloning the template to a verified first deployment. Budget 1–2 hours if the Azure infrastructure doesn't exist yet.

By the end you will have:

- The template running in your own GitHub repository
- Azure App Services for `dev`, `stg`, and `prod`
- Secretless (OIDC) deploy identities, one per environment
- GitHub environments, variables, and rulesets configured
- A first automatic deploy to dev

Related reading: [workload identity federation](workload-identity-federation.md) explains the auth model this guide sets up; [customization](customization.md) lists what to rename for your own project; the [operations manual](operations-manual.md) covers day-to-day releasing once you're set up.

## Prerequisites

| Requirement | Why |
|---|---|
| Azure subscription with rights to create resource groups, App Services, user-assigned managed identities, and role assignments | Runtime + deploy identities |
| GitHub repository admin access | Environments, rulesets, and Actions settings are repo settings, not code |
| [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az`), logged in (`az login`) | Identity setup |
| [.NET 10 SDK](https://dotnet.microsoft.com/download) | Local build and test |
| [GitHub CLI](https://cli.github.com/) (`gh`) — optional | Used for dispatch commands throughout the docs; the Actions UI works too |

## Step 1 — Get the code

Create your own repository from this template (GitHub → **Use this template**, or fork/clone and push). Then:

1. Make `develop` the **default branch** (Settings → General). The pipeline's gitflow model assumes it: features merge to `develop`, releases branch from it.
2. Ensure both `develop` and `main` branches exist and Actions are enabled.

Verify the app builds locally before touching any cloud configuration:

```sh
dotnet test
dotnet run --project Api      # http://localhost:5018/swagger
```

## Step 2 — Provision Azure resources

The reference deployment provisions infrastructure with Terraform in the platform repo `avlon-technologies/infrastructure`: module `infra/modules/cicd-demo/`, applied per environment from the roots `infra/environments/cicd-demo/{dev,stg,prod}/`. If you don't have that, provision equivalents any way you prefer (Portal, Bicep, Terraform). The pipeline requires, **per environment** (`dev`, `stg`, `prod`):

| Resource | Requirement | Notes |
|---|---|---|
| Resource group | One per environment | Reference naming: `rg-cicd-demo-<env>-cc`. Its name becomes the `RESOURCE_GROUP` environment variable (used by the prod slot-swap commands in `_deploy.yml`) |
| App Service | Configured for the .NET 10 runtime | Its name becomes the `WEBAPP_NAME` environment variable. Reference naming: `app-cicd-demo-<env>-cc`, on a Linux plan `asp-cicd-demo-<env>-cc` (B1 for dev/stg) |
| **Prod only:** deployment slot named `staging` | Requires a plan tier that supports slots (reference deployment uses P0v3) | The slot name `staging` is hardcoded in `_deploy.yml` |

Two assumptions worth knowing before you deviate from the defaults:

- **Smoke tests target the default hostnames** `https://<WEBAPP_NAME>.azurewebsites.net` and `https://<WEBAPP_NAME>-staging.azurewebsites.net`. Custom domains or private-endpoint-only apps need `_deploy.yml` edits.
- The App Services must be reachable from GitHub-hosted runners (public internet) for the smoke tests to pass.

## Step 3 — Create the deploy identities

One user-assigned managed identity per environment, living in that environment's resource group, each trusted for exactly one GitHub environment and authorized for exactly one resource group. The full rationale and mechanism is in [workload-identity-federation.md](workload-identity-federation.md).

For each environment (shown for `dev` — repeat for `stg` and `prod`), replacing `<owner>/<repo>` with your repository:

```sh
# 1. User-assigned managed identity, in the environment's resource group
az identity create --name "mi-github-cicd-demo-dev-cc" --resource-group "rg-cicd-demo-dev-cc"
CLIENT_ID=$(az identity show --name "mi-github-cicd-demo-dev-cc" \
  --resource-group "rg-cicd-demo-dev-cc" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name "mi-github-cicd-demo-dev-cc" \
  --resource-group "rg-cicd-demo-dev-cc" --query principalId -o tsv)

# 2. Federated credential: trust GitHub OIDC tokens for this repo + environment
az identity federated-credential create --name "github-cicd-demo-dev" \
  --identity-name "mi-github-cicd-demo-dev-cc" --resource-group "rg-cicd-demo-dev-cc" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:<owner>/<repo>:environment:dev" \
  --audiences "api://AzureADTokenExchange"

# 3. Website Contributor, scoped to this environment's resource group only
az role assignment create --assignee "$PRINCIPAL_ID" --role "Website Contributor" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/rg-cicd-demo-dev-cc"
```

Record each managed identity's **client ID** (`$CLIENT_ID`) — you'll need it in the next step. Client IDs are identifiers, not secrets.

> The `subject` string must exactly match `repo:<owner>/<repo>:environment:<env>` — this is the security boundary. A token from a fork, another repo, or a job not running in that GitHub environment is rejected.

## Step 4 — Configure GitHub

### Environments

Settings → Environments → create `dev`, `stg`, and `prod`. In each, add **environment variables** (not secrets):

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | The client ID of that environment's managed identity (Step 3) |
| `WEBAPP_NAME` | That environment's App Service name (Step 2) |
| `RESOURCE_GROUP` | That environment's resource-group name (Step 2) — used by the slot-swap steps in `_deploy.yml` |

Optionally add **required reviewers** to the `prod` environment for a human approval gate before production deploys. (The back-merge job runs in parallel with the deploy, so `develop` gets release commits back even while prod waits for approval.)

### Repository variables

Settings → Secrets and variables → Actions → **Variables** (repository level):

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |

### Actions settings

Settings → Actions → General:

- **Workflow permissions:** *Read repository contents and packages permissions* (read-only default token — jobs elevate explicitly)
- **Allow GitHub Actions to create and approve pull requests:** enabled (required by the automated back-merge/backport PRs)

### Rulesets

Settings → Rules → Rulesets. These enforce the quality gates the pipeline assumes:

| Ruleset target | Rules |
|---|---|
| `develop` | Require a pull request; require the **build / Build & Test** status check |
| `main` | Require a pull request; require **build / Build & Test** and **Guard main source branch** checks; **allow merge commits only** (disable squash and rebase) |

Merge-commit-only on `main` is load-bearing: the prod pipeline reads the release version from the default merge commit subject (`Merge pull request #N from …/release/X.Y.Z`). A squashed or reworded merge fails the prod run by design rather than shipping an untraceable build.

> The required checks only appear in the ruleset picker after they have run at least once — open a trivial PR first if GitHub won't autocomplete them.

## Step 5 — First deploy to dev

Push (or merge a PR) to `develop`:

```sh
git checkout develop
git commit --allow-empty -m "Trigger first dev deploy"
git push
```

Watch Actions → **CI/CD — Develop → DEV**. The run should: build and test, deploy to your dev App Service, then pass the smoke test (`GET /v1/hello` returns `Hello World!` and `/openapi/v1.json` reports the build label, `YYYYMMDD.<run_number>`).

Verify: open `https://<dev-webapp-name>.azurewebsites.net/swagger` — the page shows the deployed build label, linked commit, and environment name.

If the run fails, the [troubleshooting table](operations-manual.md#troubleshooting) maps the common failure messages to causes — the most frequent first-run issues are a missing `permissions:` grant (instant `startup_failure`), an App Service that doesn't exist yet, and a federated-credential subject that doesn't exactly match the repo/environment.

## Step 6 — First release to stg and prod

Once dev works, exercise the full promotion path (full detail: [operations manual](operations-manual.md)):

```sh
# Cut a release branch
git checkout develop && git pull
git checkout -b release/0.1.0
git push -u origin release/0.1.0

# Dispatch a release candidate to staging
gh workflow run on-release.yml --ref release/0.1.0
```

The dispatch reuses the artifact the push already built (or rebuilds if it expired), deploys it to stg, smoke-tests it, and tags the commit `build/stg/0.1.0-build.<height>` (the label is derived from the commit — see the operations manual). Then promote:

```sh
gh pr create --base main --head release/0.1.0 --title "Release 0.1.0"
gh pr merge --merge      # merge commit — do NOT squash
```

The prod run locates the stg-tested artifact for the release head, deploys it to the `staging` slot, smoke-tests, swaps into production, tags `build/prod/0.1.0`, creates GitHub Release `v0.1.0`, and opens a back-merge PR to `develop`.

## Next steps

- Adapt the template to your own application: [customization.md](customization.md)
- Learn the day-to-day flows (hotfixes, rollbacks, redeploys): [operations manual](operations-manual.md)
- Understand the design: [ARCHITECTURE.md](ARCHITECTURE.md)
- Inspect what GitHub's OIDC tokens actually contain: run the **Show OIDC Token Claims** workflow (Actions → Show OIDC Token Claims)
