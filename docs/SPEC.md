# Shiftify — General Spec

Shift scheduling for small organizations. RSO 2026/27, group 8 (Shifters).

## 0. How to use this spec
- Everything here is **decided** unless it is tagged **[O-n]**. A tag marks an open decision, collected in §14.
- Each component lives in its own repo with its own `SPEC.md` (from [service-spec-template.md](service-spec-template.md)) and its own contracts. A service spec:
  - resolves the `O-n` items it owns
  - may add detail
  - may **not** contradict a decided item. To change a decided item, edit this spec first.
- Services are built to be **reusable by other apps** (see the tiers in §10).
- Design background and defaults: [microservices-guide.md](microservices-guide.md).

---

## 1. Scope
Shiftify serves small organizations: ≤50 employees, one location, a few departments. The domain is generic, and industry-specific behaviour comes only from configurable rules.

**In scope:** departments, positions, skills and employees · schedule editing and publishing · views · availability and time off · coverage requests and swaps · auto-scheduler · notifications.

**Out of scope:** time & attendance · payroll · reports · calendar sync · external integrations · i18n.

**Tenancy:** single tenant, **tenant-ready**. Every entity, event and JWT carries `org_id`, so adding tenants later needs no schema change.

**Roles**
| Role | Can |
|---|---|
| Admin | Manage departments, positions, skills, employees, rules |
| Manager | Edit and publish schedules for their departments; approve time off and swaps; run the auto-scheduler |
| Employee | View published schedules; set availability; request time off, coverage and swaps |

---

## 2. Domain model (conceptual)
Fields are the required concepts. Types and storage are decided per service [O-db]. All entities carry `org_id`.

| Entity | Key fields | Owner |
|---|---|---|
| **Department** | name, color | `staff` |
| **Skill** | name | `staff` |
| **Position** | department_id, name, required_skill_ids[] | `staff` |
| **Employee** | name, email, role, seniority (`intern`/`junior`/`mid`/`senior`), skill_ids[], department_ids[], contract_hours_per_week | `staff` |
| **Identity** | Keycloak user ↔ employee_id | `auth` |
| **ShiftTemplate** | department_id, name, start_time, end_time, days_of_week[], slots[] | `schedule` |
| **Shift** | department_id, start, end, slots[]: { position_id, count } | `schedule` |
| **Assignment** | shift_id, position_id, employee_id, locked | `schedule` |
| **Schedule** | department_ids[], period_start, period_end, status (`draft`/`published`), version, published_at | `schedule` |
| **OverrideLog** | schedule_id, version, manager_id, violations[] | `schedule` |
| **Rule** | type, scope (`global` or department_id), hard, weight, params | `rules` |
| **Availability** | employee_id, kind (`unavailable`/`prefer_not`/`prefer`), recurring (day_of_week + time range) or date range | `availability` |
| **TimeOffRequest** | employee_id, start, end, reason, status (`pending`/`approved`/`rejected`) | `availability` |
| **SwapRequest** | type (`coverage`/`swap`), requester assignment, counterpart assignment?, accepted_by?, status (§6) | `swap` |
| **SolverJob / Proposal** | input snapshot, status, proposals[] (§8) | `autoscheduler` |
| **Notification** | recipient employee_id, type, payload, read | `notification` |
| **SavedView** | owner_id, name, config (§7) | `bff` |

**Time handling**
- There is one org time zone.
- A shift may cross midnight.
- Durations are computed from actual timestamps, so DST nights are correct.

---

## 3. Rules & validation
Rules are data, not code. Each rule has a `type` with typed `params`:
- A department-scoped rule overrides a global rule of the same type.
- Every rule is **hard** (must hold) or **soft** (a violation costs `weight`).

| Type | Params | Semantics |
|---|---|---|
| `max_hours_per_day` | `hours` | Sum of an employee's shift hours **starting** on a calendar day ≤ `hours` |
| `max_hours_per_week` | `hours` | Sum of shift hours starting in a Mon–Sun week ≤ `hours`, across all departments |
| `min_rest_between_shifts` | `hours` | Gap between the end of one shift and the start of the next ≥ `hours` |
| `max_consecutive_days` | `days` | Consecutive calendar days with ≥1 shift ≤ `days` |
| `min_seniority_count` | `level`, `count` | Each shift has ≥ `count` assignees with seniority ≥ `level` |
| `max_seniority_count` | `level`, `count` | Each shift has ≤ `count` assignees with seniority ≤ `level` |
| `required_skills` | — | The assignee has all of the position's required skills (always hard) |
| `respect_unavailability` | — | No overlap with `unavailable` or approved time off (always hard) |
| `respect_preferences` | — | Penalty for overlapping `prefer_not`, bonus for `prefer` (soft) |
| `contract_hours_target` | `tolerance_hours` | Penalty per hour outside contract ± tolerance (soft) |
| `fair_distribution` | `kind` (`night`/`weekend`) | Penalty for the max–min spread of night or weekend shifts (soft) |

