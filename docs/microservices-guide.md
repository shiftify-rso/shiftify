# Building a Good Microservices App — Best Practices & Crossroads

Nov 17, 2026

A good microservices app is a set of independently deployable services cut along domain boundaries. Each service owns its data and talks through versioned contracts and reliable events, and it ships through a fully automated pipeline. This guide condenses the RSO 2026/27 lectures (design, cloud-native patterns, Kubernetes, CI/CD and IaC, database per service, Kafka and NATS). The table lists each crossroads with a sensible default; the sections give the reasoning.

## The crossroads at a glance

| Decision | Default | Choose otherwise when | § |
| --- | --- | --- | --- |
| Monolith or microservices | Modular monolith first | several teams, stable boundaries, differing scale or security needs | 1 |
| Legacy system | Strangler fig | never a big bang | 1 |
| How to cut | Business capability or subdomain | — (never by layer or entity) | 1 |
| Build, buy or reuse | Build core, simplify supporting, buy generic | — | 1 |
| Service size | One capability, one team | split for volatility, scale, fault isolation, security; merge for transactions, chatty workflows | 1 |
| API or event | Event for facts; sync API only when the caller needs the result | long-running work → async command + 202 | 1 |
| Orchestration or choreography | Orchestrate inside a context, choreograph between | — | 1, 5 |
| Sync protocol | REST + OpenAPI 3.1 | gRPC for internal low-latency calls; GraphQL for a BFF | 1 |
| Concurrency model | Virtual threads (Java 21+) or async/await | reactive for streaming or backpressure-heavy paths | 2 |
| Multitenancy | Pool + RLS | silo for premium or regulated tenants | 2 |
| Workload type | Deployment | StatefulSet for brokers or dev DBs; Job/CronJob for batch; managed DB in prod | 3 |
| Ingress | Gateway API (HTTPRoute) | Ingress only in legacy setups | 3 |
| Rollout | Rolling, `maxUnavailable: 0` | canary for risky changes; blue/green for instant rollback | 3 |
| Packaging | Helm, one chart per service | Kustomize for small overlays and patching third-party charts | 3 |
| Automation level | Continuous delivery (manual prod gate) | continuous deployment with strong tests and canaries | 4 |
| Deploy mechanism | GitOps pull (Argo CD) | push from CI to get started | 4 |
| IaC tool | Terraform/OpenTofu | Bicep if Azure-only; Ansible only for VMs | 4 |
| DB isolation | Schema per service | server per service for scale or different tech | 5 |
| DB technology | PostgreSQL | document, KV, search, graph only with a reason | 5 |
| Publishing events | Transactional outbox | CDC (Debezium) relay at scale | 5 |
| Cross-service reads | Replica from events | composition for low traffic; CQRS for hot views | 5 |
| Event sourcing | No | audit, temporal queries, important state transitions | 5 |
| CQRS | Level 1–2 | level 3 only with event sourcing | 5 |
| Event payload | Fat (state transfer), versioned | thin when consumers must always read the freshest data from the source | 5 |
| Queue or log | Log for facts, queue for tasks | — | 6 |
| Broker | Kafka (or Event Hubs) for events | NATS for request-reply, edge, light ops | 6 |
| Delivery semantics | At least once + idempotent consumer | Kafka transactions for Kafka → Kafka pipelines | 6 |
| Message key | Aggregate ID | — | 6 |
| Schema format | Avro + Schema Registry, BACKWARD | Protobuf if the team uses gRPC | 6 |
| Scaling signal | CPU for APIs (HPA) | consumer lag for workers (KEDA) | 3, 6 |

## 1. Design: where to cut

The most expensive microservices mistake is not the technology choice. It is a wrong boundary. The goal is teams that can move independently; microservices are only a means to that.

**The core test.** Can one team change, test and deploy its service without coordinating with anyone? This needs independent deployment, data only it owns, one owning team and failure that stays isolated. If the test fails, you built a distributed monolith: you pay every cost of microservices and get none of the benefits.

### Crossroads: monolith or microservices?

| Situation | Choose |
| --- | --- |
| Domain poorly understood, boundaries still moving, 1–2 teams, no need to scale parts separately | **Modular monolith**: one module per bounded context, one DB schema per module, modules talk through public interfaces or in-process events, boundaries enforced by tests (ArchUnit, Spring Modulith). Extract services later. |
| Several teams, stable boundaries, parts with different scaling, security or change needs | **Microservices** |
| Existing legacy system | **Strangler fig**: put a gateway in front, extract one high-value, low-dependency module, reroute traffic, migrate its data separately, repeat. Never a big bang. |

### The 7-step design process

1. **Understand the domain** with Event Storming: events in past tense on a timeline, then commands, actors, external systems, policies ("when X, then Y"), aggregates, and hot spots (disagreements). Start with events, not data or commands, and don't draw boundaries too early.
2. **Classify subdomains.** *Core* (competitive edge, e.g. pricing, recommendations): build it yourself with your best team and full DDD. *Supporting* (warehouse, delivery): keep it simple or outsource it. *Generic* (identity, payments, email): buy or reuse (Keycloak, Stripe). Building your own auth is almost always a mistake.
3. **Draw bounded contexts** and a context map. Inside a context a word has one meaning ("Order" in Sales, Warehouse and Delivery is three models). Use the ubiquitous language in code, APIs and events. Translate between contexts; never share one model. Boundaries go where the language changes and a process phase ends.
4. **Define aggregates** as consistency boundaries: model only the true invariants, keep aggregates small, reference other aggregates by ID only, and use eventual consistency (events) beyond the boundary. One transaction is one aggregate. A service never splits an aggregate.
5. **Set granularity** by weighing disintegrators against integrators (below).
6. **Choose communication and contracts**: API or event, OpenAPI or AsyncAPI.
7. **Verify and record** with design tests, fitness functions and ADRs.

### Decomposition strategies

