# Operations Manual

How to build, deploy, release, and verify this application across environments.

## Environments at a glance

| Environment | App Service | Direct URL | Via shared gateway | Deployed by |
|---|---|---|---|---|
| dev | `dev-demo-helloworld-api` | https://dev-demo-helloworld-api.azurewebsites.net | http://52.139.34.97:8081/ | push to `develop` (automatic) |
| stg | `stg-demo-helloworld-api` | https://stg-demo-helloworld-api.azurewebsites.net | http://52.139.34.97:8082/ | manual dispatch of a release, hotfix, or support pipeline |
| prod | `prod-demo-helloworld-api` | https://prod-demo-helloworld-api.azurewebsites.net | http://52.139.34.97/ | merge PR to `main` (automatic, blue/green slot swap) |

**Quality gates (enforced by repository rulesets):** all merges to `develop` and `main` go through a pull request, every PR must pass the **build / Build & Test** check (the `on-pr.yml` workflow), and `main` accepts merge commits only — squash and rebase are disabled there because release version detection reads the merge commit subject. **PRs into `main` may only come from `release/*`, `hotfix/*`, or `support/*` branches** (the **Guard main source branch** check) — features flow to prod through a release, never directly.

Every deploy, in every environment, ends with an automatic **smoke test**: `GET /v1/hello` must return `Hello World!` **and** `/openapi/v1.json` must report the build label being deployed (or a pre-release of it — promoted binaries keep their rc stamp). A deploy that leaves the app broken *or serving the wrong build* fails the pipeline instead of reporting success.

## Deploy to dev (automatic)

Merging a PR to `develop` (or any push to it) triggers **CI/CD — Develop → DEV**: build → test → deploy to dev. No manual steps.

```
gh pr create --base develop --head my-feature
gh pr merge --merge
```

The build is labeled `YYYYMMDD.<run_number>` and the deployed commit is tagged `build/dev/<label>`.

To manually redeploy a previous build to dev (e.g. to retry a failed deploy with the same label):

**From the command line:**
```
gh workflow run on-develop.yml --ref develop -f build-label=20260703.32
```

**From the UI:** Actions → **CI/CD — Develop → DEV** → Run workflow → enter the build label (e.g. `20260703.32`). The label must correspond to an existing `build/dev/<label>` tag — the pipeline fails fast if it doesn't. A fresh build of HEAD is stamped with that label and deployed; leave the input empty to build and deploy HEAD normally.

## Cut a release

Once the state of `develop` is ready to become a release, create and push a release branch named after the bare version (no `v`, no rc suffix — see naming rationale below):

```
git checkout develop && git pull
git checkout -b release/1.1.0
git push -u origin release/1.1.0
```

Every push to `release/**` triggers **CI/CD — Release → STG** in build-only mode: it builds and tests with the auto-label `1.1.0-build.<run_number>` but does **not** deploy. Land stabilization fixes directly on this branch.

## Deploy a release candidate to staging

Deploys to stg are gated on a human trigger (manual dispatch). Give each candidate an rc label: `1.1.0-rc.1`, then `-rc.2` as fixes land.

**From the UI:**
1. **Actions** tab → **CI/CD — Release → STG** (left sidebar)
2. Click **Run workflow**
3. **Use workflow from:** select the release branch (e.g. `release/1.1.0`) — easy to miss; it defaults to `main`
4. **version:** enter the candidate label, e.g. `1.1.0-rc.1`
5. Click **Run workflow**

**From the command line:**
```
gh workflow run on-release.yml --ref release/1.1.0 -f version=1.1.0-rc.1
```

The run deploys to stg and tags the commit `build/stg/1.1.0-rc.1` — the audit trail of exactly what QA tested.

The version label must match the release branch: dispatching from `release/1.1.0` accepts `1.1.0` or `1.1.0-<pre-release>` (e.g. `1.1.0-rc.1`) and **fails fast** on anything else (e.g. `1.2.0-rc.1`), so staging can't be stamped or tagged with a version that doesn't belong to the branch.

