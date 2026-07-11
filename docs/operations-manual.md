# Operations Manual

How to build, deploy, release, and verify this application across environments.

> Setting the pipeline up for the first time? Start with [getting-started.md](getting-started.md). Adapting the template to your own project? See [customization.md](customization.md). This manual covers day-to-day operation of a configured pipeline.

## Environments at a glance

| Environment | App Service | Direct URL | Via shared gateway | Deployed by |
|---|---|---|---|---|
| dev | `dev-demo-helloworld-api` | https://dev-demo-helloworld-api.azurewebsites.net | `http://<gateway-ip>:8081/` | push to `develop` (automatic) |
| stg | `stg-demo-helloworld-api` | https://stg-demo-helloworld-api.azurewebsites.net | `http://<gateway-ip>:8082/` | manual dispatch of a release, hotfix, or support pipeline |
| prod | `prod-demo-helloworld-api` | https://prod-demo-helloworld-api.azurewebsites.net | `http://<gateway-ip>/` | merge PR to `main` (automatic, blue/green slot swap) |

(`<gateway-ip>` is the shared Application Gateway's public IP, an output of the infrastructure deployment — one frontend port per environment.)

**Quality gates (enforced by repository rulesets):** all merges to `develop` and `main` go through a pull request, every PR must pass the **build / Build & Test** check (the `on-pr.yml` workflow), and `main` accepts merge commits only — squash and rebase are disabled there because release version detection reads the merge commit subject. **PRs into `main` may only come from `release/*`, `hotfix/*`, or `support/*` branches** (the **Guard main source branch** check) — features flow to prod through a release, never directly.

Every deploy, in every environment, ends with an automatic **smoke test**: `GET /v1/hello` must return `Hello World!` **and** `/openapi/v1.json` must report the build label being deployed (or a pre-release of it — promoted binaries keep their rc stamp). A deploy that leaves the app broken *or serving the wrong build* fails the pipeline instead of reporting success.

## Deploy to dev (automatic)

Merging a PR to `develop` (or any push to it) triggers **CI/CD — Develop → DEV**: build → test → deploy to dev. No manual steps.

```
gh pr create --base develop --head my-feature
gh pr merge --merge
```

The build is labeled `YYYYMMDD.<run_number>`. Dev deploys are not tagged — the **Deployments** view and the run history are the record, and the running build is always identifiable via Swagger.

To manually redeploy a previous build to dev (e.g. to retry a failed deploy with the same label):

**From the command line:**
```
gh workflow run on-develop.yml --ref develop -f build-label=20260703.32
```

**From the UI:** Actions → **CI/CD — Develop → DEV** → Run workflow → enter the build label (e.g. `20260703.32`). The label must match a previous **CI/CD — Develop → DEV** run (it's validated against the workflow's run history) — the pipeline fails fast if it doesn't. A fresh build of HEAD is stamped with that label and deployed; leave the input empty to build and deploy HEAD normally.

## Cut a release

Once the state of `develop` is ready to become a release, create and push a release branch named after the bare version (no `v`, no rc suffix — see naming rationale below):

```
git checkout develop && git pull
git checkout -b release/1.1.0
git push -u origin release/1.1.0
```

Every push to `release/**` triggers **CI/CD — Release → STG** in build-only mode: it builds and tests but does **not** deploy. Land stabilization fixes directly on this branch.

**Candidate labels are derived from the commit, not chosen.** The label is a pure function of the branch name and the commit height (`git rev-list --count HEAD`): the tip of `release/1.1.0` at height 187 builds `1.1.0-build.187`, and every stabilization fix advances the height, minting the next candidate automatically. There is no version input anywhere in the flow. Because the same commit always derives the same label, the push build's artifact is already the candidate — it is uploaded commit-keyed (`webapp-<sha>`, 90-day retention) with a marker recording its label.

## Deploy a release candidate to staging

Deploys to stg are gated on a human trigger (manual dispatch). Dispatching means exactly "deploy this branch's HEAD to stg" — nothing to type.

**From the UI:**
1. **Actions** tab → **CI/CD — Release → STG** (left sidebar)
2. Click **Run workflow**
3. **Use workflow from:** select the release branch (e.g. `release/1.1.0`) — easy to miss; it defaults to the repository's default branch (`develop`), and the pipeline fails fast if the selected branch isn't a `release/*` or `milestone/*` branch
4. Click **Run workflow**

**From the command line:**
```
gh workflow run on-release.yml --ref release/1.1.0
```

The dispatch **reuses the artifact the push already built** — the build job is skipped, and the binary that reaches stg is byte-identical to the one CI tested on push. The run deploys to stg and tags the commit `build/stg/1.1.0-build.187` — the audit trail of exactly what QA tested. Re-dispatching on the same commit redeploys the same artifact; a rebuild happens only if the artifact expired (90 days) or the push predates the marker scheme. A new candidate requires a new commit — push the fix, the height advances, dispatch again.

## Deploy to production

When a candidate is accepted, merge the release branch to `main` via PR:

```
gh pr create --base main --head release/1.1.0 --title "Release 1.1.0"
gh pr merge --merge        # merge commit — do NOT squash (see note)
```

Merging triggers **CI/CD — Main → PROD**, which automatically:

1. Extracts `1.1.0` from the merge commit subject
2. **Promotes the stg-tested artifact** (build-once-promote-many): release-branch builds are stored keyed by commit SHA with 90-day retention; the prod pipeline finds the artifact for the merged release head and ships *that exact binary* — the build job is skipped. "Stg-tested" is verified, not assumed: promotion requires a `build/stg/*` tag on the release head, which only a stg deploy that passed its smoke test creates. If the candidate was never dispatched to stg, the artifact expired, or it never went green on staging, the run **fails** rather than silently rebuilding or shipping untested source — dispatch the release pipeline to stage the candidate, verify staging, then re-run
3. Deploys **blue/green**: the artifact goes to the `staging` slot first, is smoke-tested there, and only then swapped into production — a bad build never reaches users, and the previous build stays in the slot for instant rollback (swap back)
4. Smoke-tests production after the swap — if that fails, the previous build is **automatically swapped back** — and tags the release-branch commit the artifact was built from as `build/prod/1.1.0`
5. Creates GitHub Release **v1.1.0** with generated notes

> **Promoted artifacts keep their candidate stamp.** Because the promoted binary is byte-identical to what QA tested, prod's Swagger shows the label it was built with (e.g. `1.1.0-build.187`) — that's a feature: it tells you exactly which candidate was promoted. The git tag (`build/prod/1.1.0`) and GitHub Release (`v1.1.0`) carry the release version.

> **Always use a merge commit for release PRs, with the default message.** The version is read from the merge commit subject ("Merge pull request #N from …/release/1.1.0"). A push whose subject doesn't name a `release/*`, `hotfix/*`, or `support/*` branch — a squash merge, or a merge message customized at merge time — **fails the prod run outright**: the stg-tested artifact can't be located without a version, and the pipeline refuses to rebuild untested source for prod. (Redeploying `main` without a version remains available as an explicit escape hatch via manual dispatch.) Squash also breaks the back-merge below.

6. Opens a **back-merge PR** from the release branch into `develop`, so stabilization fixes aren't lost (requires the "Allow GitHub Actions to create and approve pull requests" setting — see repository settings below). This runs as its own `backmerge` job, **in parallel with the deploy** rather than after it: the commits are on `main` the moment the PR merges, so `develop` needs them back even if the prod deploy fails or is still waiting on an environment approval. (For **hotfix and support** merges the job cherry-picks onto a `backport/<version>` branch instead of back-merging the source branch — see the hotfix section.)

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

Pushes build and test with the commit-derived label (`1.1.1-hotfix.<height>`) and store the promotable artifact — no automatic stg deploy. When ready to verify on stg, dispatch manually (no inputs; the dispatch reuses the push build's artifact and skips the rebuild):

**From the UI:** Actions → **CI/CD — Hotfix → STG** → Run workflow → select the hotfix branch (the **Use workflow from** selector defaults to `develop` — same trap as the release dispatch; the pipeline fails fast if the branch isn't `hotfix/*`)

**From the command line:**
```
gh workflow run on-hotfix.yml --ref hotfix/1.1.1
```

When verified, PR `hotfix/1.1.1 → main` (merge commit). Merging triggers **CI/CD — Main → PROD**, which auto-detects `1.1.1` from the merge commit subject, promotes the stg-tested artifact, creates GitHub Release `v1.1.1`, and raises a **cherry-pick backport PR** to `develop`: because hotfix branches are cut from `main` (not `develop`), their history is never merged into `develop` directly — the `backmerge` job cherry-picks the merge commit's diff (`-m 1`) onto a `backport/1.1.1` branch and opens the PR from that. If the cherry-pick hits conflicts, the job fails with the exact manual commands to run; if `develop` already contains the change, it skips gracefully.

Re-dispatching on the same commit redeploys the same artifact; a new candidate label requires a new commit (the height advances with each fix) — same rules as the release flow.

## Maintain a support branch

Use a `support/X.Y.Z` branch to backport fixes to a prior production version while a newer release is in progress on `develop`. Cut from `main` at the relevant version tag:

```
git checkout -b support/1.4.1 v1.4.0
git push -u origin support/1.4.1
```

The workflow (`on-support.yml`) behaves identically to the hotfix flow: pushes build and test only, deploys to stg on manual dispatch, and merging to `main` triggers full prod promotion, a GitHub Release `v1.4.1`, and the same **cherry-pick backport PR** to `develop` as a hotfix (see the hotfix section). Conflicts are more likely here than for hotfixes — `develop` has usually drifted far from the old supported version — so expect to finish some backports manually using the commands from the failed job's log.

**From the command line:**
```
gh workflow run on-support.yml --ref support/1.4.1
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
- **Tags** — `git fetch --tags && git tag -l 'build/*'`: every successful **stg/prod** deploy tags the exact commit as `build/stg/<label>` or `build/prod/<label>` — the audit trail of what QA/UAT tested and what shipped. Dev deploys are not tagged.
- **Releases** — repo **Releases** page lists `vX.Y.Z` with generated notes.

## Version and branch naming

| Thing | Convention | Example |
|---|---|---|
| Release branch | bare version | `release/1.1.0` |
| Hotfix branch | bare patch version | `hotfix/1.1.1` |
| Support branch | bare patch version | `support/1.1.1` |
| Candidate label (commit-derived; appears in stg tags and Swagger) | branch version + kind + commit height | `1.1.0-build.187`, `1.1.1-hotfix.42` |
| Release / hotfix / support tag (automatic on prod deploy) | `v` + version | `v1.1.0` |

The candidate label identifies a *build of one commit* — it is derived (`git rev-list --count HEAD`), never typed, so the same commit always carries the same label and each new commit mints the next candidate. The branch identifies the *line of development*; candidate suffixes never appear in branch names.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Run fails instantly with `startup_failure` and no logs | A caller job is missing the `permissions:` block (`id-token: write`, `contents: write`) that `_deploy.yml` requires — the repo default token is read-only and called workflows can't elevate it |
| Deploy fails: "Resource … doesn't exist" | The target App Service hasn't been provisioned — apply the infrastructure for that environment first (see [getting-started — Step 2](getting-started.md#step-2--provision-azure-resources)) |
| Deploy fails at "Login to Azure" | Federated credential / identity problem — see `docs/workload-identity-federation.md` |
| Push to `develop`/`main` rejected (GH013) | Rulesets require a PR — open one instead of pushing directly |
| Release merged but prod run fails: "Could not parse a release/hotfix/support branch from the merge commit subject" | The PR was squash-merged or the merge message was customized, hiding the branch name — the run refuses to fall back to an untested rebuild. Redeploy by dispatching **CI/CD — Main → PROD** with the version, and keep the default merge message next time (main's ruleset blocks squash, so a customized message is the usual cause) |
| PR can't merge: "required status check missing" | Wait for the **build / Build & Test** check from `on-pr.yml` to pass; if it never appears, the PR predates the check — push any commit to re-trigger |
| Prod deploy failed at "Smoke test staging slot" | The new build is unhealthy — **production was not touched** (swap never happened). Fix and redeploy; nothing to roll back |
| Prod deploy failed at "Smoke test deployment" (after the swap) | The swap went through but prod stopped answering — the pipeline **automatically swapped the previous build back**; production is running the prior version. Investigate the bad build before redeploying |
| Release merged but prod deploy fails: "No unexpired stg-tested artifact" | The candidate was never dispatched to stg (or its artifact expired). Dispatch the release pipeline on the source branch, verify staging, then re-run the failed prod run — it will find and promote the artifact |
| Release merged but prod deploy fails: "No build/stg/* tag points at …" | The candidate was built, but its stg deploy never went green (smoke test failed, deploy errored, or the dispatch was cancelled). Re-dispatch the release pipeline on the source branch, let the stg deploy pass, then re-run the prod run |
| Smoke test fails: "reports version 'X', expected 'Y'" | The app answers but is running the wrong build — the deploy or swap didn't take effect, or the wrong artifact shipped. Check which run last deployed to that environment; redeploy the intended label |
| Deploy fails at "Tag deployment": "Deployment tags are immutable" | The `build/<env>/<label>` tag already points at different code — two different commits derived the same label (e.g. a release branch re-cut at the same commit height). Push another commit to advance the height, or delete the stale tag if its run is confirmed dead |
| Deploy failed at "Smoke test deployment" (dev/stg) | The build deployed but isn't answering — check App Service logs; the previous build is gone, so fix forward or re-run the last good workflow run |
| Deploy run sits in "Queued" | Concurrency groups serialize deploys per environment (`deploy-dev`, `deploy-stg`, `deploy-prod`) — the run starts when the in-flight deploy to that environment finishes |
| A job after a *skipped* job never runs | GitHub implicitly wraps `if` conditions in `success()`, which is false when **any ancestor job was skipped** — and the promotion path skips `build` by design. Downstream jobs must use `!failure() && !cancelled()` explicitly (deploy and release already do; copy that pattern for new jobs) |
| Back-merge PR wasn't created after a release | Check the `backmerge` job's log. If it says "not permitted to create pull requests", re-enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests** |
| Backport PR wasn't created after a hotfix/support merge | The cherry-pick onto `develop` hit conflicts — the `backmerge` job log contains the exact manual commands (`git cherry-pick -m 1 <merge-sha>` onto a `backport/<version>` branch); resolve and open the PR by hand |
| Dispatch fails at "Derive version from the commit" | The workflow was dispatched from the wrong branch (the **Use workflow from** selector defaults to `develop`), or the branch name derives a label with characters outside letters/digits/`.`/`-`. Select the right branch, or rename it |
| Dispatch rebuilds instead of reusing the push artifact | The `webapp-<sha>` artifact has expired (90-day retention), or predates label markers (no `webapp-<sha>.label.<label>` companion artifact). A fresh build is the correct fallback — same commit, same derived label, so the new artifact is interchangeable and will be used for prod promotion |
| Dispatch log shows "label derivation changed since the push build" | The label-derivation logic in the workflow was edited between the push and the dispatch. The pipeline deploys the binary under the label it was actually stamped with (the stamp is compiled in); push a new commit if you want the new derivation |
| Prod rollback dispatch fails: "Artifact for v… has expired" | The stg-tested artifact for that release is beyond its 90-day window. Re-dispatch the release pipeline from the release branch (`gh workflow run on-release.yml --ref release/X.Y.Z`) to rebuild the artifact, then retry the rollback dispatch |

## Repository settings the pipeline depends on

These live in GitHub settings, not in the workflow files — if the repo is ever recreated or transferred, they must be reconfigured:

| Setting | Where | Value |
|---|---|---|
| Rulesets `develop` / `main` / `release` | Settings → Rules | PR required; **build / Build & Test** status check required; `main` allows merge commits only; `main` source branches must include `support/*` |
| Workflow permissions | Settings → Actions → General | Default token: **read-only**; **Allow GitHub Actions to create and approve pull requests: on** (the back-merge and backport PRs need it) |
| Repo variables | Settings → Secrets and variables → Actions | `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (used by `_deploy.yml`; not secrets) |
| Environment variables | Settings → Environments → (each env) → Environment variables | `AZURE_CLIENT_ID`, `WEBAPP_NAME` per environment — `_deploy.yml` reads them via the job's `environment:` scope, so entry workflows carry no per-env config |
| Environments | Settings → Environments | `dev`, `stg`, `prod` — each matched by a federated credential on its deploy identity |

There are deliberately **no repository secrets** — Azure auth is OIDC workload identity federation (see `docs/workload-identity-federation.md`).

## Infrastructure changes

All Azure resources (App Services, VNets, Key Vaults, App Gateway, deploy identities) are Terraform-managed in a separate infrastructure repository — change infrastructure there via plan/apply, never in the Azure Portal. This repo contains no IaC; the resources the pipeline requires are listed in [getting-started — Step 2](getting-started.md#step-2--provision-azure-resources).
