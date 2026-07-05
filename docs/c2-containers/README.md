# C2 — Containers

Zooming into the system boundary: the separately deployable / runnable / configurable units ("containers" in C4 terms — not Docker containers) and how they communicate. A container is something that runs as its own process or is deployed independently.

← [C1 — Context](../c1-context/README.md) · [Architecture overview](../ARCHITECTURE.md) · Next: [C3 — Components](../c3-components/README.md)

## Diagram

```mermaid
graph TB
    consumer([API Consumer])
    developer([Developer])
    operator([Operator])

    subgraph system [cicd-demo system]
        subgraph delivery [Delivery plane «GitHub»]
            repo[Source Repository<br/>«git»<br/>App code + workflow definitions]
            ci[CI/CD Pipeline<br/>«GitHub Actions»<br/>Build, test, deploy, promote]
            artifacts[(Build Artifact Store<br/>«Actions artifacts»<br/>webapp-publish / webapp-&lt;sha&gt;)]
        end

        subgraph runtime [Runtime plane «Azure»]
            gateway[Application Gateway<br/>«shared»<br/>One frontend port per env]
            appdev[API — dev<br/>«App Service B1»]
            appstg[API — stg<br/>«App Service B1»]
            appprod[API — prod<br/>«App Service P0v3»<br/>production + staging slots]
        end
    end

    developer -->|push / PR| repo
    operator -->|dispatch / merge| ci
    repo -->|triggers| ci
    ci -->|uploads / downloads| artifacts
    ci -->|OIDC deploy| appdev
    ci -->|OIDC deploy| appstg
    ci -->|OIDC deploy → slot → swap| appprod
    consumer -->|HTTPS| gateway
    gateway --> appdev
    gateway --> appstg
    gateway --> appprod
```

The system splits into two **planes**: a **delivery plane** (how code becomes a running deployment) and a **runtime plane** (what actually serves traffic). Most of the architecture's substance is in the delivery plane.

## Containers

### Delivery plane (GitHub)

| Container | Technology | Responsibility |
|---|---|---|
| **Source Repository** | Git on GitHub | Holds the application code, tests, and the workflow definitions that *are* the pipeline. Branch rulesets enforce PR-only merges and required checks — the quality gate lives here. |
| **CI/CD Pipeline** | GitHub Actions (three reusable + six entry workflows) | Builds, tests, publishes, deploys, promotes, tags, releases, and back-merges. Mechanisms live in the reusable workflows (`_build`, `_deploy`, and `_hotfix-support` — a shared prepare→build→deploy for the hotfix/support flows); branch policy lives in the entry workflows. Decomposed in [C3](../c3-components/README.md). |
| **Build Artifact Store** | GitHub Actions artifacts | Holds compiled publish output. Two naming schemes: `webapp-publish` (ephemeral, 1-day) for throwaway builds, and `webapp-<sha>` (90-day) for promotable release candidates. **This store is what makes "build once, promote many" possible** — prod pulls the exact bytes stg tested. |

### Runtime plane (Azure)

| Container | Technology | Responsibility |
|---|---|---|
| **Application Gateway** | Azure App Gateway (shared) | Single internet entry point fronting all three environments, one frontend port each (prod :80, dev :8081, stg :8082). Its health probe targets `/healthz`. |
| **API — dev / stg** | Azure App Service (B1 Linux) | Runs the published API. One App Service per environment, in its own resource group. |
| **API — prod** | Azure App Service (P0v3, with slots) | Same API, but on a plan that supports deployment **slots** — a `staging` slot and a `production` slot — enabling blue/green deploys and instant rollback. |

The **API application itself is a single container** — one self-hosted Kestrel process per App Service. Its internal structure is the subject of [C3](../c3-components/README.md).

## Communication

| From → To | Protocol | Notes |
|---|---|---|
| Consumer → Application Gateway | HTTPS/HTTP | Public traffic. |
| Gateway → App Service | HTTP (over Azure VNet) | Per-environment backend; health-probed on `/healthz`. |
| Pipeline → App Service | Azure REST (via `azure/webapps-deploy`, `az`) | Authenticated by short-lived OIDC token, not a stored secret. |
| Pipeline → Artifact Store | Actions artifact up/download (REST for cross-run) | Cross-run download (promotion) needs `actions: read`. |
| Repository → Pipeline | GitHub event triggers | Push, PR, and `workflow_dispatch`. |

## Deployment topology per environment

Each environment is a self-contained stamp: its own resource group `<env>-demo-helloworld-rg`, its own VNet, its own App Service `<env>-demo-helloworld-api`, its own Key Vault, and its own deploy identity (an App Registration scoped to *only* that resource group). The one shared resource is the Application Gateway, which multiplexes the three by frontend port.

```mermaid
graph LR
    subgraph dev-rg [dev-demo-helloworld-rg]
        d[App Service dev]
        dkv[Key Vault]
    end
    subgraph stg-rg [stg-demo-helloworld-rg]
        s[App Service stg]
        skv[Key Vault]
    end
    subgraph prod-rg [prod-demo-helloworld-rg]
        p[App Service prod + slots]
        pkv[Key Vault]
    end
    agw[Shared Application Gateway<br/>:8081 dev · :8082 stg · :80 prod]
    agw --> d & s & p
```

## Key decisions at this level

- **Delivery plane and runtime plane are separate systems, federated by OIDC.** GitHub compute never holds an Azure credential; it presents a signed identity token that Azure's per-environment trust configuration accepts. Removes the single largest class of CI secrets.
- **The artifact store is a first-class container, not an implementation detail.** Making the compiled binary a durable, addressable object (keyed by commit SHA, retained 90 days) is what lets prod promote the *exact* stg-tested bytes instead of rebuilding from source. Rebuilding would reintroduce the risk the whole verification chain exists to remove.
- **Prod is the only environment with slots.** Blue/green is bought at the cost of a pricier plan (P0v3 vs B1). dev/stg roll back by re-running a workflow; prod rolls back by a near-instant slot swap. The cost is spent only where user-facing downtime matters.
- **One shared gateway, isolated backends.** A single gateway keeps infra cost down and gives one public surface, while separate resource groups + scoped identities keep the environments' blast radius independent.
