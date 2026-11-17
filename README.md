# Shiftify

Shift scheduling for small organizations: rule-aware schedule editing, an auto-scheduler that proposes schedules, and coverage and swap requests. RSO 2026/27, group 8 (Shifters).

- [General spec](docs/SPEC.md)
- [Microservices guide](docs/microservices-guide.md)
- [Service spec template](docs/service-spec-template.md)

## Repositories
Every component is its own repo, included here as a submodule.

| Path | Repo |
|---|---|
| `services/staff` | [staff](https://github.com/shiftify-rso/staff) |
| `services/auth` | [auth](https://github.com/shiftify-rso/auth) |
| `services/notification` | [notification](https://github.com/shiftify-rso/notification) |
| `services/schedule` | [schedule](https://github.com/shiftify-rso/schedule) |
| `services/rules` | [rules](https://github.com/shiftify-rso/rules) |
| `services/availability` | [availability](https://github.com/shiftify-rso/availability) |
| `services/swap` | [swap](https://github.com/shiftify-rso/swap) |
| `services/autoscheduler` | [autoscheduler](https://github.com/shiftify-rso/autoscheduler) |
| `bff` | [bff](https://github.com/shiftify-rso/bff) |
| `web` | [web](https://github.com/shiftify-rso/web) |
| `infra` | [infra](https://github.com/shiftify-rso/infra) |

## Setup
```sh
curl -fsSL https://raw.githubusercontent.com/shiftify-rso/shiftify/main/scripts/setup.sh | bash
```
This clones the repo into `./shiftify` (or updates an existing clone) and checks every submodule out on `main` at its latest commit. Rerun it any time to update everything. From inside a clone, run `scripts/setup.sh .`

## Releases
Submodule pointers are only bumped at release or demo time, in a PR:
```sh
git switch -c release/v0.1.0
git submodule update --remote && git commit -am "bump submodules for v0.1.0"
gh pr create --fill && gh pr merge --squash --delete-branch
git switch main && git pull && git tag v0.1.0 && git push --tags
```

## License
[Apache-2.0](LICENSE)
