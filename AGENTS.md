# AGENTS.md

Rules for AI coding agents working on Shiftify. Read this and [`docs/SPEC.md`](docs/SPEC.md) before doing anything.

## Layout
```
shiftify/                     main repo (this one): docs and submodules
├── AGENTS.md, CLAUDE.md      agent rules (CLAUDE.md just imports this file)
├── docs/
│   ├── SPEC.md               general spec: binding
│   ├── service-spec-template.md
│   ├── microservices-guide.md   lecture best practices; the defaults behind the SPEC
│   └── archive/              superseded docs; never use them as a source
├── scripts/setup.sh          workspace bootstrap
├── services/{staff,auth,notification,schedule,rules,availability,swap,autoscheduler}
├── bff/  web/  infra/        submodules
└── prijava/, navodila.md     local-only course files; gitignored, never commit or publish
```
- **Every submodule is a separate repo** under `github.com/shiftify-rso`, with its own `SPEC.md`, contracts (`contracts/`: OpenAPI, AsyncAPI, proto, GraphQL), Helm chart and CI.
- **Git commands for a component run inside its folder.** The root repo only tracks submodule pointers, and those are bumped at release time only (README → Releases).

## Roles
The developer works from the root. One **orchestrator** agent holds the project context, and **workers** implement single components.

**Orchestrator** (the agent started in the root):
- Reads `docs/SPEC.md` and the relevant service specs, then plans the work and splits it per component.
- Delegates each component's work to a worker, with precise scope: repo folder, task, spec sections, and the contracts the worker may rely on.
- **Owns all communication with the developer.** It collects open questions from workers and asks them in batches (see Asking).
- Coordinates cross-service changes. Contract changes are agreed first, and the producer is changed before its consumers.
- Reviews worker results against the specs before reporting back.

**Worker:**
- Works **only inside its assigned component folder**. It reads other repos only to understand contracts it consumes.
- Reads the component's `SPEC.md` and the referenced general SPEC sections first.
- **Never guesses on a choice** that falls under the ask policy. It stops, or keeps going on the unblocked parts, and returns the question with options and a recommendation to the orchestrator.
- Ends with a short report: what changed, which tests ran and their results, any spec updates, and open questions.

## Asking the developer
Ask before deciding on any of these:
1. **Technology and libraries:** a new dependency, framework feature, tool or infrastructure component.
2. **Spec-level decisions:** resolving an `[O-n]`, deviating from a decided SPEC item, or changing a contract (API, event, schema).
3. **Design forks:** two or more reasonable approaches (data model shape, sync vs async, error handling, validation placement).
4. **Anything outward-facing:** pushing, opening or merging PRs, tagging, repo or org settings, Azure resources, deleting anything.

How to ask:
- Give 2–4 concrete options, with a **recommended** one first, plus "leave open" where it fits. Batch related questions together.
- If the developer may not know a technology, explain **what it actually does** in plain terms (what problem it solves and how it works here), not buzzwords. Then ask.
- When the developer asks a question back, answer it before moving on.
- Only trivial choices need no question: local naming, formatting, test structure.

## Specs
- **`docs/SPEC.md` is binding.** Everything not tagged `[O-n]` is decided. Its terminology applies: it's *department*, never "sector".
- **An `[O-n]` gets resolved** by asking (above), then recording the result in that service's `SPEC.md` table "Resolved open decisions": the ID, the choice and a one-line reason.
- **Changing a decided item** requires the developer's agreement and a PR to `docs/SPEC.md` first. Code must never silently contradict the spec.
- **Spec and code change together:** update the service `SPEC.md` (and its contracts) in the same PR as the code.
- **New service specs** start from `docs/service-spec-template.md`.
- **Spec and doc style:** slim, core features first. No architecture essays unless asked. Record decisions, not narratives.

## Git
- **Branches:** only `main` lives long-term. Use short-lived branches named after the task (`staff-crud`).
- **`main` is protected in all 12 repos:** every change goes through a PR, squash merge only, linear history, and no force-push or deletion. Never try to bypass this.
- **Commit messages and PR titles:** short, lowercase, imperative, no articles or filler, e.g. `add employee crud endpoints`. **No `Co-Authored-By` or any other trailer.** The PR title becomes the squash commit, so write it in the same style; the PR body can be short or empty.
- **Pulls rebase** (`pull.rebase=true`). Never create merge commits by hand.
- **Never commit** secrets, `.env` files, `prijava/` or `navodila.md`. Secrets go into Sealed Secrets in `infra`.

## CI
**Current state:** there are no CI workflows yet. The rulesets require PRs, and CI checks become required as each repo gets CI. Adding a check to a repo's ruleset is outward-facing, so ask first.

**Target per repo** (SPEC §12):

| When | Steps |
|---|---|
| On a PR | build, unit tests + Testcontainers integration tests, contract checks (oasdiff, Apicurio compatibility; Pact where useful), static analysis (SonarQube Cloud / CodeQL) |
| On `main` and `vX.Y.Z` tags | build image, Trivy scan, Syft SBOM, cosign sign, push to GHCR (tag = git SHA; plus the version on tags) |
| Deploy | never from CI. Open a PR to `infra` bumping the image version, and Argo CD syncs it |

**Workflow rules:**
- Pin every action to a full commit SHA, with the version in a comment.
- Use least-privilege `permissions:` (`contents: read` by default) and OIDC instead of stored cloud credentials.
- No workflow may create or approve PRs, and none may use `pull_request_target` with untrusted code.
- Dependabot keeps dependencies and actions updated.

## Stack quick reference
This is a summary; [SPEC §12](docs/SPEC.md) is authoritative.
- **Backend:** Java 25, Spring Boot, Gradle Kotlin DSL. The BFF uses Spring for GraphQL. The web app is SvelteKit with shadcn-svelte and Tailwind.
- **Messaging:** Kafka for events (JSON Schema in Apicurio, transactional outbox + Debezium) and RabbitMQ for tasks.
- **Data and identity:** PostgreSQL on CloudNativePG, one database per service. Keycloak for identity, Envoy Gateway at the edge.
- **Infrastructure:** AKS (one demo env) and kind + Tilt locally; OpenTofu, Helm and Argo CD; Sealed Secrets.
- **Conventions:** REST with `/v1`, problem+json errors and intent endpoints. Every entity and event carries `org_id`.