- A **night shift** overlaps 22:00–06:00.
- A **weekend shift** starts on Saturday or Sunday.

**Validation.** `rules` offers a single validate operation:
- **Input:** the caller sends the assignment set to evaluate, i.e. the period's assignments with the proposed change applied.
- **Rules' own inputs:** `rules` gets employee attributes and absences itself (§11).
- **Output:** a list of violations:

```
{ rule_id, hard, employee_id?, shift_id?, message }   e.g. "Ana: 46h in week 45 exceeds 40h"
```

- **Callers:** live editing (§4), swap eligibility (§6) and solver result reporting (§8).
- **Rule changes:** a change emits `rule.changed`. `schedule` then re-validates open drafts, and published schedules are not touched.

---

## 4. Schedule editing & publishing
**Drafts**
- A manager creates a draft for a period and departments, either empty, from templates, or from an auto-scheduler proposal.
- Shifts and assignments can be created, moved and deleted, and assignments can be locked.

**Validation**
- **Every change is validated.** Hard violations show as errors, soft ones as warnings.
- Publishing with violations requires an explicit override, which is logged in `OverrideLog`.

**Publishing**
- **Publish:** `status = published`, `version + 1`, the schedule becomes visible to employees, and `schedule.published` is emitted.
- **Editing a published schedule:** the change applies immediately, the version bumps, and `schedule.changed` is emitted with the affected employee IDs.
- Employees never see drafts.

---

## 5. Availability & time off
- Employees set availability as recurring (weekday + time range) or as a date range, with kind `unavailable`, `prefer_not` or `prefer`.
- Time-off requests go `pending → approved | rejected` by a manager of the employee's department.
- `unavailable` and approved time off are hard constraints. `prefer_not` and `prefer` are soft (§3).

---

## 6. Coverage & swaps
**Request types**
- **Coverage:** give away my assignment.
- **Swap:** exchange my assignment for a coworker's.

**State machine**
```
open ──(coworker accepts)──► accepted ──(manager approves)──► applied
  │                             └──(manager rejects)──► rejected
  ├──(requester cancels)──► cancelled
  └──(shift starts)──► expired
```

**Eligibility.** A coworker sees a request only if both hold:
1. They are in the shift's department and have the position's required skills.
2. Validation shows **no hard violations** after the change (for a swap, on both sides).

**Approval.** On approval, eligibility is re-validated. If it still holds, `swap` asks `schedule` to apply the change, the version bumps, and both employees are notified.

**Expiry.** When a request is created, `swap` schedules a **RabbitMQ delayed message** for the shift start. If the request is still `open` when the message arrives, it becomes `expired`.

---

## 7. Views
Employees see **published** schedules. Managers see drafts and published schedules.

| View | Description |
|---|---|
| **Week grid** | Days as columns, shifts as cards, grouped by department |
| **Timeline** | One row per employee (or position), time on the x-axis; overlaps and gaps visible |
| **My schedule** | The current employee's upcoming shifts, as a list or calendar, mobile-friendly |
| **Coverage** | Required vs assigned headcount per shift or hour; under- and over-staffing highlighted |

A view config can be saved as a `SavedView`, which the **BFF** stores (it is Shiftify UI config, not scheduling data):

```json
{
  "type": "timeline", "range": "week", "department_ids": [],
  "group_by": "employee | position | department",
  "color_by": "department | seniority | position",
  "filters": { "seniority": [], "skill_ids": [], "employee_ids": [] }
}
```

---

## 8. Auto-scheduler
The manager picks a period and departments, and the auto-scheduler proposes who works which shift. The solver is **Timefold Solver**. The model details are [O-solver].

**Input**
- shifts with slots
- employees
- availability and approved time off
- the effective rules
- locked assignments
- `num_proposals` (default 3, max 5)

**Requirements**
- **Never "infeasible":** unfilled slots are allowed, at a very large penalty.
- **Rules:** hard rules are constraints, and soft rules are weighted penalties.
- **Locked assignments** appear in every proposal.
- **Distinct proposals:** each differs from the others in ≥10% of assignments.

