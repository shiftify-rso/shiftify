# Shift Scheduler — Implementation Spec

## 1. Scope
A shift scheduling app for small organizations (≤50 employees, one location, a few sectors), built as a course/demo project. The domain is generic: industry-specific behavior comes only from configurable rules.

**In scope**
- Org/sector/employee management
- Schedule editing and publishing
- Configurable views
- Availability and time off
- Coverage requests and swaps
- An auto-scheduler with configurable rules
- Notifications

**Out of scope**
- Time & attendance
- Payroll
- Reports
- Calendar sync
- Integrations
- Multi-tenancy
- i18n

**Roles**
| Role | Can |
|---|---|
| Admin | Manage org, sectors, employees, rules |
| Manager | Edit and publish schedules for their sectors; approve time off and swaps; run the auto-scheduler |
| Employee | View published schedules; set availability; request time off, coverage and swaps |

---

## 2. Data model

| Entity | Key fields |
|---|---|
| **Sector** | id, name, color |
| **Position** | id, sector_id, name, required_skill_ids[] |
| **Employee** | id, name, email, role, seniority (`intern`/`junior`/`mid`/`senior`), skill_ids[], sector_ids[], contract_hours_per_week |
| **Skill** | id, name |
| **ShiftTemplate** | id, sector_id, name, start_time, end_time, days_of_week[], slots[] (see Shift) |
| **Shift** | id, sector_id, start (datetime), end (datetime), slots[]: { position_id, count } |
| **Assignment** | id, shift_id, position_id, employee_id, locked (bool) |
| **Schedule** | id, sector_ids[], period_start, period_end, status (`draft`/`published`), version, published_at |
| **Availability** | id, employee_id, kind (`unavailable`/`prefer_not`/`prefer`), recurring rule (day_of_week + time range) or specific date range |
| **TimeOffRequest** | id, employee_id, start, end, reason, status (`pending`/`approved`/`rejected`) |
| **Rule** | id, type, scope (`global` or sector_id), hard (bool), weight, params (JSON) |
| **SwapRequest** | see §5 |
| **SavedView** | id, owner_id, name, config (JSON, see §6) |
| **Notification** | id, employee_id, type, payload, read |

**Time handling**
- All datetimes are stored with the org's single time zone.
- A shift may cross midnight (`end > start` on the next day).
- Durations are computed from actual timestamps, so DST nights come out correct.

---

## 3. Rules

Rules are data, not code. Each rule has a `type` with typed `params`. A sector-scoped rule overrides a global rule of the same type. Every rule can be **hard** (must hold) or **soft** (a violation costs `weight` points).

### Built-in rule types

| Type | Params | Semantics |
|---|---|---|
| `max_hours_per_day` | `hours` | Sum of an employee's shift hours that **start** on a calendar day ≤ `hours` |
| `max_hours_per_week` | `hours` | Sum of shift hours starting in a Mon–Sun week ≤ `hours`; counted across all sectors |
| `min_rest_between_shifts` | `hours` | Gap between the end of one shift and the start of the employee's next ≥ `hours` |
| `max_consecutive_days` | `days` | Number of consecutive calendar days with ≥1 shift ≤ `days` |
| `min_seniority_count` | `level`, `count` | Each shift has ≥ `count` assigned employees with seniority ≥ `level` |
| `max_seniority_count` | `level`, `count` | Each shift has ≤ `count` assigned employees with seniority ≤ `level` |
| `required_skills` | — | An employee assigned to a position has all of its `required_skill_ids` (always hard) |
| `respect_unavailability` | — | No assignment overlaps `unavailable` availability or approved time off (always hard) |
| `respect_preferences` | — | Penalty for each assignment overlapping `prefer_not`; bonus for overlapping `prefer` (soft) |
| `contract_hours_target` | `tolerance_hours` | Penalty per hour the weekly hours fall outside contract ± tolerance (soft) |
| `fair_distribution` | `kind` (`night`/`weekend`) | Penalty for the difference between the max and min number of night or weekend shifts across employees (soft) |

**Examples**
- "Two juniors/interns aren't enough, need a senior": `min_seniority_count { level: senior, count: 1 }`.
- "At most one intern per shift": `max_seniority_count { level: intern, count: 1 }`.

**Definitions**
- A **night shift** is one that overlaps 22:00–06:00.
- A **weekend shift** is one that starts on Saturday or Sunday.

### Validation
A single `validate(assignments, context)` function returns a list of violations:

```
{ rule_id, hard, employee_id?, shift_id?, message }
```

Three features use it:
- live warnings while editing (§4)
- swap eligibility (§5)
- solver result reporting (§7)

Example message: "Ana: 46h in week 45 exceeds 40h".

---

## 4. Schedule editing
- A manager creates a draft schedule for a period and sectors, either empty, from templates, or from an auto-scheduler proposal.
- Shifts and assignments can be created, moved and deleted. Assignments can be locked.
- **Every change runs `validate`.**
  - Hard violations show as errors.
  - Soft violations show as warnings.
  - Publishing is allowed with violations only if the manager confirms an override (the override is logged).
- **Publishing:**
  - sets `status = published` and increments `version`
  - makes the schedule visible to employees
  - triggers notifications
- **Editing a published schedule** applies the change immediately, bumps the version, and notifies the affected employees.