| Strategy | Use? | Example |
| --- | --- | --- |
| Business capability | Yes, stable boundaries | ordering, payment, delivery |
| Subdomain (DDD) | Yes | Orders, Warehouse, Payments |
| Volatility | Yes: isolate what changes often | price list, promotions |
| Team (Conway's law) | Yes. Inverse Conway: design teams first, then architecture. | fulfilment team |
| Technical layer (UI / logic / DB) | **No**: every change hits 3 services | — |
| Entity (CRUD service per table) | **No** | "CustomerService", "AddressService" |

Parnas (1972): hide *decisions likely to change* (data model, algorithm, external provider, business rule), not process steps. Splitting by process step creates services that must change together. Keep together what changes together (Common Closure); point dependencies toward what is stable.

### Crossroads: how big is a service?

Aim for one business capability owned by one team that mostly changes on its own. Too coarse means 5 teams share one service, one release and all-or-nothing scaling. Too fine means a CRUD service per table, 10 calls per request and distributed transactions.

| Split when (disintegrators) | Keep together when (integrators) |
| --- | --- |
| Different scope or function (cohesion; not enough on its own) | Atomic transactions are needed |
| One part changes far more often | The workflow would need many calls between services |
| Load and scaling needs differ | Shared business code |
| One part fails often (fault tolerance) | Data is tightly related |
| Security or compliance needs differ (e.g. PCI DSS) |  |
| New variants are expected (extensibility) |  |

Granularity is a trade-off, so write down why. Example: split Payments from Orders (PCI scope, provider churn, provider outages must not block ordering) and accept a saga with an "awaiting payment" status. Record it as an ADR.

### Crossroads: API or event?

- **Command** (`PlaceOrder`, imperative): one known receiver, which may reject it. Send it via a sync API or a queue.
- **Query** (`GetOrder(42)`): no side effects, needs an answer. Use a sync API or a local copy.
- **Event** (`OrderPlaced`, past tense): a fact, 0…N unknown receivers, cannot be rejected. Publish it through a broker. A `SendEmail` "event" is a command in disguise: if you expect someone to act, it's a command.

Decision tree:

1. Does the caller need the result to continue? → **Sync API** (REST or gRPC) with a timeout and a fallback.
2. Is it a fact others care about? → **Event** (Kafka, NATS).
3. Is it long-running, or can it wait? → **Async command on a queue**, returning `202 Accepted` and a status resource.
4. Do you read another service's data often? → Keep a **local copy built from its events** rather than calling it on every request.

The four meanings of "event-driven" (Fowler):

| Meaning | What you get | What you pay |
| --- | --- | --- |
| Event notification (thin event with an ID; the consumer calls back) | loose coupling | an extra call; the source must be up |
| Event-carried state transfer (the event carries data; the consumer keeps a local copy) | no calls, resilience | duplicated data, eventual consistency |
| Event sourcing (internal) | audit trail, replay | schema evolution, complexity |
| CQRS (internal) | optimized reads | lag, several models |

**Orchestration or choreography.** Choreography (services react to events) suits few steps and spreading facts, but the process isn't written down anywhere. Orchestration (Temporal, Camunda) suits long processes, deadlines and compensations, but beware a "god" orchestrator. Rule of thumb: orchestrate within a context, choreograph between contexts.

### Protocols and contracts

| Protocol | When | Contract |
| --- | --- | --- |
| REST/HTTP | public and general APIs, caching | OpenAPI 3.1 |
| gRPC | internal calls, low latency, streaming | Protobuf |
| GraphQL | BFF, clients with differing needs | GraphQL SDL |
| Events (Kafka, NATS) | facts, decoupling, replay | AsyncAPI 3 + CloudEvents |
| Webhooks | notifying external systems | OpenAPI 3.1 webhooks |

With no contract in the repo, you have an implementation, not an API. API rules:

- Contract first; review it like code.
- Design outside-in from consumer use cases, never from the DB schema.
- Keep it coarse-grained: one use case is one call.
- Hide internals: tables, enums and DB errors stay inside.
- Use stable, meaningless IDs.
- Stay backward compatible by default. Hyrum's law: every observable behaviour will be depended on.

**Good REST:** intent-based endpoints (`POST /orders` with an `Idempotency-Key`, `POST /orders/42/cancel`), not `PUT` of raw status fields. Return errors as RFC 9457 `problem+json`. Use plural nouns, cursor pagination (`?limit=50&cursor=…`), `ETag` + `If-Match` (412 on conflict), and `429` + `Retry-After`. Use the right status codes (201 + Location, 204, 400/401/403/404/409/422, 503).

**Event design:**

- Name events in the past tense.
- Public events ≠ internal events: raw CDC table changes are not public events.
- Carry enough data that consumers don't call back.
- Include `id` (for idempotency), `correlationId` and `causationId`.
- Put the version in the type (`…OrderPlaced.v1`).
- Key = aggregate ID.

**Versioning:** use `/v1` in the path (most common) or a media type. For events, publish v1 and v2 side by side until all consumers migrate. Announce retirement with `Deprecation`/`Sunset` headers. The best version is the one you never need: add, don't change.

**Contract testing in CI:** Pact for consumer-driven contracts (`can-i-deploy?`), oasdiff for breaking OpenAPI changes, a schema registry (Apicurio, Confluent) for event schemas.

### Verify the design before coding

- **Five tests:**
  1. *Deploy*: can one service ship without coordination?
  2. *Change*: list 5 likely changes; each should touch 1 service. This is the cheapest and most revealing test, so do it on a whiteboard.
  3. *Failure*: if X is down, what can users still do?
  4. *Data ownership*: does each piece of data have exactly one writer?
  5. *Team*: can one team understand and maintain it?
- **Quality scenarios** (source, stimulus, artifact, environment, response, measure), 2–3 per key attribute. Example: payment provider down during a 5× promo spike → orders accepted as "awaiting payment", 0 lost, p99 < 500 ms. The measures become SLOs, tests and alerts.
- **Architecture smells:** a shared DB; lockstep releases; chattiness (> 10 calls per request); sync chains deeper than 3; dependency cycles; shared domain libraries; the same commits across services.
- **Fitness functions in CI:** ArchUnit (no cycles, no access to other modules' internals), Pact, p99 vs SLO, oasdiff.
- **ADRs:** one page in the repo next to the code, with context, decision and consequences (negative ones too). Never delete an ADR; supersede it.
- **Document with C4**, mainly level 2 (containers), as diagrams-as-code (Structurizr, PlantUML, Mermaid).

## 2. Cloud-native runtime patterns

Assume the network fails, is slow and changes. Every pattern below answers one of the 8 fallacies of distributed computing.

| Fallacy | Answer |
| --- | --- |
| The network is reliable | timeouts, retries, idempotency, outbox |
| Latency is zero | async, fewer calls (BFF), watch tail latency |
| Bandwidth is infinite | read models (CQRS), pagination, compression |
| The network is secure | mTLS, tokens, tenant in every call |
| Topology doesn't change | service discovery, DNS |
| There is one administrator | observability, metrics, SLOs |
| Transport cost is zero | serialization costs CPU; cross-zone traffic costs money |
| The network is homogeneous | contracts and schema evolution |

**Why async matters:** 10 sync services at 99.9% each give 0.999¹⁰ ≈ 99.0% for the chain (\~43 min vs \~7.2 h of downtime a month). A sync chain is only as reliable as the product of its links. Async removes *temporal* coupling (both sides up at once) and *location* coupling, but not *format* coupling; for that you need contracts and schema evolution.

### Twelve-factor app (the baseline)

1. One repo = one app, with many deploys from the same code.
2. Explicit, isolated dependencies.
3. Config strictly separate from code (env vars or a config server).
4. Backing services (DB, broker, S3) are attached resources.
5. Separate build, release and run stages; every release has a unique ID.
6. Stateless processes; state lives in backing services.
7. Expose the service on a port with an embedded server.
8. Scale out with more processes, typed by kind (HTTP, workers).
9. Fast startup, graceful shutdown: the app can be stopped at any time.
10. Dev/prod parity, using the same tools.
11. Logs are an event stream to stdout; the platform aggregates them.
12. One-off admin tasks (migrations) run in the same environment as the app.

### Resilience (stability patterns)

- **Timeout** on every call: never wait forever. Timeouts get shorter as you go down the chain.
- **Retry** with exponential backoff and jitter, only for idempotent operations, and **in one place in the chain**. 5 layers × 3 retries = 3⁵ = 243× load on the database during an outage.
- **Circuit breaker:** stop calling what is broken; fail fast.
- **Bulkhead:** separate pools or limits per dependency.
- **Fallback:** cache or a default value.
- **Backpressure and load shedding:** use bounded queues and reject with 429/503. Unbounded queues hide overload.
- Avoid unbounded results (`SELECT` without `LIMIT`), retry storms and blocked threads. Beware *metastable failures*, where retries keep a system overloaded after the trigger is gone.
- Implement with MicroProfile Fault Tolerance (`@Timeout`, `@Retry`, `@CircuitBreaker`, `@Bulkhead`, `@Fallback`), Resilience4j, or a service mesh.

### Concurrency model

A typical request spends \~96% of its time waiting on I/O (5 ms CPU out of 125 ms). What the thread does while waiting decides throughput and cloud cost.

| Model | Trade-off | Examples |
| --- | --- | --- |
| Thread per request | simple; each thread costs \~1 MB of stack (10,000 threads ≈ 10 GB) | classic Servlet, Spring MVC |
| Reactive | few threads, non-blocking; harder to write and debug; one blocking call stalls everything | Reactor, Vert.x, Mutiny |
| Virtual threads | blocking-style code; \~1M per JVM; watch for pinning in synchronized blocks (mostly fixed in JDK 24) | Java 21+ |
| async/await | coroutines in the language | Python asyncio, JS, C# |

Size pools with **Little's law, L = λ · W**. At 200 req/s × 0.25 s, 50 requests are in flight. If a dependency slows to 2 s, the same throughput needs 400 concurrent requests. A pool of 20 threads at 0.25 s caps throughput at 80 req/s. The DB connection pool is often the tighter bottleneck: 10 connections × 20 ms queries = 500 queries/s, however many threads you have.

### Edge, config and discovery

- **API gateway:** a single entry point for security, rate limiting and routing.
- **BFF:** one layer per client type (web, mobile) that aggregates calls and shapes responses. The client team owns it.
- **Config:** use ConfigMaps or Secrets as env vars or files, or MicroProfile Config or a config server. Keep secrets in Vault or External Secrets, never in Git.
- **Discovery:** Kubernetes DNS (`svc.ns.svc.cluster.local`) is server-side; Consul and Eureka are client-side. A service mesh adds routing and mTLS.

### Multitenancy (if you're SaaS)

| Model | Isolation | Cost | Ops effort |
| --- | --- | --- | --- |
| Silo: DB (or more) per tenant | highest | highest | highest |
| Bridge: shared runtime, separate schemas or DBs | medium | medium | medium |
| Pool: shared tables with `tenant_id` + row-level security | lowest | lowest | lowest |

In practice you combine tiers: premium tenants in a silo, the rest in the pool.

The tenant must flow everywhere: `tenant_id` in the JWT; per-tenant quotas at the gateway; tenant context in every call; a header or subject on events (NATS accounts, Kafka ACLs); RLS or filters on data; and a namespace, ResourceQuota and NetworkPolicy in Kubernetes. Add metrics, logs and cost per tenant. One forgotten filter leaks one customer's data to another. Watch for noisy neighbours, and plan for GDPR and data residency.

## 3. Running on Kubernetes

You don't tell Kubernetes what to do; you describe what you want, and control loops converge on it. It is level-triggered ("want 3, see 2 → create 1"), so a missed event doesn't matter. YAML in Git is the source of truth. Kubernetes does scheduling, self-healing, scaling, rollouts, discovery, config and storage. It does **not** build images, do CI/CD, make your app resilient (state, shutdown and probes are your job), provide a DB, logs or metrics, or isolate pods by default (every pod can talk to every pod).

**Cattle, not pets.** Never patch what's running; replace it. `:latest` tags, fixes via `kubectl exec` and state inside the container all destroy reproducibility.

### Pre-flight checklist for every service

- [ ] **Immutable image:** a tag or digest, never `:latest`. The same image in every environment.
- [ ] **Three probes** (below).
- [ ] **Resources:** `requests` always (no requests means no HPA) and a **memory limit** always. Usually omit the CPU limit: above it you get throttled (slow but alive), while above the memory limit you get OOMKilled. For the JVM, set `MaxRAMPercentage`, not a fixed `Xmx`.
- [ ] **Graceful shutdown:** on SIGTERM, a `preStop` pause of \~5 s (endpoint removal isn't instant on every node), then finish in-flight requests before SIGKILL at 30 s.
- [ ] **Structured (JSON) logs** to stdout.
- [ ] **Metrics and traces:** `/metrics`, OpenTelemetry.
- [ ] **Config from outside** via ConfigMap and Secret.
- [ ] **Non-root, hardened:** `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false`. Pod Security Standards: *restricted*.
- [ ] **≥ 2 replicas + a PodDisruptionBudget**, spread across zones with `topologySpreadConstraints`. Three replicas in one zone is not HA.
- [ ] **No local state:** state lives in backing services.

### Probes: who asks what

| Probe | Question | On failure | Should check |
| --- | --- | --- | --- |
| startupProbe | Has it started? | restart; the others wait | init (JVM, model load). Without it, slow starts trigger liveness restart loops. |
| readinessProbe | Can it take traffic? | removed from Service, not killed | warm-up, overload, *essential* dependencies only |
| livenessProbe | Is it stuck? | container restart | only the process itself (deadlock) |

The most expensive mistake is putting the **DB in the liveness probe**. The DB blips, every replica restarts at once, and you cause your own outage. Keep probes cheap and side-effect free.

### Crossroads: workload type

| Type | When | Example |
| --- | --- | --- |
| Deployment | stateless, any replica count | orders, catalog, cart |
| StatefulSet | stable identity + own disk per replica | Postgres in dev, Kafka, NATS |
| DaemonSet | one pod per node | log shipper, OTel Collector |
| Job / CronJob | runs to completion / on a schedule | DB migration, nightly report. Make it idempotent; set `concurrencyPolicy`, `activeDeadlineSeconds`, `timeZone`. |

Run production databases as managed services or through an operator (CloudNativePG), not a hand-rolled StatefulSet.

### Config and secrets

One image, with config from a ConfigMap (env or files). Changing a ConfigMap does **not** update running pods; use a `checksum/config` annotation to trigger a rollout. A Secret is base64, not encryption: restrict it with RBAC and enable etcd encryption. Never put secrets in Git; use External Secrets Operator (Vault, Key Vault) or Sealed Secrets.

### Exposing services

- **Service** (ClusterIP) gives pods a stable name: call `http://orders/...`. Only Ready pods get traffic. Use headless for StatefulSets. Don't create one LoadBalancer per HTTP service; use one L7 entry point.
- **Crossroads: Ingress or Gateway API.** Ingress-NGINX was retired in March 2026, and the Ingress API is frozen. **Use Gateway API for new projects.** It separates roles: GatewayClass (provider), Gateway (platform team: listeners, TLS), HTTPRoute (developer: paths, headers, weights). It is portable and supports HTTP, gRPC, TCP and UDP. Migrate with `ingress2gateway`.
- **Labels:** use the `app.kubernetes.io/*` set. Selectors are immutable, so never put the version in selector labels.

### Crossroads: deployment strategy (separate *deploy* from *release*)

| Strategy | How | Cost / risk |
| --- | --- | --- |
| Recreate | stop old, start new | downtime |
| Rolling (default) | gradual replacement; `maxSurge: 1, maxUnavailable: 0` keeps capacity | both versions live at once, so changes must be backward compatible |
| Blue/green | two environments, switch traffic | 2× resources; instant rollback |
| Canary | small share of traffic (HTTPRoute weights 90/10); metrics decide (Argo Rollouts, Flagger) | needs good metrics |
| Shadow | copy of traffic, responses discarded | side effects (writes!) |
| Feature flags | code deployed, feature off | flag debt |

### Scaling

HPA on CPU computes utilization against `requests`. Use **KEDA** for event-driven scaling (Kafka lag, NATS stream depth, scale to 0). VPA handles vertical scaling; since 1.35 resources can change without a restart.

### Packaging: Helm

Use one chart per service. Templates + values produce plain YAML; a release has revisions, upgrade and rollback.

- `values.yaml` is the chart's public API: commented, safe defaults, shallow, camelCase, **no secrets** (only the Secret's name), validated by `values.schema.json`.
- Track two versions: `version` (the chart, SemVer) ≠ `appVersion` (the app).
- Keep environment differences in `values-<env>.yaml` only. Precedence: `values.yaml` < `-f` files < `--set`.
- **Build once, deploy everywhere:** the same image digest and chart move through dev → staging → prod. Promotion means changing the version in the environment's values. Building per environment means prod runs an artifact nobody tested.
- Deploy with `helm upgrade --install … --wait --rollback-on-failure`. It is idempotent, so it suits CI/CD. A rollback is a new revision.
- Verify in CI, cheapest first: `helm lint` → `helm template | kubeconform` → `--dry-run=server` → `helm diff` → `helm test`.
- Pin dependencies (`Chart.lock` in Git), publish charts to an OCI registry, and **mirror third-party images**: Bitnami's 2025 withdrawal broke charts with ImagePullBackOff.
- Run DB migrations as a `pre-upgrade` hook Job. Keep migrations backward compatible (expand → migrate → contract), because both versions run during a rolling update.
- Use a library chart for shared templates instead of copy-paste. Helm 4 is current (Helm 3 security fixes ended 11 Nov 2026).
- **Helm or Kustomize?** Helm suits distributing apps across many environments (packages, releases, rollback). Kustomize suits small overlays and patching third-party charts. Using both is common.

### Failure domains

Ask what fails together: pod (replicas, probes) → node (PDB, anti-affinity) → zone (spread, regional disks) → region (multi-cluster, DNS failover). A **cell architecture** limits the blast radius to a subset of customers.

### Developer loop and platform

- **Inner loop:** a local cluster (kind, k3d, minikube) + Skaffold or Tilt, using the same Helm chart as prod. Iterations take seconds, not minutes.
- **Platform engineering:** the platform team owns clusters, the Gateway, pipelines, chart templates and observability. Service teams own code, HTTPRoutes, values and SLOs. Offer a *golden path* (service template + chart + pipeline) and self-service (Backstage).
- **Debug:** `kubectl describe` (events at the bottom), `logs --previous`, `get events --sort-by`, `port-forward`, `kubectl debug`. Common statuses: ImagePullBackOff (image or registry auth), CrashLoopBackOff (the app crashes), Pending (resources, PVC or node), OOMKilled (memory limit), Running 0/1 (readiness failing).

## 4. Delivery: CI/CD and infrastructure as code

For microservices, CI/CD is a precondition, not an improvement. 20 services × 3 environments × 5 changes a week = 300 deployments a week, and done by hand that is 300 chances to fail a week. In production, nobody types `kubectl apply`.

### Crossroads: how far to automate

- **CI:** every change is built and tested. A "build" covers compiling, unit and integration tests, analysis, packaging the image and deploying to a test environment.
- **Continuous delivery:** always releasable; production is one human click away.
- **Continuous deployment:** production deploys automatically too.

A sensible default is continuous delivery: automatic to dev and staging, with manual approval for prod.

### Continuous delivery principles

1. Everything in Git: code, pipeline, infrastructure, config.
2. Build once; promote the same artifact through every environment.
3. Use the same deploy procedure for every environment.
4. Keep feedback fast: CI under 10 minutes.
5. Stop at the first failure; a red pipeline takes priority.
6. Run a smoke test after every deploy.
7. If it hurts, do it often: releases, migrations, restores.
8. "Done" means deployed, not "code written".

### Reference pipeline

1. **PR:** lint, build, unit tests; the quality gate must pass to merge.
2. **CI on main:** secrets from Key Vault; build and test (Testcontainers); dependency scan (Dependabot, OWASP DC); static analysis (SonarQube, CodeQL); build the image; image scan (Trivy); SBOM + signing (Syft, cosign); push to the non-prod registry, **tagged with the git SHA**, deployed by digest.
3. **Staging:** deploy and run acceptance tests.
4. **Promote:** copy the image into a separate prod registry (`az acr import`). Only images that passed staging reach prod.
5. **Production:** manual approval through a protected GitHub environment with required reviewers.
6. **Observe:** Prometheus/Grafana or Azure Monitor and Application Insights.

The same image, tag and Helm chart go everywhere; only the values differ.

### Crossroads: push or pull (GitOps) deployment

|  | Push | Pull / GitOps (Argo CD, Flux) |
| --- | --- | --- |
| How | CI runs `helm upgrade --install` | CI commits a new image tag to a GitOps repo; an agent in the cluster reconciles |
| Cluster credentials | CI needs them | CI needs none |
| Rollback | re-run the pipeline | `git revert` |
| Drift | undetected | `selfHeal` reverts manual changes; `prune` deletes what isn't in Git |
| Best for | getting started | production, many services (ApplicationSet: 20 services × 3 envs from one template) |

OpenGitOps principles: declarative, versioned and immutable, pulled automatically, continuously reconciled. It is the Kubernetes control loop stretched across the whole pipeline. Add Argo Rollouts or Flagger for metric-driven canary and blue/green. Order migrations with sync waves and hooks.

### GitHub Actions practices

- Grant least privilege: `permissions: contents: read` by default.
- Use **OIDC** (`id-token: write`) into Azure instead of stored passwords: a short-lived token per job.
- **Pin actions to a full commit SHA.** Tags are pointers: in the March 2025 tj-actions/changed-files compromise, retargeted tags leaked secrets from 23,000+ repos. Keep actions updated with Dependabot or Renovate.
- Use `concurrency` with `cancel-in-progress`, `paths` filters in monorepos, a dependency cache, and `needs`/`if` for ordering.
- Use environments for per-env secrets, reviewers and branch rules.
- Beware `pull_request_target`: repo permissions plus foreign code is a trap. Put `.github/workflows` under CODEOWNERS.
- **Reusable workflows** (`workflow_call`) are the platform team's golden path: 20 services, one pipeline, and an improvement lands everywhere.

The pipeline holds the keys to production. Treat it as a production system.

### Quality and supply chain

- **Quality gate** on *new* code (e.g. ≥ 80% coverage, no critical bugs or new vulnerabilities) as a required status check. Coverage is not quality; mutation testing (PIT) is better.
- **Test stack:** JUnit, Testcontainers, Pact, Playwright, Gatling or k6.
- **Supply chain:** an SBOM (SPDX/CycloneDX), signed images (cosign/Notation) verified before run (Ratify), build provenance attestations, SLSA levels, scanning (Trivy, Defender), and no long-lived secrets.

### Infrastructure as code

ClickOps creates snowflake environments, unknown settings and guesswork recovery. With IaC, changes go through PRs, environments are identical and reproducible, drift is detected, and a new environment takes minutes.

Essentials:

- Declarative and idempotent.
- **Remote state with locking**, never in Git; it holds sensitive data.
- Detect drift with `plan`.
- **Plan on the PR** (posted as a comment), **apply after merge**.
- Versioned modules (Azure Verified Modules).
- Separate state per environment.
- Policy as code before apply (OPA/Conftest, Checkov, Kyverno).
- Tests (`terraform test`, tflint).

| Layer | Tools |
| --- | --- |
| 5 · Delivery | GitHub Actions, Azure Pipelines, Argo CD, Flux |
| 4 · Apps in K8s | Helm, Kustomize |
| 3 · Images | Dockerfile, Packer (VMs) |
| 2 · Server config | Ansible |
| 1 · Infrastructure | Terraform/OpenTofu, Bicep, Pulumi, Crossplane |

**Crossroads: which IaC tool?**

- Multi-platform → **Terraform** (BSL licence, IBM) or **OpenTofu** (MPL 2.0, Linux Foundation; same code, `tofu` command).
- Azure only → **Bicep** (no state file).
- IaC in a general-purpose language → Pulumi.
- Cloud resources as Kubernetes CRDs → Crossplane.
- **Terraform vs Ansible:** Terraform *creates* resources (declarative, with state). Ansible *configures* existing servers (agentless over SSH, idempotent modules, no state); use it for VMs, on-prem and self-hosted runners, not for apps in K8s. They are often combined.

### Measure delivery (DORA)

Throughput: lead time for changes, deployment frequency, time to restore. Instability: change failure rate, rework rate. Speed and stability are not trade-offs; the best teams excel at both. Measure teams, not individuals, and watch trends.

## 5. Data: database per service

Don't start with an E-R model of the whole system. Start with domains, events and data owners. What services share is the contract, not the database. A shared DB is a distributed monolith: schema changes break others, there's no independent deploy, no per-service scaling, a single point of failure and hidden coupling through tables.

### Rules

1. **One owner:** each piece of data has exactly one service that writes it.
2. **Contract only:** others read through an API or events. No back doors.
3. **No foreign keys across boundaries:** use IDs only (`customer_id`, `product_id`). FKs *inside* a service are fine.
4. **No shared tables**, not even "read-only".
5. **Own model:** shaped to the service's needs. Snapshot what must stay historically true (name and price at purchase).
6. **Own technology** where justified.

### Crossroads: isolation level

| Level | Pros | Cons |
| --- | --- | --- |
| Private tables (one server, one schema) | cheapest | boundaries rely on discipline |
| **Schema per service** (own DB user) | good compromise; the default for a project | shared server resources |
| Server per service | full isolation, independent scaling, any tech | cost, operations |

### Crossroads: which database (polyglot persistence)

Default to relational. Choose another only with a reason, because every technology is also operations.

| Type | Example | For | E-shop use |
| --- | --- | --- | --- |
| Relational | PostgreSQL, Azure SQL | transactions, integrity | orders, payments, stock |
| Document | MongoDB, Cosmos DB | variable structure | catalog (no 500-column "universal table") |
| Key-value | Redis | hot, short-lived data, TTL | cart, sessions |
| Wide-column | Cassandra, ScyllaDB | massive writes | viewing history |
| Search | Elasticsearch, OpenSearch | full text, facets | search, CQRS views |
| Graph | Neo4j | relationships | recommendations |
| Time series | TimescaleDB, InfluxDB | metrics over time | telemetry |

Data has a temperature (Uber). Hot data lives in memory with a short life; cold data goes to cheap object storage.

### The dual-write problem → transactional outbox

"Save then publish" in code is a bug waiting for an outage. If the commit succeeds and the publish fails, the order exists but nobody knows. Reverse the order and you publish an event for an order that doesn't exist. 2PC/XA is slow, blocks and is rarely supported.

**Outbox:** in one local transaction, `INSERT` the business row **and** an `outbox` row (`id uuidv7, aggregate_id, type, payload`). A relay publishes it:

| Relay | Pros | Cons |
| --- | --- | --- |
| Polling (`SELECT … FOR UPDATE SKIP LOCKED`) | simple, enough for a project | loads the DB; lag = poll interval |
| CDC from the log (Debezium Outbox Event Router; key = `aggregate_id`) | no polling, keeps order, no broker code in the app | one more component |

Platform options include SQL Server 2025 / Azure SQL change event streaming, the Cosmos DB change feed, the Dapr outbox and Spring Modulith's event publication registry.

### Idempotent consumer (inbox) and ordering

Delivery is at-least-once, so duplicates are normal, not exceptions. In the **same transaction** as the change, run `INSERT INTO inbox(event_id) … ON CONFLICT DO NOTHING`; if 0 rows were inserted, skip. Clean up entries older than the redelivery window. A `UNIQUE(order_id)` constraint in Payments gives idempotency in the DB itself. **At-least-once + idempotency = effectively exactly-once.**

**Ordering:** partition key = aggregate ID, so order holds per aggregate, not globally. On replicas, use a version check: `UPDATE … SET price=$2, version=$3 WHERE id=$1 AND version < $3`, which drops stale events.

### Crossroads: the missing JOIN

| Method | Analogy | Reads | Freshness | Complexity | Use for |
| --- | --- | --- | --- | --- | --- |
| API composition (BFF or gateway aggregates) | telephone game | slow; availability multiplies (0.999³ = 99.7%) | always fresh | low | admin UIs, low traffic |
| Replication (event-carried state → local copy, local JOIN) | pizza menu on the fridge | fast, works when the source is down | may be stale | medium | hot paths needing another service's data |
| CQRS view (JOIN at write time) | specialist reporter | O(1) by key, cross-source search | lags ms–s | high | heavy-traffic pages (e.g. "My orders" at 10k/s) |

Using all three in one system for different views is normal. With composition, avoid **N+1**: 101 calls ≈ 0.5 s versus a batch API (`GET /customers?id=1,5,8`) with 2 calls ≈ 10 ms.

ACID applies inside a service and BASE between services. Ask *how much lag the business tolerates*: account balance 0 ms, "My orders" 1 s, recommendations 1 h. If it tolerates none, it belongs in one service.

### Events: thin or fat, domain or integration

- **Thin (notification):** the consumer calls back, so data is always fresh, but the consumer is stuck if the source is down.
- **Fat (state transfer):** the consumer is autonomous; the event is a public contract. Include a `version` to drop stale events.
- Carry enough that nobody calls back, and no more.
- **Domain events** (fine-grained, internal, change with the model) ≠ **integration events** (coarse, public, versioned, CloudEvents + schema). Translate internal events to public ones; never publish internals.
- A local replica is **not** event sourcing. Replication belongs to the consumer, holds the current state, and may compact events. Event sourcing belongs to the owner, keeps every change forever, and is the source of truth.

### Sagas (instead of distributed transactions)

Each step is a local transaction. On failure, compensations run in reverse order. A compensation is a new business step that leaves a trace (a refund, a credit note), not a delete.

**Structure:** compensatable steps → **pivot** (point of no return) → retryable steps (retried until success). Put steps that often fail first, and hard-to-compensate steps (money, emails) after the pivot. Example: authorize payment → reserve stock → *capture payment (pivot)* → create shipment → confirm order. Whether to reserve stock before payment is a business decision about step order.

**Choreography or orchestration:** see section 1. Orchestration keeps the flow in one place and is easier to test; choreography has no centre but the flow is scattered and cycles appear.

**Sagas have no I from ACID.** Watch for lost updates, dirty reads and fuzzy reads. Countermeasures:

| Countermeasure | Example |
| --- | --- |
| Semantic lock | status PLACED locks editing |
| Commutative updates | stock −1/+1, not "set to 4" |
| Pessimistic view | reorder steps to reduce risk |
| Reread before write | `WHERE version = $v` |
| By value | > €10,000 needs manual approval |
| Reservation with expiry (Try-Confirm-Cancel) | hold for 15 min; it expires by itself if the saga hangs |

**Durable execution** for orchestrated sagas: Temporal (the most widespread), Azure Durable Functions, Dapr Workflow, AWS Lambda durable functions, Restate, DBOS. Completed steps are replayed from the log, not re-executed.

### Crossroads: event sourcing?

**Yes** when audit is a requirement (finance, insurance, legal), when you get "what was the state on 1 March?" questions, when state transitions matter, or for debugging by replay. **No** for CRUD (catalog, lookups, settings), for the whole system "because it's modern", for a team without experience or time, or for frequent ad-hoc queries on state.

If yes:

- **Event store:** append-only, `UNIQUE(stream_id, version)` for optimistic concurrency, and a global position for projections. A PostgreSQL table is enough; dedicated options are KurrentDB (formerly EventStoreDB), Marten, Axon and Python eventsourcing. **Kafka is not an event store**: it can't check stream versions or read one stream efficiently.
- **Pattern:** `decide(command, state) → events`; `state = events.reduce(evolve)`; append with the expected version.
- **Prefer short streams** that end naturally ("closing the books" per period) over snapshots. Snapshots are a cache, not truth.
- **Versioning:** new field → default on read; changed meaning → new event type; rename or split → upcast on read; big redesign → copy-transform into a new stream (last resort).
- **GDPR:** never delete events. Encrypt personal data with a per-person key and destroy the key (crypto-shredding), or store only references.
- **New: DCB** (Dynamic Consistency Boundaries): tags instead of fixed streams, with the consistency boundary set per command. Supported in Axon 5 and Python eventsourcing.

### Crossroads: CQRS level

1. **Separate models, same DB:** commands go through the domain model; queries go straight to SQL views or DTOs.
2. **Separate read store:** a materialized view, read replica or search index, fed by CDC or events.
3. **With event sourcing:** projections are the only way to read.

Most systems need level 1 or 2. Projections are idempotent (`ON CONFLICT`), store a checkpoint in the same transaction, and are shaped like the screen. To rebuild one, build `v2` in the background from the start of history, then switch an alias; this needs retained or compacted history. Handle the lag in the UX:

- *Optimistic display:* show the result of the user's own command.
- *Read-your-writes:* return a position (`202 {"position":4711}`) and query with `?atLeast=4711`.
- *Read from the write model* for the user's own fresh data.
- *Honesty:* show an "in progress" status.

### When not (yet) to split the database

- **Small team, one product:** modular monolith with a schema per module.
- **Unclear boundaries:** wrongly split data is the most expensive mistake.
- **Strong consistency required across everything:** keep it one service.
- **"We need reports"** is not a reason to share a DB. Use CDC or events into a data warehouse or lake (data mesh at scale).

Prime Video (2023) moved one workload back into a single process and cut cost by 90%. AI agents follow the Bezos rule too: give them an API or MCP, never direct DB access.

**Migrating off a shared DB:**

1. Inventory who reads and writes what (`pg_stat_statements`).
2. Move to a schema and DB user per service; give foreign readers read-only access.
3. Make sure only the owner writes; others move to the API or events.
4. Sync via CDC or the outbox, never dual writes.
5. Move the table physically, last.

**GDPR deletes:** publish `CustomerDeleted`; every replica and view owner deletes. Mind event retention in the broker. **Testing:** Testcontainers with a real DB, contract tests for messages, and test the saga's compensation path too.

## 6. Event-driven architecture: messaging and streaming

Events give you three kinds of decoupling: in **time** (the receiver needn't be up; 50 orders/s × a 600 s outage = 30,000 orders waiting, not 30,000 HTTP 503s), in **space** (the sender doesn't know the receiver's address) and in **speed** (the broker absorbs spikes). You also get new consumers without touching the producer, replay, and independent scaling.

You pay with eventual consistency, duplicates and ordering issues, harder debugging (no call stack, so use tracing and correlation IDs), event schemas that become public contracts, and one more critical platform.

### Crossroads: queue or log (messaging or streaming)

|  | Queue (RabbitMQ, Service Bus) | Log (Kafka, Event Hubs, JetStream) |
| --- | --- | --- |
| After reading | deleted on ack | kept until retention ends (e.g. 7 days) |
| Who tracks progress | the broker | the consumer (offset) |
| Re-read | no | from any offset |
| New consumer | sees only new messages | can read history |
| 1M messages waiting | panic: consumers aren't keeping up | "only that many?" (\~1 GB). Watch **consumer lag**, not log length. |
| Use for | **tasks for workers**: email, PDF, images; per-message retry, DLQ, priorities, delays | **facts for many services**: replay, a new service reading history, high throughput, per-key order |

A queue is Snapchat (gone once viewed); a log is a security camera (the recording stays). With a log, a bug in a projection is fixed by resetting the offset (`--reset-offsets --to-datetime`) and reprocessing. With a queue, the messages are gone.

The line is blurring: RabbitMQ has Streams, and Kafka 4.2+ has share groups (queues, with a DLQ in 4.4). **Choose by model, not by product name.**

Other basics:

- **Push or pull:** push (RabbitMQ, Service Bus, Core NATS) gives low latency and needs prefetch limits. Pull (Kafka, JetStream pull) gives natural backpressure and batching; lag builds at the broker, where you can measure it and scale on it.
- **Topologies:** point-to-point queue; pub/sub; competing consumers; log.

### Decision tree

1. Is it a task for one worker, forgotten once acked? → **Queue:** Service Bus, RabbitMQ, JetStream workqueue, Kafka share groups.
2. Is it a fact for many services, needing replay or DB integration? → **Log:** Kafka, Event Hubs, JetStream limits.
3. Do you need request-reply, low latency, edge deployment or simple ops? → **NATS (+ JetStream)**.

It's common to use both: Kafka for events and history, NATS for service-to-service communication.

### Kafka essentials

- **Model:** a topic is a set of partitions; each partition is an append-only, immutable, ordered log replicated across brokers (leader + followers). Producers and consumers talk to the leader. Since 4.0 Kafka runs on **KRaft only** (no ZooKeeper); skip any tutorial that starts with "install ZooKeeper". Manage topics as code (Strimzi `KafkaTopic` in Git → Argo CD).
- **Keys and order:** key → `murmur2(key) % partitions`. Order is guaranteed **per key only**. **Key = aggregate ID** (the order ID). With no key, `OrderPlaced` and `OrderCancelled` land on different partitions and a cancelled order gets shipped. Avoid low-cardinality keys: country as the key put 85% of traffic on one hot partition.
- **Partition count:** partitions ≥ max(T / P\_producer, T / P\_consumer), then add headroom. Example: 60 MB/s, 10 MB/s per producer and 5 MB/s per consumer gives 12, so take 24. The consumer is almost always the bottleneck. Too few partitions caps parallelism; too many means more files, memory and slower leader elections. **Plan ahead:** you can't remove partitions, and adding them remaps keys and breaks ordering. If you must, create a new topic and switch consumers once the old one is drained.
- **Consumer groups:** a group is one logical app. Across groups everyone gets everything (pub/sub); within a group, partitions are divided (competing consumers). More instances than partitions adds nothing.
- **Lag:** `LOG-END − CURRENT` is the key metric. Scale on it with **KEDA** (`lagThreshold`, `maxReplicaCount` = partition count).
- **Rebalancing:** use **KIP-848** (`group.protocol=consumer`, broker-led and incremental) plus static membership (`group.instance.id`) to avoid rebalance storms during rolling updates.
- **Share groups:** per-record acks and delivery counts, any number of workers, but no per-key order. Production-ready in 4.2.
- **Retention and compaction:** time- or size-based retention deletes whole segments. Size it from throughput: 2,000/s × 1 KB ≈ 173 GB/day → 7 days ≈ 1.2 TB → ×RF3 ≈ 3.6 TB. **Tiered storage** (3.9) keeps old segments in Blob or S3. A **compacted** topic keeps the last value per key, so the topic becomes a table: a new service bootstraps a local replica from offset 0 (50k records instead of 30M). A null value is a tombstone (delete). Keyless records are rejected; set `delete.retention.ms` long enough to avoid zombies.
- **GDPR:** on compacted topics, tombstone the customer. On time-retention topics, use crypto-shredding or short retention. Never put personal data in the key.
- **Why it's fast:** sequential I/O, the OS page cache, zero-copy `sendfile` (partly lost with TLS) and batching plus compression (`linger.ms`, `batch.size`, zstd). Tune for throughput or latency from measurements.
- **Ecosystem:** Kafka Connect (Debezium sources; Elasticsearch, Blob or S3 sinks, configuration only), stream processing with Kafka Streams (a library) or Flink (a cluster, with SQL), and Schema Registry.

### Durability: the "never lose" configuration

```
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false   # default
acks=all                               # default since 3.0
enable.idempotence=true                # default since 3.0
```

This survives 1 broker down with reads and writes. With 2 down, writes are rejected (`NotEnoughReplicasException`): durability is chosen over write availability. `acks=0` or `1` may lose data (ad clicks, perhaps; payments, never). Spread replicas across availability zones with `broker.rack`, but cross-zone traffic costs money; diskless topics (KIP-1150) are coming.

### Crossroads: delivery semantics

| Semantics | Risk | How |
| --- | --- | --- |
| At most once | may lose | commit before processing; `acks=0`; Core NATS |
| **At least once** | may duplicate | commit **after** processing; `acks=all`. The Kafka and JetStream default. |
| Exactly once | — | idempotent producer + transactions; only within Kafka → Kafka |

- **For business events:** at least once + an idempotent consumer (inbox).
- Don't rely on `enable.auto.commit`: it can commit unprocessed records.
- The **idempotent producer** dedupes retries per PID and sequence. It doesn't help if your code calls `send()` twice, after a restart with a new PID, or for effects outside Kafka.
- **Transactions** (`transactional.id`, `isolation.level=read_committed`, `processing.guarantee=exactly_once_v2`) make the output write and the offset commit atomic, within Kafka only.
- **Outside Kafka** (a bank API): send an `Idempotency-Key` header (`order-8c41`); a retry returns the first result.

### Retries and dead letters

Transient errors (DB, network) → retry with backoff through retry topics (`…retry-1m`, `…retry-10m`) → a `…dlq` after N attempts → a human looks. A **poison pill** (invalid JSON, a code bug) retried in place blocks the whole partition, so move it aside. The cost is that order for that key is lost. Share groups have a built-in DLQ (4.4).

### Schemas and compatibility

"Bytes are bytes" to the broker. A Friday rename of `znesek` ("amount") → `amount` gives `null` payments on Saturday at 3 AM. Same failure class as the Mars Climate Orbiter (pound-force vs newtons). Rules:

- Use **Schema Registry** for every event. The wire format is magic byte + schema ID + data. Avro sends no field names (31 B of JSON → 15 B), and you can generate classes from schemas.
- **Compatibility mode:** BACKWARD (the default; new readers read old data; upgrade consumers first), FORWARD (old readers read new data; upgrade producers first), FULL (both).
- **Golden rule:** every new field gets a default; never rename; never change meaning or units; tolerant readers ignore unknown fields. For breaking changes: **expand → migrate → contract**, or a new event type `.v2` published alongside v1.
- **Format:** Avro (smallest, at home in Kafka), Protobuf (gRPC shops), JSON Schema (readable, larger). Pick what the team already uses for APIs.
- Use CloudEvents headers (`ce_type=…OrderPlaced.v1`, `ce_id`, `ce_source`) and AsyncAPI as the contract.

### NATS essentials

- **What it is:** a single Go binary, starts instantly, CNCF, Apache 2.0. **Compare Kafka with JetStream, not Core NATS.**
- **Subjects** instead of topics: hierarchical, with wildcards `*` (one token) and `>` (the rest), e.g. `orders.si.>` or `orders.*.placed`. No setup needed; routing lives in the name.
- **Core NATS** is like radio: at most once, no storage. If nobody listens, the message is gone. Good for telemetry, cache invalidation and request-reply; **not** for orders or payments.
- **Queue groups:** competing consumers with no partitions and no upper limit; a new replica gets work immediately.
- **Request-reply:** call a subject instead of a host ("the taxi dispatch desk, not a specific driver's number"); no DNS or load balancer needed.
- **JetStream:** streams over subjects (file storage, replicas 3), durable pull consumers with explicit ack and `max-deliver`. It's a log with positions but no partitions. Retention policies: `limits` (Kafka-like), `interest` (until all subscribers ack) and `workqueue` (until the first ack, queue-like). One server covers events and tasks.
- **Exactly once:** the `Nats-Msg-Id` header plus a dedup window (2 min default) on publish; double ack (AckSync) on consume. External effects still need idempotency.
- **KV and object store:** last value + history + watch, like a compacted topic. It can replace Redis for a cart.
- **Accounts, leaf nodes, superclusters:** multi-team isolation, edge sites (a store keeps selling offline and syncs later) and multi-region.
- **Governance lesson:** in 2025 Synadia nearly relicensed NATS under the BUSL; it stayed Apache 2.0 in the CNCF. Check governance and licence when choosing technology (compare Terraform and OpenTofu).

|  | Kafka | NATS (+ JetStream) |
| --- | --- | --- |
| Model | partitioned log | subjects; streams over them |
| Throughput | highest, batched | very high, low latency |
| Request-reply | not built in | built in |
| Queues | share groups (4.2+) | workqueue, queue groups |
| Ecosystem | Connect, Streams, Registry, Flink | smaller; KV and objects built in |
| Ops | heavier | one binary |
| Edge, multi-cluster | MirrorMaker, Cluster Linking | leaf nodes, superclusters |

### Managed options and alternatives

| Need | Azure | AWS | Google Cloud |
| --- | --- | --- | --- |
| Queue | Service Bus queues | SQS | Pub/Sub (pull), Cloud Tasks |
| Pub/sub | Service Bus topics, Event Grid | SNS | Pub/Sub |
| Log | Event Hubs (Kafka API: same client, change `bootstrap.servers` + SASL/OAuth) | Kinesis | Pub/Sub with seek |
| Managed Kafka | Event Hubs, Confluent Cloud, Strimzi on AKS | MSK (Express) | Managed Service for Kafka |
| Event router | Event Grid | EventBridge | Eventarc |

The Kafka API is becoming a standard, with storage moving to object storage and stateless brokers: Redpanda (C++, BSL), AutoMQ, WarpStream, Bufstream, Aiven Inkless. Pulsar suits strict multi-tenant or geo setups (heavy ops); RocketMQ suits transactional or delayed messages; RabbitMQ and Artemis are classic brokers without long history. Event Hubs doesn't support every Kafka feature at every tier.

## 7. Observability, security and operations

With no call stack across services, you can only operate what you measure.

### What to measure

| Method | For | Signals |
| --- | --- | --- |
| RED | services | Rate, Errors, Duration (p50, p99) |
| USE | resources | Utilization, Saturation (queues), Errors |
| Golden signals (Google SRE) | everything | latency, traffic, errors, saturation |

- **Measure p99, not averages.** If one request fans out to 100 servers that are each slow 1% of the time, 63% of requests are slow (1 − 0.99¹⁰⁰). Counter it with timeouts, hedged requests and less fan-out.
- **Prometheus metric types:** counter (requests, errors), gauge (memory, queue depth), histogram (latency buckets → `histogram_quantile(0.99, …)`). Beware cardinality: a user ID as a label creates millions of series.
- **Stack:** OpenTelemetry for instrumentation (metrics, traces, logs, with correlation IDs propagated through events), Prometheus to collect, Grafana to display. On Azure, Azure Monitor and Application Insights.
- **SLOs** come from the quality scenarios in section 1. Alert on SLO burn, not on noise.
- **Kafka:** alert on `UnderReplicatedPartitions > 0`, `OfflinePartitionsCount` and ISR shrinkage. Watch consumer lag per group and partition, time since the last commit, and producer error and retry rates (Burrow, Kafka UI, JMX exporter).

### Security in depth

- **Identity:** OAuth2/OIDC tokens (JWT) at the gateway, with the tenant ID in the token. Never build your own auth service; use Keycloak or Entra ID.
- **Service to service:** mTLS, via a service mesh if you need it.
- **Kubernetes:** namespaces as boundaries; RBAC with least privilege; no API token unless needed; **NetworkPolicy deny-all, then allow**; Pod Security Standards *restricted*; a hardened `securityContext`.
- **Secrets:** Key Vault or Vault via External Secrets; OIDC from CI; short-lived tokens; none in Git or Helm values.
- **Supply chain:** pin to SHAs, SBOMs, signed images, scanning, provenance (see section 4).
- **Data:** PII out of event keys; crypto-shredding for event-sourced data; a GDPR delete event fanned out to every replica owner.

### Operational readiness

- **Runbook basics:** `kubectl describe` and events, `logs --previous`, `helm history` / `rollback`, Argo CD sync status, consumer-group lag, offset reset for reprocessing.
- **Chaos testing:** if your service dies when someone else's DB dies, your boundaries are wrong (Netflix's Chaos Monkey).
- **Upgrade cadence:** Kubernetes ships 3 releases a year with \~1 year of patches, so upgrading is routine. Keep manifests and charts current (Ingress → Gateway API, Helm 3 → 4).
- **Concurrency limits:** bounded pools and queues, 429/503 with `Retry-After`, KEDA or HPA scaling on the right metric (lag, not CPU, for consumers).

## 8. Anti-patterns and project checklist

### Anti-patterns

| Anti-pattern | Instead |
| --- | --- |
| Shared database / shared tables | DB per service; contract via API or events |
| Split by technical layer or per entity (CRUD per table) | split by capability, subdomain or volatility |
| Building generic subdomains (own auth, payments) | buy or reuse: Keycloak, Stripe |
| Shared domain library across services | duplicate small code; publish contracts, not models |
| Long sync chains, > 10 calls per request | events, local replicas, coarse APIs, BFF |
| "Save then publish" (dual write) | transactional outbox + CDC |
| Retries at every layer | retry in one place, with backoff + jitter, for idempotent operations only |
| `SendEmail` disguised as an event | call it a command; send it via a queue |
| Publishing raw CDC table changes or internal domain events | translate to versioned integration events |
| No event schema ("JSON hell") | Schema Registry, defaults on new fields, never rename |
| Producing without a key | key = aggregate ID |
| Low-cardinality key (country) | high-cardinality key (order ID) |
| Thousands of partitions "just in case" | size from throughput, with headroom |
| Kafka as an event store or for sync RPC | event store with stream versions; HTTP, gRPC or NATS request-reply |
| Topic per table (CDC with no translation) | outbox with domain-shaped events |
| Large payloads in messages | claim check: file in Blob, link in the message |
| DB check in the liveness probe | liveness checks the process only |
| `:latest`, `kubectl exec` fixes, state in the container | immutable images, replace not patch |
| Building per environment | build once, promote by digest |
| Secrets in Git or Helm values; long-lived CI passwords | External Secrets, OIDC |
| Actions pinned to tags | pin to the commit SHA |
| Event sourcing everything | only where history carries value |
| Big-bang rewrite | strangler fig |

### Project checklist

Design

- [ ] Event Storming done; subdomains classified; bounded contexts and context map drawn
- [ ] Aggregates defined; one transaction = one aggregate
- [ ] Each service passes the deploy, change, failure, data-ownership and team tests
- [ ] Key decisions recorded as ADRs; C4 level-2 diagram in the repo

Contracts

- [ ] OpenAPI 3.1 / AsyncAPI 3 in the repo, contract first, linted (Spectral), diffed (oasdiff), Pact in CI
- [ ] Commands in the imperative, events in the past tense, CloudEvents envelope, version in the type
- [ ] REST: intent endpoints, `Idempotency-Key`, problem+json, cursor pagination, ETags

Data

- [ ] DB (at least a schema) per service; no cross-boundary FKs; one writer per piece of data
- [ ] Outbox for every state change that emits an event; inbox and version checks in every consumer
- [ ] Sagas with explicit pivot, compensations and isolation countermeasures; compensation path tested
- [ ] Read strategy chosen deliberately per view: composition, replica or CQRS

Events

- [ ] Queue vs log chosen by model; key = aggregate ID; partitions planned with headroom
- [ ] RF 3, `min.insync.replicas=2`, `acks=all`, idempotent producer
- [ ] At least once + idempotent consumer; commit after processing
- [ ] Retry topics + DLQ so poison pills don't block a partition
- [ ] Schema Registry; new fields with defaults; never rename
- [ ] Monitor consumer lag and scale on it (KEDA)

Runtime

- [ ] Twelve-factor; stateless; config from env; logs to stdout
- [ ] Timeouts everywhere, one retry layer, circuit breakers, bulkheads, fallbacks, bounded queues
- [ ] Three probes done right; requests + memory limit; graceful shutdown; non-root, hardened
- [ ] ≥ 2 replicas, PDB, zone spread; HPA or KEDA
- [ ] Gateway API (HTTPRoute) for ingress; NetworkPolicy deny-all

Delivery

- [ ] One Helm chart per service; values per environment; schema-validated values; lint, template, diff in CI
- [ ] Pipeline: test → scan → SBOM → sign → push by SHA → staging → approval → prod; same artifact everywhere
- [ ] GitOps (Argo CD) with prune + selfHeal; canary for risky changes
- [ ] Infrastructure in Terraform/OpenTofu or Bicep; plan on PR, apply on merge; remote locked state
- [ ] Actions pinned to SHAs; least-privilege `permissions`; OIDC; Dependabot or Renovate

Operations

- [ ] RED metrics + p99 + traces via OpenTelemetry; SLOs and alerts from quality scenarios
- [ ] DORA metrics tracked per team

The database holds state. The log holds history. The bus carries facts, and must not lose them.