Re-dispatching the same label on the same branch (e.g. to pick up a config change or retry a flaky deploy) skips the build and redeploys the existing artifact — the binary that reaches stg is byte-identical to the one from the first dispatch. Note that the **first** dispatch always builds: the push-triggered artifact (`webapp-publish`) has a date-based auto-label and is not reusable. Only once a dispatch has produced a commit-keyed `webapp-<sha>` artifact will subsequent dispatches with the same label skip the build.

## Deploy to production

When a candidate is accepted, merge the release branch to `main` via PR:

```
gh pr create --base main --head release/1.1.0 --title "Release 1.1.0"
gh pr merge --merge        # merge commit — do NOT squash (see note)
```

Merging triggers **CI/CD — Main → PROD**, which automatically:

1. Extracts `1.1.0` from the merge commit subject
2. **Promotes the stg-tested artifact** (build-once-promote-many): rc dispatches store their build keyed by commit SHA with 90-day retention; the prod pipeline finds the artifact for the merged release head and ships *that exact binary* — the build job is skipped. "Stg-tested" is verified, not assumed: promotion requires a `build/stg/*` tag on the release head, which only a stg deploy that passed its smoke test creates. If no rc was ever dispatched, the artifact expired, or the candidate never went green on staging, the run **fails** rather than silently rebuilding or shipping untested source — dispatch the release pipeline to stage a candidate, verify staging, then re-run
3. Deploys **blue/green**: the artifact goes to the `staging` slot first, is smoke-tested there, and only then swapped into production — a bad build never reaches users, and the previous build stays in the slot for instant rollback (swap back)
4. Smoke-tests production after the swap — if that fails, the previous build is **automatically swapped back** — and tags the release-branch commit the artifact was built from as `build/prod/1.1.0`
5. Creates GitHub Release **v1.1.0** with generated notes

> **Promoted artifacts keep their rc stamp.** Because the promoted binary is byte-identical to what QA tested, prod's Swagger shows the rc label it was built with (e.g. `1.1.0-rc.3`) — that's a feature: it tells you exactly which candidate was promoted. The git tag (`build/prod/1.1.0`) and GitHub Release (`v1.1.0`) carry the release version.

> **Always use a merge commit for release PRs.** The version is read from the merge commit subject ("Merge pull request #N from …/release/1.1.0"). A squash merge usually hides the branch name, so the build falls back to a date label and no GitHub Release is created; if a version *is* detected on a non-merge commit, the run fails outright because the stg-tested artifact can't be located. Squash also breaks the back-merge below.

6. Opens a **back-merge PR** from the release branch into `develop`, so stabilization fixes aren't lost (requires the "Allow GitHub Actions to create and approve pull requests" setting — see repository settings below)

The back-merge PR is created automatically but merged manually — review it (conflicts with ongoing develop work are possible), merge with a merge commit, then delete the release branch:

```
gh pr merge <back-merge-pr> --merge
git push origin --delete release/1.1.0
```

