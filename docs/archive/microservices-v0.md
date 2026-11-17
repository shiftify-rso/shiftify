# Shift Scheduler — Suggested Microservices

Eight services, each owning its own data. Section references (§) point to SPEC.md.

| # | Service | Owns | Spec |
|---|---|---|---|
| 1 | Organization | Sector, Position, Skill, Employee | §2, §9 Org |
| 2 | Auth | credentials, roles, tokens | §1 Roles |
| 3 | Schedule | Schedule, Shift, ShiftTemplate, Assignment, override log | §4 |
| 4 | Rules & Validation | Rule, `validate()` | §3 |
| 5 | Availability | Availability, TimeOffRequest | §2, §9 Availability |
| 6 | Swap | SwapRequest (coverage + swap) | §5 |
| 7 | Auto-scheduler | solver jobs, proposals | §7 |
| 8 | Notification | Notification, email delivery | §8 |

Optional: **Views** (SavedView, §6) — small enough to live inside Schedule, but can be split out.

---

## 1. Organization service
Master data for the org.
- CRUD for sectors, positions (with required skills), skills, employees (seniority, skills, sectors, contract hours).
- Other services read employee/position data from here (or cache it from `employee.updated` events).

**API:** `/sectors`, `/positions`, `/skills`, `/employees`

## 2. Auth service
Login and role checks for Admin / Manager / Employee.
- Issues JWTs carrying `employee_id`, `role`, and the manager's `sector_ids`.
- Other services only verify the token; they don't call Auth per request.

**API:** `POST /login`, `POST /refresh`, `GET /me`

## 3. Schedule service
The core: drafts, shifts, assignments, publishing.
- Create a draft (empty, from templates, or from an auto-scheduler proposal).
- Create/move/delete shifts and assignments; lock assignments.
- Calls **Rules & Validation** on every change and returns violations to the UI.
- Publish (with logged override if violations exist), bump version.
- Hides drafts from employees.

**API:** `/schedules`, `/schedules/{id}/shifts`, `/assignments`, `POST /schedules/{id}/publish`, `/templates`
**Emits:** `schedule.published`, `schedule.changed` (with affected employee ids)

## 4. Rules & Validation service
Rules as data plus the single `validate(assignments, context)` function.
- CRUD for rules (global or sector-scoped, hard/soft, weight, params).
- Resolves which rules apply (sector rule overrides global).
- `POST /validate` takes assignments + context and returns `{ rule_id, hard, employee_id?, shift_id?, message }[]`.
- Used by Schedule (live warnings), Swap (eligibility), Auto-scheduler (result reporting).

**API:** `/rules`, `GET /rules/effective?sector_id=`, `POST /validate`

## 5. Availability service
Employee availability and time off.
- Recurring or date-range availability (`unavailable` / `prefer_not` / `prefer`).
- Time-off requests with manager approve/reject.
- Supplies availability + approved time off to Validation and Auto-scheduler.

**API:** `/availability`, `/time-off`, `POST /time-off/{id}/approve|reject`
**Emits:** `timeoff.approved`, `timeoff.rejected`

## 6. Swap service
Coverage and swap requests with the §5 state machine.
- `open → accepted → applied | rejected`, plus `cancelled` and `expired`.
- Eligibility: same sector + required skills (from Organization), then no hard violations via `POST /validate` (both sides for a swap).
- On manager approval: re-validate, then ask Schedule to update the assignment(s).
- Expires open requests when the shift starts (scheduled job).

**API:** `/requests`, `GET /requests/eligible` (for the current employee), `POST /requests/{id}/accept|approve|reject|cancel`
**Emits:** `swap.requested` (with eligible employee ids), `swap.accepted`, `swap.applied`, `swap.rejected`, `swap.expired`

## 7. Auto-scheduler service
Async CP-SAT solver producing 1–5 proposals.
- Gathers input: shifts + locked assignments (Schedule), employees (Organization), availability/time off (Availability), effective rules (Rules).
- Runs as a job: `queued → running → done | failed`, 30s limit. A worker pulls jobs from a queue.
- Returns per proposal: assignments, score, per-rule penalty breakdown, soft violations, unfilled slots with reasons.
- Applying a proposal = Schedule service copies its assignments into the draft.

**API:** `POST /jobs`, `GET /jobs/{id}`, `GET /jobs/{id}/proposals`
**Emits:** `solver.job.done`, `solver.job.failed`

## 8. Notification service
In-app + email notifications.
- Subscribes to events from the other services and maps them to recipients (§8 trigger table).
- Stores in-app notifications; sends email (SMTP or a dev mail catcher like MailHog).

**API:** `GET /notifications`, `POST /notifications/{id}/read`
**Consumes:** `schedule.published`, `schedule.changed`, `swap.*`, `timeoff.*`, `solver.job.done`

---

## Communication
- **Sync (REST):** reads and validation calls, e.g. Schedule → Rules `POST /validate`, Swap → Schedule to apply.
- **Async (message broker, e.g. RabbitMQ):** events consumed by Notification, and solver job queue.
- **API gateway** in front: routes `/api/<service>/…`, verifies JWTs.
