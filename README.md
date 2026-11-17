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

```sh
git clone --recurse-submodules https://github.com/shiftify-rso/shiftify.git
git submodule update --remote   # pull the latest main of every component
```

## License
[Apache-2.0](LICENSE)
