# Operations Manual

How to build, deploy, release, and verify this application across environments.

## Environments at a glance

| Environment | App Service | Direct URL | Via shared gateway | Deployed by |
|---|---|---|---|---|
| dev | `dev-demo-helloworld-api` | https://dev-demo-helloworld-api.azurewebsites.net | http://52.139.34.97:8081/ | push to `develop` (automatic) |
| stg | `stg-demo-helloworld-api` | https://stg-demo-helloworld-api.azurewebsites.net | http://52.139.34.97:8082/ | manual dispatch of a release, or push to `hotfix/**` |
| prod | `prod-demo-helloworld-api` | https://prod-demo-helloworld-api.azurewebsites.net | http://52.139.34.97/ | merge PR to `main` (automatic) |

All merges to `develop` and `main` must go through a pull request (enforced by repository rulesets).

## Deploy to dev (automatic)

Merging a PR to `develop` (or any push to it) triggers **CI/CD — Develop → DEV**: build → test → deploy to dev. No manual steps.

```
gh pr create --base develop --head my-feature
gh pr merge --merge
```

The build is labeled `YYYYMMDD.<run_number>` and the deployed commit is tagged `build/dev/<label>`.

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

## Deploy to production

When a candidate is accepted, merge the release branch to `main` via PR:

```
gh pr create --base main --head release/1.1.0 --title "Release 1.1.0"
gh pr merge --merge        # merge commit — do NOT squash (see note)
```

Merging triggers **CI/CD — Main → PROD**, which automatically:

1. Extracts `1.1.0` from the merge commit subject
2. Builds with that version (stamped into the assembly's `InformationalVersion`)
3. Deploys to prod and tags the commit `build/prod/1.1.0`
4. Creates GitHub Release **v1.1.0** with generated notes

> **Always use a merge commit for release PRs.** The version is read from the merge commit subject ("Merge pull request #N from …/release/1.1.0"). A squash merge hides the branch name, so the build falls back to a date label and no GitHub Release is created. Squash also breaks the back-merge below.

5. Opens a **back-merge PR** from the release branch into `develop`, so stabilization fixes aren't lost

The back-merge PR is created automatically but merged manually — review it (conflicts with ongoing develop work are possible), merge with a merge commit, then delete the release branch:

```
gh pr merge <back-merge-pr> --merge
git push origin --delete release/1.1.0
```

(If nothing landed on the release branch after it was cut, the PR will show no diff or won't be created — just delete the branch.)

## Hotfix production

For urgent fixes that can't wait for a release cycle:

```
git checkout main && git pull
git checkout -b hotfix/1.1.1
# fix, commit
git push -u origin hotfix/1.1.1
```

Every push to `hotfix/**` auto-deploys to **stg** for verification. When verified, PR `hotfix/1.1.1 → main` (merge commit) — note the auto-versioning only recognizes `release/X.Y.Z` merges, so a hotfix prod deploy gets a date label; tag `v1.1.1` manually if desired:

```
gh release create v1.1.1 --target main --generate-notes
```

Back-merge the hotfix to `develop` afterward, same as a release.

## Verify a deployment

- **Endpoints** — hit the URL from the table above; the API returns `Hello World!` at `/`.
- **Deployments view** — repo home → right sidebar → **Deployments** (or `/deployments`): per-environment history.
- **Tags** — `git fetch --tags && git tag -l 'build/*'`: every successful deploy tags the exact commit as `build/<env>/<label>`.
- **Releases** — repo **Releases** page lists `vX.Y.Z` with generated notes.

## Version and branch naming

| Thing | Convention | Example |
|---|---|---|
| Release branch | bare version | `release/1.1.0` |
| Candidate label (dispatch input / stg tag) | SemVer pre-release | `1.1.0-rc.2` |
| Release tag (automatic on prod deploy) | `v` + version | `v1.1.0` |
| Hotfix branch | bare patch version | `hotfix/1.1.1` |

The rc number identifies a *candidate build*; the branch identifies the *line of development* — so rc numbers never appear in branch names.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Run fails instantly with `startup_failure` and no logs | A caller job is missing the `permissions:` block (`id-token: write`, `contents: write`) that `_deploy.yml` requires — the repo default token is read-only and called workflows can't elevate it |
| Deploy fails: "Resource … doesn't exist" | The target App Service hasn't been provisioned — run `terraform apply` for that environment in `../cicd-infrastructure` |
| Deploy fails at "Login to Azure" | Federated credential / identity problem — see `docs/workload-identity-federation.md` |
| Push to `develop`/`main` rejected (GH013) | Rulesets require a PR — open one instead of pushing directly |
| Release merged but prod tag is a date, no GitHub Release | The PR was squash-merged; the version is only detected on merge commits |

## Infrastructure changes

All Azure resources (App Services, VNets, Key Vaults, App Gateway, deploy identities) are Terraform-managed in the separate **cicd-infrastructure** repo — change infrastructure there via plan/apply, never in the Azure Portal. See that repo's README for usage.
