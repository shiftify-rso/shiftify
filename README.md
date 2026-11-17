# Shiftify

Shift scheduling for small organizations: rule-aware schedule editing, an auto-scheduler that proposes schedules, and coverage and swap requests. RSO 2026/27, group 8 (Shifters).

- [General spec](docs/SPEC.md): what we build, plus every decided technology
- [Microservices guide](docs/microservices-guide.md): the lecture best practices behind those decisions
- [Build plan](docs/build-plan.md): build order (walking skeleton first)
- [Service spec template](docs/service-spec-template.md)
- [AGENTS.md](AGENTS.md): rules for AI coding agents

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
This clones the repo into `./shiftify`, or updates an existing clone. It checks every submodule out on `main` at its latest commit and sets `pull.rebase`. Rerun it any time to update everything; from inside a clone, run `scripts/setup.sh .`. Before pushing, log in with `gh auth login`.

## Development

### Where to work
Open the **`shiftify` root** in your editor or agent, not a single service. The root holds the specs and every component side by side, so cross-service changes stay visible. Each submodule is still its own git repo: branch, commit and open PRs **inside that submodule's folder**.

### Specs before code
- **[`docs/SPEC.md`](docs/SPEC.md)** fixes the domain, the service boundaries, the interactions and the technology. It is binding.
- Each service repo has its own **`SPEC.md`**, which resolves the open `[O-n]` items the general spec leaves to that service.
- **Order of work:** decide, write the decision into the spec, then implement. A spec change goes in the same PR as the code it describes.
- **Changing a decided item** means editing `docs/SPEC.md` first, in its own PR, agreed by the team.

**Why:** there are 11 repos and 3 people. Specs are the only place where the whole picture lives.

### Docs per repo
Each component repo documents itself, so someone with only that repo can understand, run and reuse the service:

| File | Contents |
|---|---|
| `README.md` | what it does, how to run and test it locally, configuration |
| `SPEC.md` | design and resolved `[O-n]` decisions |
| `contracts/` | OpenAPI / AsyncAPI / proto / GraphQL schema, event JSON Schemas |
| `docs/` | optional: diagrams, runbooks, longer notes |

These are updated in the same PR as the code. This repo only holds cross-service docs.

### Branches and PRs
- **Only `main` exists long-term.** Work happens on short-lived branches, e.g. `staff-crud`.
- **Every change reaches `main` through a PR.** A ruleset on all 12 repos blocks direct pushes, force-pushes and deleting `main`, with no admin bypass.
- **No approval is required**, so you can merge your own PR and are never blocked by an absent teammate. Once a repo has CI, its checks will be required.
- **Squash merge only.** Each PR becomes one commit on `main`, its message is the PR title, and history stays linear. **Why:** clean history, with no "Merge pull request…" or "Merge branch…" commits.
- `pull.rebase=true` (set by `setup.sh`) replays your local commits on top of what you pull instead of creating merge commits.

### Commit messages and PR titles
Short, lowercase and imperative, with no articles or filler, just enough to say what changed:
```
add employee crud endpoints
fix rest-gap rule across midnight
```
Don't add `Co-Authored-By` or other trailers. The PR title becomes the squash commit, so the same style applies to PR titles.

### Releases and deploys
- A **release** is a version tag `vX.Y.Z` on a component. CI builds images tagged with the git SHA (and the version on tags) and pushes them to GHCR.
- A **deploy** is a PR to `infra` that bumps image versions. Argo CD syncs the cluster from `infra`, so merging the PR deploys, and reverting it rolls back. **Why:** this is GitOps. The cluster always matches Git, and CI never holds cluster credentials.
- **Submodule pointers** in this repo are bumped only when tagging a release or demo snapshot:
  ```sh
  git switch -c release/v0.1.0
  git submodule update --remote && git commit -am "bump submodules for v0.1.0"
  gh pr create --fill && gh pr merge --squash --delete-branch
  git switch main && git pull && git tag v0.1.0 && git push --tags
  ```
  **Why not a bot:** an Action opening PRs needs the org setting "Actions may create and approve PRs", which could later bypass required reviews. `setup.sh` always pulls the latest `main` of every component anyway.

### CI (planned per repo, GitHub Actions)
- **On a PR:** build, unit and Testcontainers tests, contract checks (oasdiff, Apicurio compatibility), static analysis.
- **On `main` and tags:** image build, Trivy scan, SBOM, cosign signature, push to GHCR.
- **Also:** Dependabot. Actions pinned to commit SHAs with least-privilege `permissions`.

### Local environment (planned)
A kind cluster plus Tilt, using the same Helm charts as AKS, set up from `infra`. The AKS demo cluster is created and destroyed with OpenTofu to save credit.

## License
[Apache-2.0](LICENSE)
