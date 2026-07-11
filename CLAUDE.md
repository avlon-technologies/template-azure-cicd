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

- `_build.yml` — build, test, publish, upload `webapp-publish` artifact. Accepts an optional `version` input; otherwise the build label defaults to `YYYYMMDD.<run_number>`. The label is stamped into `InformationalVersion` at the *build* step (publish runs `--no-build`) and surfaces in Swagger. Outputs `build-label`. Commit-keyed (promotable) builds also upload a marker artifact `<artifact-name>.label.<label>` whose *name* records the stamped label — the stg pipelines' reuse check reads it without downloading anything. Requires `checks: write` and `pull-requests: write` on the caller to publish test results as a PR check via `EnricoMi/publish-unit-test-result-action`.
- `_deploy.yml` — downloads the artifact, logs into Azure via OIDC, deploys to App Service (with `slot-swap: true`, used by prod: deploy to `staging` slot → smoke test → swap; a failed *post-swap* smoke test automatically swaps the previous build back), smoke-tests `/v1/hello` *and* asserts `/openapi/v1.json` reports the deployed `build-label` (a pre-release of it also passes — promoted candidate binaries keep their stamp), prints the URL to the run summary, and — when the caller sets `tag-deployment: true` (stg and prod callers do; dev doesn't) — tags `build/<environment>/<build-label>` on the commit the artifact was built from (`source-sha` input, defaults to the run's HEAD). stg tags double as the prod promotion gate's proof of a green staging deploy. Tags are immutable: an existing tag at a different commit fails the deploy (same commit is a no-op). Requires a GitHub environment (`dev` | `stg` | `prod`) — the App Service name and OIDC client ID come from that environment's variables (`WEBAPP_NAME`, `AZURE_CLIENT_ID`), scoped by the job's `environment:` declaration, so entry workflows carry no per-env config. Callers must grant `id-token: write`, `contents: write`, and `actions: read` (the last for the REST-API artifact download, used by cross-run promotion).
- `on-pr.yml` — builds/tests PRs to `develop`/`main`; the check is required by rulesets, which also enforce PR-only merges (merge-commit-only on `main`).

Pipeline behavior also depends on repo settings outside these files: rulesets, workflow permissions (default token read-only; "Actions can create PRs" enabled for the back-merge step), the `AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID` repo variables, and the per-environment `AZURE_CLIENT_ID`/`WEBAPP_NAME` variables — see the "Repository settings" section of `docs/operations-manual.md`. Gotcha: jobs downstream of the promotion path's skipped `build` job need explicit `!failure() && !cancelled()` conditions (implicit `success()` fails on skipped ancestors).

Entry workflows carry `concurrency` groups so deploys to the same environment serialize (`deploy-dev` / `deploy-stg` / `deploy-prod`; the three stg pipelines share a group on dispatch, group per-branch on push); `on-pr.yml` cancels superseded PR builds. All actions are pinned to commit SHAs with a `# vX.Y.Z` comment — Dependabot (`.github/dependabot.yml`) keeps the pins current; when bumping manually, update the SHA and the comment together.

Branch → environment mapping:

| Entry workflow | Trigger branches | Environment / App Service |
|---|---|---|
| `on-develop.yml` | `develop` | dev / `app-cicd-demo-dev-cc` |
| `on-release.yml` | `release/**`, `milestone/**` | stg / `app-cicd-demo-stg-cc` |
| `on-hotfix.yml` | `hotfix/**` | stg / `app-cicd-demo-stg-cc` |
| `on-support.yml` | `support/**` | stg / `app-cicd-demo-stg-cc` |
| `on-main.yml` | `main` | prod / `app-cicd-demo-prod-cc` |

