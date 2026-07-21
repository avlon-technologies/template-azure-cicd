# Security

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub's **Security → Report a vulnerability** (private vulnerability reporting) on this repository, rather than opening a public issue. Include reproduction steps and the affected file or workflow.

This is a template/reference repository maintained on a best-effort basis; there is no formal SLA for security responses.

## Security model

The template is designed so that adopting it does not require storing cloud credentials:

- **No repository secrets.** Azure authentication uses OIDC [workload identity federation](docs/workload-identity-federation.md): GitHub mints a short-lived, job-scoped JWT; Entra ID validates it against a per-environment federated credential. There is no client secret to leak or rotate.
- **Per-environment blast radius.** Each environment has its own deploy identity holding Website Contributor scoped to only its resource group. Compromising the dev deploy path grants nothing in prod.
- **Least-privilege tokens.** The default `GITHUB_TOKEN` is read-only; jobs declare the minimal permissions they need.
- **Pinned supply chain.** All GitHub Actions are pinned to full commit SHAs (with version comments) and kept current by Dependabot.
- **Injection-safe workflows.** Untrusted inputs (dispatch inputs, commit messages, branch names) reach scripts via environment variables, never by direct interpolation; version labels are restricted to a safe charset because they become artifact names and git tags.
- **Immutable audit trail.** `build/<env>/<label>` tags are create-or-verify — the pipeline fails rather than moving a tag, so the record of what was tested and shipped can't be silently rewritten.

## Known trade-offs to review when adopting

- **Swagger UI and the OpenAPI document are exposed in all environments, including prod.** Deliberate for this no-sensitive-surface demo; reconsider for a real API (note the deploy smoke test reads `/openapi/v1.json` — see [customization](docs/customization.md#3-the-smoke-test-contract)).
- The sample app has **no authentication or rate limiting** — it is a pipeline demo, not an API security reference.
- Values like client IDs, tenant IDs, and subscription IDs appear in workflow *variables* by design; they are identifiers, not credentials ([why this is safe](docs/workload-identity-federation.md#why-the-workflow-files-contain-no-secrets)).
- **`DEPLOY_ALERT_WEBHOOK` is stored as a variable, not a secret — an accepted risk.** A chat webhook URL is a low-value capability: possession allows posting messages to one channel, nothing more, and that is its full blast radius. Keeping it a variable preserves the repo's no-secrets model and the simple `vars`-based opt-in in `_deploy.yml`. If your webhook's exposure matters more than that (e.g. it posts to a sensitive channel), convert it to an Actions secret instead — that requires declaring it under `workflow_call.secrets` in `_deploy.yml` and passing it (or `secrets: inherit`) from each entry workflow, and updating the "no repository secrets" wording in these docs to "no cloud-credential secrets".
