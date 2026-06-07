---
name: git-integration-branch-guard
description: Enforce a role-based, one-way Git integration branch workflow. Use when a user asks to create, sync, merge, rebase, pull, cherry-pick, push, open a PR, review branch history, or prepare a release in a repository with local work branches, shared dev/test/uat/staging branches, or production branches.
---

# Git Integration Branch Guard

## Objective

Protect production history from accidental contamination by treating shared integration and environment branches as one-way collection or promotion pools.

Shared dev/test/uat/staging branches can receive work for validation, but they must not become upstream sources for scoped work branches or production. If a repository explicitly treats a long-lived branch as release-ready, classify that branch as a production or release branch for that workflow instead of treating it as a shared validation pool.

## Branch Roles

| Role | Common names | Purpose |
|---|---|---|
| Production branch | `main`, `master`, `trunk`, `prod`, `production`, `release`, or custom names | Source of production releases and clean work branches |
| Shared integration or environment branch | `dev`, `develop`, `test`, `qa`, `uat`, `stage`, `staging`, `preprod`, `integration`, or custom names | Shared validation or promotion pool that may contain multiple in-flight changes |
| Work branch | `feat/*`, `feature/*`, `features/*`, `fix/*`, `bugfix/*`, `hotfix/*`, `chore/*`, `refactor/*`, `task/*`, `ticket/*`, or team-specific names | One scoped feature, bug fix, task, or change branch created from the production branch |

Names are examples, not rules. First map the repository's branch roles, then apply the direction rules.

Do not rely on prefixes alone. A work branch is any scoped branch that is intended to release a bounded change to production, regardless of whether it is named `feat/foo`, `features/foo`, `user/foo`, `ticket-123`, or something else.

Do not rely on branch names alone. In one repository `dev` may be a shared integration branch; in another it may be a scoped developer branch, an environment branch, or part of a promotion chain. Treat the branch by its role, not by its spelling.

## Direction Rules

Allowed directions:

| Action | Direction | Purpose |
|---|---|---|
| Create work branch | production -> work branch | Start clean feature or fix work |
| Sync upstream | production -> work branch | Bring released changes into current work |
| Sync production into validation pools | production -> shared integration/environment branch | Keep shared environments aware of released changes |
| Send to shared validation | work branch -> shared integration/environment branch | Deploy or validate in a shared environment |
| Promote between shared environments | earlier shared environment -> later shared environment | Allowed only when the repository explicitly defines this promotion path, such as dev -> test -> uat |
| Release | work branch -> production | Ship reviewed, scoped work |

Forbidden directions:

| Direction | Why it is unsafe |
|---|---|
| shared integration/environment branch -> work branch | Pulls unrelated in-flight work into the scoped branch |
| shared integration/environment branch -> production | Releases a mixed validation pool instead of a reviewed unit of work |

If a branch name appears in more than one category, classify it by repository role and release policy before applying this table.

## Non-Negotiable Rule

Never use a shared integration or environment branch as an upstream for scoped work.

Before running `git merge`, `git rebase`, `git pull`, or `git cherry-pick`, identify:

- `source`: the branch or commit being brought in
- `target`: the currently checked-out branch or branch being changed

If `source` is a shared integration or environment branch and `target` is a work branch or production branch, stop. Do not run the command.

Tell the user the operation violates the one-way integration workflow and ask whether they meant to sync from the production branch instead.

Standard response:

> This violates the one-way integration branch workflow. Shared dev/test/uat/staging branches are validation pools, not upstreams for scoped work. Merging one into a work or production branch can pull unrelated in-flight work into the release path. Did you mean to sync from the production branch instead?

## Required Checks Before Git Operations

Before any branch-changing operation:

1. Inspect current state:

   ```bash
   git status --short --branch
   git branch --show-current
   ```

2. Identify the repository's production branch, scoped work branches, and shared integration/environment branches.

3. Identify the exact source and target.

4. Apply the direction rules.

5. If the requested direction is forbidden, refuse and clarify before doing anything.

This applies even if the user phrases the request casually, for example:

- "pull dev into this branch"
- "rebase this feature on dev"
- "sync from staging"
- "merge test into this task branch"
- "pull uat into my local branch"
- "cherry-pick the integration fix"
- "merge develop to main"

## Creating a Clean Work Branch

Prefer a separate worktree when the repository supports it:

```bash
git fetch origin
git worktree add ../<repo>-<short-task-name> -b <type>/<short-task-name> origin/<production-branch>
cd ../<repo>-<short-task-name>
```

Without a worktree:

```bash
git fetch origin
git switch -c <type>/<short-task-name> origin/<production-branch>
```