**Output, per proposal**
- assignments
- total score and per-rule penalty breakdown
- soft violations
- unfilled slots, each with a reason, e.g. "Sat 22:00 Kitchen: needs 1 senior, 0 eligible (Marko on time off, Ana exceeds 40h)"

**Running a job**
- A job is created with `POST` → `202` plus a job resource. It goes `queued → running → done | failed`, with a 30s solve limit.
- Jobs are tasks on a **RabbitMQ** queue that workers pull. `solver.job.completed` or `solver.job.failed` is emitted at the end.
- The manager compares proposals side by side, applies one to a draft through `schedule`, then edits it.

---

## 9. Notifications
- In-app notifications are stored by `notification` and pushed live to the browser through the BFF's GraphQL subscriptions.
- Email goes via **Mailpit** in all environments [O-mail].

**`notification` is generic:**
- Configuration, not code, says which event types it handles, which template each uses, and which payload field holds the recipients.
- Producers therefore include recipient `employee_id`s in their events.

| Event | Recipients |
|---|---|
| Schedule published | Everyone in the schedule |
| Schedule changed after publishing | The affected employees |
| Coverage/swap requested | Eligible coworkers |
| Swap accepted, applied, rejected or expired | The participants |
| Time off approved or rejected | The requester |
| Solver job completed or failed | The manager who started it |

---

## 10. Components & ownership

**Reuse tiers**
- **Generic** (know nothing about shifts): `auth`, `notification`, `staff`.
- **Scheduling-generic** (usable by any shift-scheduling app): `schedule`, `rules`, `availability`, `swap`, `autoscheduler`.
- **Shiftify-specific** (all app glue lives here): `bff`, `web`.

| Component | Tier | Responsibility | Owns (single writer) |
|---|---|---|---|
| `staff` | generic | People directory: departments, positions, skills, employees | Department, Position, Skill, Employee |
| `auth` | generic | Keycloak + a thin adapter. It consumes `employee.*` / `department.*`, creates the Keycloak user (invite email) and maps the JWT claims `employee_id`, `role`, `department_ids` and `org_id` [O-auth] | Identity (Keycloak realm) |
| `notification` | generic | Configurable event → in-app/email notifications | Notification |
| `schedule` | sched. | Drafts, shifts, templates, assignments, locks, publishing, override log | Schedule, Shift, ShiftTemplate, Assignment, OverrideLog |
| `rules` | sched. | Rule CRUD, effective-rule resolution, validate | Rule |
| `availability` | sched. | Availability, time-off requests and approval | Availability, TimeOffRequest |
| `swap` | sched. | Coverage/swap requests, eligibility, state machine, expiry | SwapRequest |
| `autoscheduler` | sched. | Async solver jobs and proposals (API + workers) | SolverJob, Proposal |
| `bff` | Shiftify | GraphQL API for `web`: composes services, subscriptions, saved views | SavedView |
| `web` | Shiftify | SvelteKit SPA [O-ui] | — |

`staff` is the master for people. Admins create employees in Shiftify's UI, and logins follow automatically through `auth`.

---

## 11. Interactions
This section fixes who talks to whom, about what, and whether the call is sync or async. Mechanism and payload details belong to the service specs.

**Edge**
- `web → Envoy Gateway → bff`, as GraphQL over HTTPS plus subscriptions over WebSocket.
- The service REST APIs are also routed through the gateway at `/api/<service>/v1/…` for other apps to use. A JWT is required on every route.

**Sync** (the caller needs the result). The protocol is chosen per interaction [O-proto].
| Caller → callee | Purpose |
|---|---|
| `schedule`, `swap`, `autoscheduler` → `rules` | validate |
| `swap` → `schedule` | read assignments; apply the approved change |
| `autoscheduler` → `schedule` | read shifts and locked assignments |
| `schedule` → `autoscheduler` | fetch the chosen proposal to apply to a draft |
| `bff` → all services | queries and commands for the UI |

