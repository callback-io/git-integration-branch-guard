# Git Integration Branch Guard

[简体中文](README.zh-CN.md)

Git Integration Branch Guard is a portable Agent Skill for repositories that use shared development, testing, UAT, staging, or integration branches.

I built this after getting burned repeatedly: my AI coding agent kept merging `dev` into my feature branches to "bring them up to date", and kept creating new work branches from `dev` when they should have started from `main`. Each time, other people's unfinished work quietly followed my branch toward release.

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
├── .claude-plugin/
│   ├── plugin.json            # Claude Code plugin metadata
│   └── marketplace.json       # marketplace manifest for /plugin marketplace add
├── .github/
│   └── workflows/
│       └── ci.yml
├── action.yml                 # GitHub Action wrapper around the audit script
├── hooks/
│   └── hooks.json             # PreToolUse hook registration (plugin install only)
├── install.sh                 # copies the skill into detected agent runtimes
├── schema/
│   └── branch-guard.schema.json
├── scripts/
│   └── guard-git-command.sh   # the PreToolUse command guard
├── skills/
│   └── git-integration-branch-guard/
│       ├── SKILL.md
│       └── scripts/
│           └── audit-branch-flow.sh
├── tests/
│   ├── audit-branch-flow-tests.sh
│   ├── guard-git-command-tests.sh
│   └── install-tests.sh
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── README.md
├── README.zh-CN.md
└── LICENSE
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

Only `SKILL.md` is required. This skill includes one optional shell script because release-readiness audits are safer when the repetitive Git checks are encoded as a deterministic command. The skill lives in `skills/git-integration-branch-guard/`, which is the directory to copy when installing it by hand.

## Installation

Pick the path that matches your tooling. Every path below installs the same skill; only the Claude Code plugin additionally registers the command guard hook.

### As a Claude Code plugin (skill + command guard hook)

```text
/plugin marketplace add callback-io/git-integration-branch-guard
/plugin install git-integration-branch-guard@git-integration-branch-guard
```

This is the only install path that enables the PreToolUse command guard, because plugin installation is the flow where Claude Code asks for your consent to register hooks. Runtimes that can install Claude Code marketplace plugins, such as Qwen Code, get the same package.

### With the installer (any Agent Skills runtime)

```bash
git clone https://github.com/callback-io/git-integration-branch-guard
cd git-integration-branch-guard
./install.sh --list   # preview detected runtimes first
./install.sh          # copy the skill into each detected runtime
```

The installer detects `~/.claude`, `~/.codex` (honors `$CODEX_HOME`), `~/.gemini`, and `~/.qwen`, and copies the skill into each runtime's `skills` directory. Use `--target <dir>` for any other runtime, `--project` for the current repository's `.claude/skills`, and `--update` to refresh an older copy. The installer only copies skill files; it never edits agent settings or registers hooks.

### Installation for AI agents

If you want your coding agent to install this skill for you, point it at this repository and ask it to follow these steps:

```bash
git clone https://github.com/callback-io/git-integration-branch-guard /tmp/git-integration-branch-guard
/tmp/git-integration-branch-guard/install.sh --list
/tmp/git-integration-branch-guard/install.sh
```

Review the installer before running it. It is intentionally limited to copying files into skills directories, so granting it execution is low risk; do not pipe it from the network into a shell.

### By hand

1. Copy `skills/git-integration-branch-guard/` into your agent runtime's skills directory.
2. Keep `SKILL.md` and `scripts/audit-branch-flow.sh` together so the skill can reference the helper script.
3. Enable or load the skill according to your agent runtime's instructions.

### As a standalone audit helper

1. Copy `skills/git-integration-branch-guard/scripts/audit-branch-flow.sh` into a repository or shared tooling directory.
2. Run it from inside the Git work tree you want to audit.
3. If the script is outside the repository, call it by absolute path.

### Platform support