(If nothing landed on the release branch after it was cut, the PR will show no diff or won't be created — just delete the branch.)

## Hotfix production

For urgent fixes that can't wait for a release cycle. Always cut from `main` (or the relevant version tag), not `develop`:

```
git checkout main && git pull
git checkout -b hotfix/1.1.1
# fix, commit
git push -u origin hotfix/1.1.1
```

Pushes build and test only — no automatic stg deploy. When ready to verify on stg, dispatch manually:

**From the UI:** Actions → **CI/CD — Hotfix → STG** → Run workflow → select the hotfix branch → enter the version label (e.g. `1.1.1` or `1.1.1-rc.1`)

**From the command line:**
```
gh workflow run on-hotfix.yml --ref hotfix/1.1.1 -f version=1.1.1-rc.1
```

When verified, PR `hotfix/1.1.1 → main` (merge commit). Merging triggers **CI/CD — Main → PROD**, which auto-detects `1.1.1` from the merge commit subject, promotes the stg-tested artifact, creates GitHub Release `v1.1.1`, and opens a back-merge PR to `develop`.

The version label must match the hotfix branch: `1.1.1` or `1.1.1-<pre-release>`. Re-dispatching the same label skips the rebuild and redeploys the existing artifact (same rules as the release flow).

## Maintain a support branch

Use a `support/X.Y.Z` branch to backport fixes to a prior production version while a newer release is in progress on `develop`. Cut from `main` at the relevant version tag:

```
git checkout -b support/1.4.1 v1.4.0
git push -u origin support/1.4.1
```

The workflow (`on-support.yml`) behaves identically to the hotfix flow: pushes build and test only, deploys to stg on manual dispatch, and merging to `main` triggers full prod promotion, a GitHub Release `v1.4.1`, and a back-merge PR to `develop`.

**From the command line:**
```
gh workflow run on-support.yml --ref support/1.4.1 -f version=1.4.1-rc.1
gh pr create --base main --head support/1.4.1 --title "Support 1.4.1"
gh pr merge --merge
```

> **Note:** the `support/*` source branch must be enabled in the GitHub ruleset for `main` (Settings → Rules → the `main` ruleset → bypass/source branch list). See the repository settings section below.

## Roll back production

**Immediate rollback (previous build only):** The staging slot holds the previous production build after every swap. To roll back, swap again:

```
az webapp deployment slot swap --resource-group prod-demo-helloworld-rg \
  --name prod-demo-helloworld-api --slot staging --target-slot production
```

This is near-instant (no rebuild, no redeploy).

**Rollback to any previously released version:** Dispatch `on-main.yml` with the target version:

```
gh workflow run on-main.yml --ref main -f version=1.5.0
```

**From the UI:** Actions → **CI/CD — Main → PROD** → Run workflow → enter the version (e.g. `1.5.0`). The pipeline resolves the `v<version>` release tag, promotes the artifact that was stg-tested for that release (same artifact promotion as a normal release merge), and deploys via the blue/green slot swap. The `build/prod/<version>` tag already points at the release commit that produced the artifact, so tagging is a no-op. No new GitHub Release is created — only push-triggered runs create releases.

The artifact must be within its 90-day retention window. If it has expired, the pipeline fails with an error instructing you to re-dispatch the release pipeline from the release branch to produce a fresh artifact.

**For dev/stg (no slots):** Re-run an earlier successful workflow run or revert the commit.

## Verify a deployment

- **Run summary** — every deploy run's summary page shows a "🚀 Deployed" card with the app, Swagger, and API URLs.
- **Swagger** — `<app-url>/swagger` shows the exact build label, linked commit SHA, and environment of what's running.
- **Smoke test** — already ran automatically; a green deploy job means the app answered correctly.
- **Deployments view** — repo home → right sidebar → **Deployments** (or `/deployments`): per-environment history.
- **Tags** — `git fetch --tags && git tag -l 'build/*'`: every successful deploy tags the exact commit as `build/<env>/<label>`.
- **Releases** — repo **Releases** page lists `vX.Y.Z` with generated notes.

## Version and branch naming

| Thing | Convention | Example |
|---|---|---|
| Release branch | bare version | `release/1.1.0` |
| Hotfix branch | bare patch version | `hotfix/1.1.1` |
| Support branch | bare patch version | `support/1.1.1` |
| Candidate label (dispatch input / stg tag) | SemVer pre-release | `1.1.0-rc.2` |
| Release / hotfix / support tag (automatic on prod deploy) | `v` + version | `v1.1.0` |

The rc number identifies a *candidate build*; the branch identifies the *line of development* — so rc numbers never appear in branch names.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Run fails instantly with `startup_failure` and no logs | A caller job is missing the `permissions:` block (`id-token: write`, `contents: write`) that `_deploy.yml` requires — the repo default token is read-only and called workflows can't elevate it |
| Deploy fails: "Resource … doesn't exist" | The target App Service hasn't been provisioned — run `terraform apply` for that environment in `../cicd-infrastructure` |
| Deploy fails at "Login to Azure" | Federated credential / identity problem — see `docs/workload-identity-federation.md` |
| Push to `develop`/`main` rejected (GH013) | Rulesets require a PR — open one instead of pushing directly |
| Release merged but prod tag is a date, no GitHub Release | The PR was squash-merged; the version is only detected on merge commits (main's ruleset now blocks squash, so this should no longer occur) |
| PR can't merge: "required status check missing" | Wait for the **build / Build & Test** check from `on-pr.yml` to pass; if it never appears, the PR predates the check — push any commit to re-trigger |
| Prod deploy failed at "Smoke test staging slot" | The new build is unhealthy — **production was not touched** (swap never happened). Fix and redeploy; nothing to roll back |
| Prod deploy failed at "Smoke test deployment" (after the swap) | The swap went through but prod stopped answering — the pipeline **automatically swapped the previous build back**; production is running the prior version. Investigate the bad build before redeploying |
| Release merged but prod deploy fails: "No unexpired stg-tested artifact" | No rc was ever dispatched to stg for the merged release head (or the artifact expired). Dispatch the release pipeline on the source branch to build and stage-test one, then re-run the failed prod run — it will find and promote the fresh artifact |
| Release merged but prod deploy fails: "No build/stg/* tag points at …" | The rc artifact was built, but its stg deploy never went green (smoke test failed, deploy errored, or the dispatch was cancelled). Re-dispatch the release pipeline on the source branch, let the stg deploy pass, then re-run the prod run |
| Smoke test fails: "reports version 'X', expected 'Y'" | The app answers but is running the wrong build — the deploy or swap didn't take effect, or the wrong artifact shipped. Check which run last deployed to that environment; redeploy the intended label |
| Deploy fails at "Tag deployment": "Deployment tags are immutable" | The `build/<env>/<label>` tag already points at different code — a label was reused for a different commit. Use a new label (only the dev same-label redeploy flow may move tags) |
| Deploy failed at "Smoke test deployment" (dev/stg) | The build deployed but isn't answering — check App Service logs; the previous build is gone, so fix forward or re-run the last good workflow run |
| Deploy run sits in "Queued" | Concurrency groups serialize deploys per environment (`deploy-dev`, `deploy-stg`, `deploy-prod`) — the run starts when the in-flight deploy to that environment finishes |
| A job after a *skipped* job never runs | GitHub implicitly wraps `if` conditions in `success()`, which is false when **any ancestor job was skipped** — and the promotion path skips `build` by design. Downstream jobs must use `!failure() && !cancelled()` explicitly (deploy and release already do; copy that pattern for new jobs) |
| Back-merge PR wasn't created after a release | Check the release job's "Open back-merge PR" step log. If it says "not permitted to create pull requests", re-enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests** |
| rc dispatch fails at "Resolve and validate version" | The version label doesn't match the release branch (e.g. `1.2.0-rc.1` dispatched from `release/1.3.0`). Use `<branch-version>` or `<branch-version>-<pre-release>` |
| Re-dispatch with same label rebuilds instead of reusing artifact | The prior `webapp-<sha>` artifact has expired (90-day retention). A fresh build is the correct fallback — the new artifact will be used for any subsequent redeploys and for prod promotion |
| Prod rollback dispatch fails: "Artifact for v… has expired" | The stg-tested artifact for that release is beyond its 90-day window. Re-dispatch the release pipeline from the release branch (`gh workflow run on-release.yml --ref release/X.Y.Z -f version=X.Y.Z-rc.1`) to rebuild the artifact, then retry the rollback dispatch |

## Repository settings the pipeline depends on

These live in GitHub settings, not in the workflow files — if the repo is ever recreated or transferred, they must be reconfigured:

| Setting | Where | Value |
|---|---|---|
| Rulesets `develop` / `main` / `release` | Settings → Rules | PR required; **build / Build & Test** status check required; `main` allows merge commits only; `main` source branches must include `support/*` |
| Workflow permissions | Settings → Actions → General | Default token: **read-only**; **Allow GitHub Actions to create and approve pull requests: on** (the back-merge PR needs it) |
| Repo variables | Settings → Secrets and variables → Actions | `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (used by `_deploy.yml`; not secrets) |
| Environment variables | Settings → Environments → (each env) → Environment variables | `AZURE_CLIENT_ID`, `WEBAPP_NAME` per environment — `_deploy.yml` reads them via the job's `environment:` scope, so entry workflows carry no per-env config |
| Environments | Settings → Environments | `dev`, `stg`, `prod` — each matched by a federated credential on its deploy identity |

There are deliberately **no repository secrets** — Azure auth is OIDC workload identity federation (see `docs/workload-identity-federation.md`).

## Infrastructure changes

All Azure resources (App Services, VNets, Key Vaults, App Gateway, deploy identities) are Terraform-managed in the separate **cicd-infrastructure** repo — change infrastructure there via plan/apply, never in the Azure Portal. See that repo's README for usage.
