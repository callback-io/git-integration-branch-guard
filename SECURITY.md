# Security Policy

## Installation Boundary

The skill installer (`install.sh`) only copies skill files into agent skills directories. It never edits agent settings, never registers hooks, and never writes outside the chosen skills directories. Hook registration — the part that can intercept commands — happens exclusively through the Claude Code plugin install flow, which has its own user consent step. Treat any fork or mirror of this project that auto-registers hooks from an installer script as untrustworthy.

## Command Guard Behavior

The PreToolUse hook (`scripts/guard-git-command.sh`) is read-only with respect to your repository: it inspects the proposed command and the local branch topology, then answers with a permission decision. It fails open by design — when its own infrastructure is missing or a payload cannot be parsed, it stays silent rather than blocking work — and `BRANCH_GUARD_DISABLE=1` bypasses it. It is a guard rail against accidental contamination, not a sandbox against a deliberately evasive actor; release auditing remains the final layer.

## Supported Versions

Security fixes are handled on the default branch until versioned releases are published.

## Reporting a Vulnerability

If you find a vulnerability, please do not open a public issue with exploit details.

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Include:

- affected version or commit
- reproduction steps
- expected and actual behavior
- potential impact

Reports are acknowledged, assessed for severity, and addressed with a fix or a mitigation note when appropriate.