**Data dependencies** (reading another service's data). Each one is either a sync call or a local replica built from events, decided per interaction [O-reads].
| Consumer | Needs | From |
|---|---|---|
| `swap` | department membership, skills, position requirements | `staff` |
| `rules` | seniority, contract hours | `staff` |
| `rules` | availability, approved time off | `availability` |
| `autoscheduler` | employees, positions | `staff` |
| `autoscheduler` | availability, approved time off | `availability` |

**Events on Kafka** (facts, past tense). Payloads, topics and versioning are [O-events].
| Event | Producer | Consumers |
|---|---|---|
| `employee.created\|updated\|deleted` | `staff` | `auth`, replica holders |
| `department.*`, `position.*`, `skill.*` | `staff` | `auth` (departments), replica holders |
| `rule.changed` | `rules` | `schedule` (re-validate drafts), replica holders |
| `availability.changed` | `availability` | replica holders |
| `timeoff.approved\|rejected` | `availability` | `notification`, replica holders |
| `schedule.published`, `schedule.changed` | `schedule` | `notification`, `bff`, `swap` (cancel requests whose assignment changed) |
| `swap.requested\|accepted\|applied\|rejected\|cancelled\|expired` | `swap` | `notification`, `bff` |
| `solver.job.completed\|failed` | `autoscheduler` | `notification`, `bff` |
| `notification.created` | `notification` | `bff` (live push) |

"Replica holders" are the consumers in the data-dependency table that choose a replica.

**Tasks on RabbitMQ** (work for one consumer). Topology and delay mechanism are [O-tasks].
| Task | Producer → consumer |
|---|---|
| Solver job | `autoscheduler` API → `autoscheduler` workers |
| Swap expiry (delayed message) | `swap` → `swap` |

---

## 12. Technology baseline
| Area | Decision |
|---|---|
| Backend | Java 25 LTS, Spring Boot, Gradle (Kotlin DSL) |
| BFF | Spring for GraphQL. Depth/complexity limits, auth on every resolver, introspection off on AKS |
| Frontend | SvelteKit + TypeScript, shadcn-svelte + Tailwind |
| Sync protocols | REST by default; gRPC where the data demands it; GraphQL only at the BFF [O-proto] |
| REST conventions | `/v1` in the path; RFC 9457 problem+json; intent endpoints (`POST /v1/schedules/{id}/publish`, body only when the action needs data); `Idempotency-Key` on creates; cursor pagination; ETag + If-Match. API DTOs only, never entities, stack traces or SQL errors. Endpoints [O-api] |
| Events | Kafka (Strimzi, KRaft). Payloads as **JSON Schema** registered in **Apicurio Registry**, with compatibility enforced |
| Publishing | Transactional outbox + **Debezium CDC** (Kafka Connect via Strimzi) |
| Consuming | At least once + idempotent consumer (inbox), commit after processing |
| Tasks | RabbitMQ (Cluster Operator + Messaging Topology Operator) |
| Data | Database per service; no cross-service FKs. Default: PostgreSQL on **CloudNativePG**, with one database and user per service [O-db] |
| Identity | Keycloak (Keycloak Operator), OIDC/JWT |
| Gateway | **Envoy Gateway** (Gateway API: HTTPRoute/GRPCRoute), JWT verified against Keycloak JWKS |
| Cloud | Azure AKS, one demo environment. The cluster is destroyed between demos to save credit |
| Local | kind + Tilt, using the same Helm charts as AKS |
| IaC | **OpenTofu**, remote state in Azure Storage |
| Images | GHCR, tagged with the git SHA and deployed by digest |
| Deploy | One Helm chart per service (in its repo); **Argo CD** GitOps from the `infra` repo; stateful infrastructure via operators |
| Secrets | Sealed Secrets in the `infra` repo; never plain secrets in Git |
| Security | NetworkPolicy deny-all + explicit allows; per-service Kafka (KafkaUser ACLs), RabbitMQ and DB users; non-root, hardened pods |
| Scaling | KEDA on RabbitMQ queue depth for solver workers (scale to 0); HPA on CPU for `bff` and APIs |
| Observability | OpenTelemetry (traces across Kafka/RabbitMQ), Prometheus, Grafana, Loki [O-observe] |
| Email | Mailpit |
| CI (per repo, GitHub Actions) | Tests + Testcontainers · contract checks (oasdiff, Apicurio compatibility, Pact where useful) · static analysis (SonarQube Cloud / CodeQL) · Trivy + Syft SBOM + cosign · Dependabot · actions pinned to SHAs · OIDC, least-privilege `permissions` |
| E2E | Playwright runs the demo scenario (§15) on kind; k6 load test shows KEDA/HPA scaling |

---

## 13. Repositories
GitHub org [`shiftify-rso`](https://github.com/shiftify-rso), all repos public, Apache-2.0:
- **One repo per component** (`staff`, `auth`, `schedule`, `rules`, `availability`, `swap`, `autoscheduler`, `notification`, `bff`, `web`). Each holds:
  - code
  - Helm chart
  - its `SPEC.md`
  - its contracts (OpenAPI / AsyncAPI / proto / GraphQL schema)
  - its CI
- **`infra`**:
  - OpenTofu
  - Argo CD applications
  - operator resources (Kafka topics and users, RabbitMQ queues, CNPG databases, Keycloak realm, Apicurio)
  - Sealed Secrets
  - the Tilt setup
  - E2E and load tests
- **`shiftify`** (main repo): `docs/` (this spec, the guide, the service-spec template, the archive) plus every other repo as a git submodule:
  ```
  shiftify/
  ├── docs/
  ├── services/{staff,auth,schedule,rules,availability,swap,autoscheduler,notification}
  ├── bff/
  ├── web/
  └── infra/
  ```
  Clone with `git clone --recurse-submodules`. Submodules track `main`; `git submodule update --remote` pulls the latest.

---

## 14. Open decisions
| ID | Decision | Default | Resolved in |
|---|---|---|---|
| O-db | DB engine and schema | PostgreSQL on CNPG; another engine needs a written reason | each service spec |
| O-reads | Sync call vs event-built replica for each data dependency (§11) | — | consumer's spec |
| O-proto | REST or gRPC for each sync interaction | REST | callee's spec |
| O-api | Endpoints and resources | REST conventions (§12) | each service spec (OpenAPI) |
| O-events | Payload fields, topic naming, partitions, retention, version suffix | key = aggregate ID; fat, versioned events | producer's spec (AsyncAPI + Apicurio) |
| O-tasks | Queue topology, delay mechanism, retries/DLQ | — | `autoscheduler`, `swap` specs |
| O-solver | Timefold domain model, constraint weights, diversity strategy | — | `autoscheduler` spec |
| O-auth | Adapter scope, Keycloak realm/client layout, invite flow | — | `auth` spec |
| O-mail | Email sending path inside `notification` (e.g. internal task queue) | — | `notification` spec |
| O-ui | Calendar/timeline library, page structure | — | `web` spec |
| O-observe | Dashboards, SLOs, alerts | RED metrics + p99 | `infra` |

---

## 15. Acceptance criteria

**Staff:** Admin can create departments, positions (with required skills), skills, and employees (with seniority, skills, departments and contract hours). The new employee can log in.

**Schedule editing**
- A manager can create a draft from templates for a given week.
- Assigning beyond `max_hours_per_week` immediately shows an error naming the employee, the rule and the hours.
- Employees cannot see a draft. After publishing they can, and they receive a notification.

**Views**
- All four views render the same schedule consistently.
- Filtering by department or seniority works in every view.
- A saved view restores its exact config.
- The coverage view highlights an understaffed shift.

**Availability & time off**
- `unavailable` or approved time off blocks both manual assignment (error) and auto-assignment.
- `prefer_not` only warns or penalizes.

**Coverage & swaps**
- When a shift's only senior requests coverage, only coworkers who keep `min_seniority_count` satisfied see the request.
- A swap that breaks a hard rule at approval time is rejected with the violation shown.
- An approved swap updates both assignments and notifies both employees.
- An unanswered request expires at shift start.

**Auto-scheduler**
- A feasible week yields ≥2 distinct proposals with no hard violations.
- Locked assignments appear in every proposal.
- Changing a department-scoped rule (e.g. min seniors 1 → 2) changes only that department's result.
- An infeasible week lists every unfilled slot with a reason.

**Demo scenario**
1. Seed 15 employees across 3 departments (mixed seniority).
2. Employees submit availability, and one time-off request is approved.
3. Generate 3 proposals for a week, pick one, tweak it, and publish.
4. A senior requests coverage. Only eligible coworkers are offered the shift; one accepts and the manager approves.
5. A junior tries to take a senior-required shift alone. The swap is blocked by the rule.

**Use cases (prijava) → sections**
| PU | Use case | § |
|---|---|---|
| PU1 | Manage departments, positions, skills, employees | 2, 10 |
| PU2 | Configure rules | 3 |
| PU3 | Edit a draft with live validation | 4 |
| PU4 | Auto-generate proposals (complex use case) | 8 |
| PU5 | Publish a schedule | 4 |
| PU6 | Approve time off and swaps | 5, 6 |
| PU7 | View the schedule | 7 |
| PU8 | Availability and time-off requests | 5 |
| PU9 | Request coverage or a swap | 6 |
| PU10 | Take over a coworker's request | 6 |
| PU11 | Notifications | 9 |
