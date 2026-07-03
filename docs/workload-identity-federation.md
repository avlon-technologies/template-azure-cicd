# How GitHub Deploys to Azure Without a Password

This repo's pipelines deploy to Azure App Service without any stored secret — no password, no key, no certificate. This document explains how that works. The pattern is called **workload identity federation** (you'll also see it called "GitHub OIDC").

## The problem with passwords

The traditional way to let a pipeline deploy is to create a machine account in Azure, give it a password (a "client secret"), and store that password in GitHub as a secret. It works, but the password is a permanent liability:

- Anyone who obtains it — from a leaked log, an old laptop, a compromised dependency — can use it **from anywhere, for months**, until someone notices.
- It expires, so deploys break until someone rotates it.
- You have to trust every person and tool that can read your repo secrets.

## The idea: a passport instead of a key

Workload identity federation replaces the shared password with a simple observation: **GitHub already knows exactly what is running**. It knows the repo, the branch, the commit, the workflow file, and the environment of every job it executes. So instead of the pipeline *holding a key*, GitHub *vouches for the pipeline* — like a passport office issuing a passport.

The flow, in plain English:

1. **The deploy job asks GitHub for proof of identity.** GitHub writes a short note (a token) saying, in effect: *"This is the `cicd-demo` repo, deploying to the `prod` environment, right now."* GitHub signs the note with a private key that never leaves GitHub, making it impossible to forge.

2. **The job takes the note to Azure** and says: "log me in as this identity" (the client ID in the workflow file — more on why that's safe below).

3. **Azure checks the note.** It verifies the signature using GitHub's published public keys (so it knows GitHub really wrote it), checks that it hasn't expired (the note is valid for about 5 minutes), and compares it against a **trust rule we configured in advance**: *"accept notes from GitHub that say exactly `repo:pixelbits-mk/cicd-demo:environment:prod` — and nothing else."*

4. **Azure hands back a temporary badge** — its own short-lived access token. That badge is what actually performs the deployment, and it only permits what the identity's role allows (deploying web apps in that one environment's resource group).

```
  GitHub OIDC provider          Entra ID (Azure AD)             Azure
        |                              |                          |
 1. signs ID token  ───►  2. job sends token + client ID  ───►   |
    "repo X, env prod"         3. verify signature,               |
                                  check trust rule                |
                               4. issue access token  ───►  5. deploy app
```

## Where each piece lives

| Piece | What it is | Where |
|---|---|---|
| Token request | Job asks GitHub for an ID token | `permissions: id-token: write` in the caller workflows |
| Token subject | Which environment the token names | `environment: <env>` on the deploy job in `_deploy.yml` |
| Identity | The machine account the job logs in as | App registrations `demo-helloworld-github-deploy-{dev,stg,prod}` in Entra ID |
| Trust rule | Which GitHub tokens Azure accepts | A *federated credential* on each app registration, matching one repo + environment |
| Permissions | What the identity may do | RBAC role (Website Contributor) scoped to that environment's resource group |
| Pointers | Which identity/tenant/subscription to use | `azure-client-id` input + `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` repo variables |

Each environment has its **own** identity, and each identity can only touch its own resource group — a dev deploy physically cannot modify prod.

## Why there's nothing secret in the YAML

The workflow files contain a client ID, tenant ID, and subscription ID in plain text. None of these are credentials — they're addresses, like knowing a company's street address. Knowing them doesn't get you past security, because Azure only accepts the *signed GitHub token*, and:

- **You can't steal it** — it isn't stored anywhere; it's minted fresh per deploy and dies ~5 minutes later. (GitHub even auto-masks it if it appears in logs.)
- **You can't forge it** — only GitHub holds the signing key.
- **You can't borrow it** — a token from a fork, another repo, another branch, or outside the declared GitHub environment has a different subject and fails the trust rule.
- **You can't overreach with it** — even a valid login is limited by the role to one resource group.

## Seeing it yourself

Run the **"Show OIDC Token Claims"** workflow (Actions → Show OIDC Token Claims → Run workflow). It prints the decoded contents of a real GitHub ID token and uploads the raw token as an artifact you can paste into [jwt.io](https://jwt.io). (That token is requested with a dummy audience, so it can't be used against Azure.)

## Jargon decoder

| Term | Plain English |
|---|---|
| Workload identity federation | The whole pattern: one system vouches for its workloads so another system doesn't need stored passwords |
| OIDC (OpenID Connect) | The standard for "signed notes about identity" |
| ID token / JWT | The signed note itself |
| Claims | The individual facts inside the note (repo, environment, expiry…) |
| Subject (`sub`) | The main "who this is" claim — what the trust rule matches |
| Issuer (`iss`) | Who signed the note (GitHub) |
| Audience (`aud`) | Who the note is intended for (Azure's token exchange) |
| App registration | The machine account in Azure the pipeline logs in as |
| Federated credential | The trust rule attached to that account |
| Access token | The temporary badge Azure issues after accepting the note |