Use work branch names that match the repository convention, such as `feat/`, `feature/`, `features/`, `fix/`, `bugfix/`, `hotfix/`, `chore/`, `refactor/`, `task/`, or a ticket/user-based naming pattern.

Do not create new work branches from the integration branch.

## Syncing a Work Branch

Use the production branch as upstream:

```bash
git fetch origin
git merge origin/<production-branch>
```

or, when the repository prefers rebasing:

```bash
git fetch origin
git rebase origin/<production-branch>
```

Never run these from a work branch or production branch:

```bash
git merge origin/<integration-branch>
git rebase origin/<integration-branch>
git pull origin <integration-branch>
```

Replace `<integration-branch>` with any shared validation branch in the repository, such as `dev`, `test`, `uat`, `staging`, or `integration`.

## Sending Work to Shared Validation

To send a scoped work branch into a shared validation pool:

```bash
git fetch origin
git switch <integration-branch>
git merge --no-ff <work-branch>
```

Only do this when the repository's deployment process expects that shared branch to collect validation candidates.

Do not treat this merge as a release. The production release must still come from the scoped work branch, not from a mixed shared environment branch.

If the repository has an explicit promotion chain such as `dev -> test -> uat`, follow that chain only for environment promotion. Do not use any of those shared branches as upstream for scoped work.

## Releasing to Production

Before merging a work branch into production, audit for contamination from shared integration or environment branches.

Recommended script:

```bash
scripts/audit-branch-flow.sh \
  --production origin/<production-branch> \
  --integration <shared-branch> \
  --integration <another-shared-branch>
```

If the script is installed outside the repository, call it by absolute path. The script needs a Bash environment; on Windows, run it from Git Bash or WSL.

The script checks for:

- merge commits or commit subjects that mention shared validation branch names, matched as whole words of literal text
- merge commits whose non-first parent is reachable from a configured shared validation branch, when that branch ref exists locally
- all non-merge commits in the release range for manual review

The script is a conservative release-readiness aid. It does not prove a branch is clean. Rebases, cherry-picks, copied patches, deleted refs, rewritten history, and custom workflows may still require manual review.

Manual checks:

```bash
# Look for merge commits involving shared validation branches.
git log --merges --oneline origin/<production-branch>..HEAD | grep -iE 'merge|pull|dev|develop|test|qa|uat|stage|staging|preprod|integration'

# Look for commits that mention the integration branch.
git log --oneline --grep='<integration-branch>' origin/<production-branch>..HEAD

# Review authors and subjects for unrelated in-flight work.
git log --no-merges --format='%h %an %s' origin/<production-branch>..HEAD
```

If the audit suggests the work branch previously merged, rebased, pulled, or cherry-picked from a shared integration or environment branch, stop and warn the user:

> This branch may contain changes from a shared validation branch. Releasing it could ship unrelated in-flight work. Consider rebuilding the change on a clean branch from the production branch, or explicitly confirm that all included commits are intended for this release.

Do not merge to production until the user explicitly chooses how to proceed.

## Decision Table

| User request | Action |
|---|---|
| "Create a feature branch" | Create from production |
| "Bring this branch up to date" | Sync from production |
| "Merge this feature to dev/test/uat for validation" | Allowed if the repository uses that shared validation pool |
| "Promote dev to test" | Allowed only if the repository defines dev -> test as an environment promotion path |
| "Merge dev into my feature" | Refuse and suggest syncing from production |
| "Pull staging into this fix branch" | Refuse and suggest syncing from production |
| "Pull uat into this local work branch" | Refuse and suggest syncing from production |
| "Merge develop/test/uat to main" | Refuse unless the repository explicitly defines that branch as release-ready |
| "Release this feature" | Audit for integration contamination, then merge work branch to production |

## Common Mistakes

Using a shared validation branch as a convenience upstream:

- Problem: the work branch absorbs unrelated unfinished changes.
- Fix: sync from production instead.

Releasing a shared validation branch:

- Problem: production receives a mixed bag of in-flight work.
- Fix: release reviewed work branches individually.

Skipping history audit before release:

- Problem: old contamination is missed even if the final merge direction looks correct.
- Fix: inspect commits between production and the work branch before release.

Assuming a branch name is enough:

- Problem: repositories use different branch names.
- Fix: map branch roles first, then apply the direction rules.

## Workflow Diagram

```text
                    production
                        |
           create/sync  |  allowed
                        v
                   work branch
                    /      \
                   /        \
 allowed: validate v          v allowed: release
        dev/test/uat       production

 allowed only by explicit promotion policy:
 dev -> test -> uat

 forbidden:
 dev/test/uat -> work branch
 dev/test/uat -> production
```

## Bottom Line

Shared validation branches are collection or promotion pools, not upstreams for scoped work.
