# Contributing

Thanks for improving Git Integration Branch Guard. This project is intentionally small: keep changes focused, portable, and easy to audit.

## Development Setup

Requirements:

- Git 2.28 or newer (the test suite uses `git init -b` and `git switch`)
- Bash 3.2 or newer (the stock macOS Bash is enough; on Windows, use Git Bash, which is bundled with Git for Windows, or WSL)
- ShellCheck for local linting

Run the checks:

```bash
bash -n scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
bash tests/audit-branch-flow-tests.sh
shellcheck scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
```

If ShellCheck is not installed locally, CI will still run it on pull requests.

## Contribution Guidelines

- Keep the skill portable across agent runtimes.
- Do not add runtime-specific assumptions unless they are documented as optional.
- Add tests for script behavior changes before changing the script.
- Document any known detection limits in the README and `SKILL.md`.
- Keep commit messages product-neutral and tool-neutral, for example `fix: handle missing option values`.

## Pull Requests

Before opening a pull request:

- Run the local checks above.
- Update `CHANGELOG.md` for user-visible changes.
- Update both `README.md` and `README.zh-CN.md` when changing user-facing behavior.