---

## 5. Coverage requests and swaps

**Request types**
- **Coverage:** the employee gives away their assignment.
- **Swap:** the employee exchanges their assignment for one of a coworker's.

**State machine**
```
open ──(coworker accepts)──► accepted ──(manager approves)──► applied
  │                             └──(manager rejects)──► rejected
  ├──(requester cancels)──► cancelled
  └──(shift starts)──► expired
```

**Eligibility.** A coworker is shown the request only if both of these hold:
1. They are in the shift's sector and have the position's required skills.
2. `validate` produces **no hard violations** after the change. For a swap, both sides are checked.

**Applying the change**
- On approval, eligibility is re-validated, since the schedule may have changed in the meantime.
- If the change is still valid, the assignment(s) are updated, the version bumps, and both employees are notified.

---

## 6. Views

Views apply to **published** schedules for employees, and to draft or published schedules for managers.

| View | Description |
|---|---|
| **Week grid** | Days as columns, shifts as cards, grouped by sector |
| **Timeline** | One row per employee (or per position), with time on the x-axis; shows overlaps and gaps |
| **My schedule** | The current employee's upcoming shifts as a list or calendar, mobile-friendly |
| **Coverage** | Required vs assigned headcount per shift or hour, with under- and over-staffing highlighted |

The view config is saveable as a `SavedView`:

```json
{
  "type": "timeline",
  "range": "week",
  "sector_ids": [],
  "group_by": "employee | position | sector",
  "color_by": "sector | seniority | position",
  "filters": { "seniority": [], "skill_ids": [], "employee_ids": [] }
}
```

---

## 7. Auto-scheduler

**Input**
- Period and sectors
- Shifts with their slots
- Employees
- Availability and approved time off
- Rules in effect
- Locked assignments
- `num_proposals` (default 3, max 5)

**Model (CP-SAT or equivalent)**
- **Variables:** `x[e, s, p] ∈ {0,1}` means employee *e* is assigned to shift *s*, position *p*.
- **Locked assignments** are fixed to 1.
- **Hard rules** become constraints.
- **Slot filling:**
  - Each slot `(s, p)` gets an `unfilled[s, p] ≥ 0` variable.
  - The constraint is `Σ x + unfilled = count`.
  - `unfilled` carries a very large penalty. This means the solver always returns a result instead of reporting "infeasible".
- **Soft rules** become weighted penalty terms. The objective is to minimize `Σ penalties`.

**Multiple proposals**
- After each solution, add a constraint that the next solution must differ in ≥ 10% of assignments.
- Repeat until `num_proposals` solutions are found or the time limit is reached.

**Output**, per proposal:
- assignments
- total score
- per-rule penalty breakdown
- list of soft violations
- list of unfilled slots

Each unfilled slot comes with a reason derived from eligibility, e.g. "Sat 22:00 Kitchen: needs 1 senior, 0 eligible (Marko on time off, Ana exceeds 40h)".

**Running a job**
- Jobs run asynchronously. Status goes `queued → running → done | failed`.
- Time limit: 30s.
- The manager compares proposals side by side, applies one to the draft, then edits it manually.

---

## 8. Notifications
- In-app notifications, plus email.

**Triggers**
| Event | Recipients |
|---|---|
| Schedule published | Everyone in the schedule |
| Schedule changed after publishing | The affected employees |
| Coverage/swap request | Eligible coworkers |
| Swap accepted, approved, rejected or expired | The participants |
| Time off approved or rejected | The requester |

---

## 9. Acceptance criteria

**Org & employees**
- Admin can create sectors, positions (with required skills), skills, and employees (with seniority, skills, sectors and contract hours).

**Schedule editing**
- A manager can create a draft from templates for a given week.
- Assigning an employee beyond `max_hours_per_week` immediately shows an error naming the employee, the rule and the hours.
- Employees cannot see a draft. After publishing, they see it and receive a notification.

**Views**
- All four views render the same schedule consistently.
- Filtering by sector or seniority works in every view.
- A saved view restores its exact config.
- The coverage view highlights a shift with fewer assignees than required.

**Availability & time off**
- An `unavailable` slot or approved time off prevents both manual assignment (error) and auto-assignment.
- `prefer_not` produces only a warning or penalty.

**Coverage & swaps**
- Given a shift whose only senior requests coverage, only coworkers whose assignment keeps `min_seniority_count` satisfied see the request.
- A swap that would break a hard rule at approval time is rejected with the violation shown.
- An approved swap updates both assignments and notifies both employees.

**Auto-scheduler**
- For a feasible week, the auto-scheduler returns ≥2 distinct proposals with no hard violations.
- Locked assignments are present in every proposal.
- Changing a sector-scoped rule changes that sector's result but not others. For example, raising the min seniors from 1 to 2 for one sector.
- For an infeasible week, the result lists the unfilled slots, each with a reason.

**Demo scenario**
1. Seed 15 employees across 3 sectors (mixed seniority).
2. Employees submit availability, and one time-off request is approved.
3. Generate 3 proposals for a week, pick one, tweak it, and publish.
4. A senior requests coverage. Only eligible coworkers are offered the shift; one accepts and the manager approves.
5. A junior tries to take a senior-required shift alone. The swap is blocked by the rule.