Release specifics (`on-release.yml`): pushes only build (deploy is gated on `workflow_dispatch`; no dispatch inputs). Labels are **commit-derived** — a pure function of branch name + commit height (`git rev-list --count HEAD`, hence the prepare job's `fetch-depth: 0` checkout): `release/X.Y.Z` at height N builds `X.Y.Z-build.N`, `milestone/<name>` builds `ms-<name>.N`. Because every build of a commit yields the same label, *push* builds are already promotable: they upload commit-keyed artifacts (`webapp-<sha>` + a `.label.<label>` marker, 90-day retention), and a dispatch **reuses the push artifact and skips the build entirely** (a missing/expired artifact rebuilds; a marker that disagrees with the derived label — possible only if the derivation logic changed between push and dispatch — deploys under the *stamped* label, since the version is compiled in and re-labeling would ship a binary that reports the wrong version). When the release merges to main, `on-main.yml` **promotes** that exact artifact (build job skipped) — a missing/expired artifact, or a release head with no `build/stg/*` tag (built but never green on staging), **fails the prod run** (no silent rebuild of untested source; re-dispatch the release pipeline to stage a fresh candidate, verify staging, then re-run). Labels are charset-restricted (letters/digits/`.`/`-`) because they become artifact names and git tags — a branch name that derives an invalid label fails the build with a rename instruction.

`on-main.yml` accepts an optional `version` dispatch input for rollback/redeploy: supply a previously released version (e.g. `1.5.0`) to promote that release's stg-tested artifact to prod via the same blue/green path. Requires the artifact to be within its 90-day retention window. The `release` and `backmerge` jobs are skipped on dispatch (push-only). Dispatching without a version redeploys the current HEAD of `main`. The `backmerge` job runs **parallel to deploy** (needs only `prepare`) so develop gets the merged commits back even if the prod deploy fails or waits on an environment approval: release sources get a branch back-merge PR; hotfix/support sources get a cherry-pick (`-m 1` of the merge commit) onto a `backport/<version>` branch instead, because those branches are cut from `main` or old version tags — their history is foreign to develop.

`on-develop.yml` accepts an optional `build-label` dispatch input: supply a previous dev build label to rebuild HEAD stamped with that label and redeploy to dev (useful for retrying a failed deploy with the same label). Dev deploys are not tagged — the label is validated against the workflow's own run history (labels are `YYYYMMDD.<run_number>`, so the original run is findable); dispatching without a label behaves identically to a push.

Hotfix/support specifics (`on-hotfix.yml`, `on-support.yml`): same dispatch-gated pattern as releases — pushes build and test with the commit-derived label (`X.Y.Z-hotfix.<height>` / `X.Y.Z-patch.<height>`) and upload promotable commit-keyed artifacts; dispatch reuses the push artifact and deploys to stg (no dispatch inputs). Merging either to `main` auto-detects the version from the merge commit subject (regex covers `release|hotfix|support`; a push whose subject doesn't parse **fails the run** rather than falling back to an untested date-label rebuild — only a version-less manual dispatch may rebuild `main` for prod) and triggers the same prod promotion and GitHub Release creation as a release merge; both get a cherry-pick backport PR to develop instead of a branch back-merge (see above). Cut `hotfix/X.Y.Z` and `support/X.Y.Z` branches from `main` (or a version tag), not `develop`.

## Infrastructure

Lives in the platform Terraform repo: `../infrastructure` (`avlon-technologies/infrastructure`) — module `infra/modules/cicd-demo/`, environment roots `infra/environments/cicd-demo/{dev,stg,prod}/` (hosted there rather than here per its ADR-0002; naming and layout follow `../engineering-standards`). Per environment it provisions a resource group `rg-cicd-demo-<env>-cc` containing a Linux App Service plan `asp-cicd-demo-<env>-cc` (B1 for dev/stg; P0v3 for prod), the App Service `app-cicd-demo-<env>-cc` (.NET 10 — the name the deploy workflows target via `WEBAPP_NAME`), a `staging` slot in prod only (the blue/green swap target), and the deploy identity below. Apps are served directly on `*.azurewebsites.net` — there is no VNet/Application Gateway layer. Remote state: `sttfstatesharedcc` / `tfstate-<env>` / `cicd-demo.tfstate`.

## Deploy identity

CI deploys log into Azure via OIDC using one user-assigned managed identity per environment (`mi-github-cicd-demo-<env>-cc`, in the workload's own resource group), each with a federated credential for its GitHub environment (`repo:avlon-technologies/template-azure-cicd:environment:<env>`) and Website Contributor scoped to its own resource group only. Client IDs live in each GitHub environment's `AZURE_CLIENT_ID` variable (read by `_deploy.yml`): dev `66b2a296-…`, stg `964871d3-…`, prod `a7cf94d6-…`. Deploys fail until the Terraform in `../infrastructure` has been applied for the target environment (the App Service must exist).
