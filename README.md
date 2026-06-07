# Git Integration Branch Guard

[简体中文](README.zh-CN.md)

Git Integration Branch Guard is a portable Agent Skill for repositories that use shared development, testing, UAT, staging, or integration branches.

It teaches an agent one critical rule:

> Shared validation branches are collection or promotion pools, not upstreams for scoped work.

Work branches may flow into shared validation branches for testing or promotion, but those shared branches must not flow back into scoped work branches or production.

## Why This Exists

Many teams use shared branches such as `dev`, `test`, `uat`, or `staging` to deploy or validate multiple in-flight changes together. Those branches are useful for testing and promotion, but dangerous as upstream sources.

If a scoped work branch merges, rebases, pulls, or cherry-picks from a shared validation branch, it can silently absorb unrelated unfinished work. Later, when that work branch is released, those unrelated changes may ship too.

This skill turns that branch policy into explicit agent behavior:

- identify source and target before branch-changing commands
- refuse unsafe shared-validation-to-work or shared-validation-to-production flows
- suggest syncing from production instead
- audit branch history before release
- keep work branches scoped and production releases clean

## Repository Layout

```text
git-integration-branch-guard/
├── .github/
│   └── workflows/
│       └── ci.yml
├── .editorconfig
├── .gitattributes
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── SKILL.md
├── README.md
├── README.zh-CN.md
├── LICENSE
├── scripts/
│   └── audit-branch-flow.sh
└── tests/
    └── audit-branch-flow-tests.sh
```

## Skill Format

This repository follows the Agent Skills format:

```text
skill-name/
├── SKILL.md          # Required: YAML frontmatter + Markdown instructions
├── scripts/          # Optional: executable helper scripts
├── references/       # Optional: extra documentation loaded on demand
└── assets/           # Optional: static templates or resources
```

Only `SKILL.md` is required. This skill includes one optional shell script because release-readiness audits are safer when the repetitive Git checks are encoded as a deterministic command.

## Installation

As an Agent Skill:

1. Copy or clone this directory into your agent runtime's skills directory.
2. Keep `SKILL.md` and `scripts/audit-branch-flow.sh` together so the skill can reference the helper script.
3. Enable or load the skill according to your agent runtime's instructions.

As a standalone audit helper:

1. Copy `scripts/audit-branch-flow.sh` into a repository or shared tooling directory.
2. Run it from inside the Git work tree you want to audit.
3. If the script is outside the repository, call it by absolute path.

## Workflow Overview

Allowed:

```text
production -> work branch
production -> shared validation branch
work branch -> shared validation branch
work branch -> production
shared validation branch -> later shared validation branch
```

The last direction is allowed only when the repository explicitly defines an environment promotion path, such as `dev -> test -> uat`.

Forbidden:

```text
shared validation branch -> work branch
shared validation branch -> production
```

The default branch names in the skill are examples only:

- production: `main`, `master`, `trunk`, `prod`, `production`, `release`, or custom names
- shared validation branches: `dev`, `develop`, `test`, `qa`, `uat`, `stage`, `staging`, `preprod`, `integration`, or custom names
- work branches: `feat/*`, `feature/*`, `features/*`, `fix/*`, `bugfix/*`, `hotfix/*`, `chore/*`, `refactor/*`, `task/*`, `ticket/*`, or team-specific names

Do not rely on prefixes alone. A work branch is any scoped branch intended to release a bounded change to production, even if its name is `features/foo`, `user/foo`, `ticket-123`, or something else.

Do not rely on branch names alone. In one repository `dev` may be a shared validation branch; in another it may be a scoped development branch, a long-lived environment branch, or part of a promotion chain. Map roles before applying rules.

Map these roles to your repository before applying the rules.

## Using The Audit Script

The script needs a Bash environment. On Windows, run it from Git Bash (bundled with Git for Windows) or WSL.

From a Git work tree:

```bash
scripts/audit-branch-flow.sh --production origin/main --integration dev
```

Audit another branch:

```bash
scripts/audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/test --integration origin/uat --head feature/example
```

The script exits with:

- `0` when no obvious shared-validation branch contamination is found
- `1` when possible contamination is detected
- `2` for usage or environment errors

Pass `--integration` more than once when the repository has multiple shared validation branches.

The script checks three signals:

- merge commits or commit subjects that mention shared validation branch names, matched as literal text
- merge commits whose non-first parent is reachable from a configured shared validation branch, when that branch ref exists locally
- the full non-merge commit list in the release range for manual review

The script is intentionally conservative. It is a release-readiness aid, not a proof that a branch is clean. Rebases, cherry-picks, copied patches, deleted refs, rewritten history, and custom repository workflows may still require manual review.

## Development Checks

Run these before publishing changes:

```bash
bash -n scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
bash tests/audit-branch-flow-tests.sh
shellcheck scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
```

GitHub Actions runs the same checks on pushes and pull requests: ShellCheck on Linux, and the syntax check and test suite on Linux, macOS, and Windows (Git Bash), so the Bash 3.2 baseline and Windows compatibility stay verified.

## Example Requests This Skill Should Catch

- "Create a feature branch for this fix."
- "Bring this branch up to date."
- "Merge this work branch into dev for testing."
- "Pull dev into this feature branch."
- "Rebase this fix branch on staging."
- "Pull uat into my local work branch."
- "Promote dev to test."
- "Merge develop to main."
- "Review this branch before release."

## Recommended Commit Style

If you publish changes to this repository, keep commit messages product-neutral and tool-neutral. Good examples:

```text
docs: add Chinese README
feat: add branch flow audit script
fix: clarify integration branch release rule
```

Avoid mentioning a specific assistant runtime, product, or internal project in commit messages.

## Contributing And Security

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

MIT. See [LICENSE](LICENSE).
