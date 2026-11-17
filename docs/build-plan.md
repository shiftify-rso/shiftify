# Build plan

**Status:** proposal, for the team to agree.

**Approach: walking skeleton first.** Build one thin slice that goes through every layer (edge, BFF, a service, its DB, outbox → Kafka, a consumer, GitOps deploy), then widen. Integration risks surface in week one, not at the end.

## Phase 0 — Foundations (`infra`)
- **Local cluster:**
  - kind + Tilt, with Tilt **profiles** so each dev runs only the slice they work on
  - set a memory budget, since the full stack is about 12–16 GB
- **Operators, single replica locally:** CloudNativePG, Strimzi (one Kafka broker + Kafka Connect with Debezium), Keycloak, Apicurio, RabbitMQ.
- **Edge:** Envoy Gateway with a JWT policy against Keycloak.
- **AKS:** an OpenTofu module for the AKS cluster plus Argo CD bootstrap. Create it only for demos, and destroy it after.
- **CI:** a skeleton workflow (build + test) that later gets copied into every repo.
- **Decide** the service golden path: template repo or convention plugin.

## Phase 1 — Walking skeleton
| Component | Slice |
|---|---|
| `staff` | Employee CRUD; outbox → Debezium → `employee.created` |
| `auth` | Consume `employee.created` → create the Keycloak user; map claims |
| `bff` | GraphQL `employees` query + `createEmployee` mutation, JWT-checked |
| `web` | Keycloak login; list and create employees |

**Done when:** an admin logs in on kind, creates an employee, and that employee can log in. The same commit is deployed to AKS via Argo CD.

**What this proves:** gateway + JWT, DB per service, outbox/CDC, Kafka + Apicurio, GraphQL, GitOps.

## Phase 2 — Core scheduling
- `rules`: rule CRUD + validate (start with `max_hours_per_week`, `min_rest_between_shifts`, `required_skills`, `min_seniority_count`).
- `schedule`: drafts, shifts, assignments, live validation, publish.
- `availability`: availability + time off.
- `notification`: in-app + Mailpit on `schedule.published`.
- `web`: week grid + my schedule views.

## Phase 3 — Showcase features
- `autoscheduler`: RabbitMQ jobs, Timefold, proposals, KEDA scale-to-0.
- `swap`: eligibility, state machine, delayed-message expiry.
- The remaining rule types; timeline + coverage views; saved views; GraphQL subscriptions.

## Phase 4 — Hardening & demo
- NetworkPolicies, the full CI gates (scans, SBOM, signing), and Grafana dashboards + SLOs.
- Playwright runs the SPEC §15 demo scenario; a k6 load test shows scaling.
- Update the prijava/report diagrams to match the final architecture.

## Open for the team
- **Course milestones and deadlines:** these set the dates for each phase.
- **Ownership:** who leads which components; e.g. one person per phase-1 pair plus `infra`.
- **Dev machines:** how much RAM each has, to set the local memory budget.
