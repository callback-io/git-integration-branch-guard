# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses semantic versioning for published releases.

## [Unreleased]

### Changed

- Match shared validation branch names as whole words, so a name like `dev` no longer matches words like `developer`.

### Fixed

- Print a notice when a shared validation branch ref cannot be resolved locally instead of silently skipping the merge-graph check, and resolve each ref once per run.
- Keep `git log` parsing stable when user configuration enables ref decorations or signature display, and read merge parents through plumbing instead of `git show`.

## [0.1.0] - 2026-06-07

### Added

- Add a Bash test suite for the branch-flow audit script.
- Add GitHub Actions CI: ShellCheck on Linux, syntax checks and tests on Linux, macOS, and Windows.
- Keep shell scripts LF-only via `.gitattributes` so they run under Git Bash on Windows.
- Add open-source project metadata and contribution guidance.

### Changed

- Open both READMEs with the real incident that motivated the skill.
- Treat integration branch names as literal text when matching commit subjects.
- Detect merge commits whose non-first parent is reachable from a configured shared validation branch, even when the merge message does not name that branch.
- Return usage status `2` when an option value is missing.

[unreleased]: https://github.com/callback-io/git-integration-branch-guard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/callback-io/git-integration-branch-guard/releases/tag/v0.1.0