The skill follows the [Agent Skills](https://agentskills.io) open standard, so any compliant runtime can load it, including the desktop and web surfaces that share their CLI's skill directory:

| Runtime | Skill | Command guard hook | Install |
|---|---|---|---|
| Claude Code (CLI, desktop, web) | yes | yes | plugin or installer |
| Qwen Code | yes | via Claude Code marketplace compatibility | plugin or installer |
| OpenAI Codex (CLI, desktop app) | yes | no | installer (`~/.codex/skills`) |
| Gemini CLI | yes | no | installer (`~/.gemini/skills`) |
| Cursor, GitHub Copilot, OpenCode, others | yes | no | by hand into the runtime's skills directory |

Runtimes without hook support still get two protection layers: the skill guides the agent before it acts, and the audit script (or the GitHub Action) verifies history before release.

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

## Repository Configuration

Declare your branch roles once in `.branch-guard.json` at the repository root, and the skill, the command guard hook, and the audit script all read the same policy:

```json
{
  "$schema": "https://raw.githubusercontent.com/callback-io/git-integration-branch-guard/main/schema/branch-guard.schema.json",
  "production": ["main"],
  "integration": ["dev", "staging"],
  "workPatterns": ["feat/*", "fix/*"],
  "promotionPaths": ["dev->staging"],
  "enforcement": "deny"
}
```

- `production` and `integration` accept branch names or glob patterns; anything else is a work branch.
- `promotionPaths` lists the only allowed shared-environment promotions, as `source->target`.
- `enforcement` controls the command guard hook: `deny` blocks forbidden flows, `ask` defers to the user, `warn` allows them with a warning.

Without the file, the guard falls back to common branch names (`main`/`master`/... as production, `dev`/`test`/`staging`/... as validation pools). Keep the file flat — string arrays and string scalars only — so the shell-only consumers can parse it. A repository-specific agent skill often reduces to this one file plus the generic skill.

## Command Guard Hook (Claude Code plugin)

When installed as a Claude Code plugin, `scripts/guard-git-command.sh` runs as a PreToolUse hook on every Bash tool call and blocks git flows that violate the one-way policy before they execute:

- `merge`, `rebase`, `pull`, and `reset --hard` that bring a shared validation branch into a work or production branch
- new branches started from a shared validation branch (`switch -c`, `checkout -b`, `branch`)
- push refspecs that land a validation branch on production (`push origin dev:main`)
- shared-environment promotions that are not declared in `promotionPaths`
- cherry-picks of commits that are reachable only from a validation branch (answered with `ask`, because the origin of a copied commit is ambiguous)

The hook fails open: when the payload cannot be parsed, no JSON parser is available, or the directory is not a Git work tree, it stays silent and never blocks normal work. Set `BRANCH_GUARD_DISABLE=1` to bypass it temporarily. The skill remains the first layer (guidance before action) and the audit script the last (verification before release); the hook is the enforcement layer in between.

## Using The Audit Script

The script needs a Bash environment. On Windows, run it from Git Bash (bundled with Git for Windows) or WSL.

From a Git work tree:

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh --production origin/main --integration dev
```

In a repository with `.branch-guard.json`, no arguments are needed:

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh
```

Audit another branch:

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/test --integration origin/uat --head feature/example
```

The script exits with:

- `0` when no obvious shared-validation branch contamination is found
- `1` when possible contamination is detected, or with `--strict` when only advisory patch-id matches are found
- `2` for usage or environment errors

Pass `--integration` more than once when the repository has multiple shared validation branches.

The script checks four signals:

- merge commits or commit subjects that mention shared validation branch names, matched as whole words of literal text
- merge commits whose non-first parent is reachable from a configured shared validation branch, when that branch ref exists locally
- commits whose stable patch-id also exists on a shared validation branch under a different hash, which catches cherry-picked or rebased copies with rewritten messages (advisory; disable with `--no-check-patch-id`)
- the full non-merge commit list in the release range for manual review

The script is intentionally conservative. It is a release-readiness aid, not a proof that a branch is clean. Copied patches, deleted refs, rewritten history, and custom repository workflows may still require manual review.

## GitHub Action

Run the same audit on every pull request that targets production:

```yaml
name: branch-guard
on:
  pull_request:
    branches: [main]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: callback-io/git-integration-branch-guard@main
        with:
          production: origin/main
          integration: dev,staging
```

`fetch-depth: 0` is required because the audit needs full history. Inputs `production` and `integration` are optional when the repository contains `.branch-guard.json`; set `strict: "true"` to also fail on advisory patch-id matches. This extends the guard beyond agents to every human contributor.

## Development Checks

Run these before publishing changes:

```bash
bash -n skills/git-integration-branch-guard/scripts/audit-branch-flow.sh scripts/guard-git-command.sh install.sh tests/*.sh
bash tests/audit-branch-flow-tests.sh
bash tests/guard-git-command-tests.sh
bash tests/install-tests.sh
shellcheck skills/git-integration-branch-guard/scripts/audit-branch-flow.sh scripts/guard-git-command.sh install.sh tests/*.sh
```

GitHub Actions runs the same checks on pushes and pull requests: ShellCheck on Linux, and the syntax check and test suite on Linux, macOS, and Windows (Git Bash), so the Bash 3.2 baseline and Windows compatibility stay verified. CI also validates every JSON and YAML manifest and self-tests the GitHub Action by building clean and contaminated scenario branches and asserting the audit passes one, fails the other, and refuses shallow checkouts.

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
