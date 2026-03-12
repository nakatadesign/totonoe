# totonoe

`totonoe` is a reference template for running a Claude Code + Codex CLI workflow with explicit role separation, secure runtime state handling, and optional Gemini fallback.

## What This Is

- A reusable template for repositories that want a structured `Manager -> Engineer -> Reviewer -> Analyst -> Manager` loop
- A bash-first orchestration layer with no Python dependency in the runtime scripts
- A reference implementation that emphasizes safety around runtime files, path handling, and final decision gates

## What This Is Not

- Not a hosted service
- Not a generic agent framework for every workflow
- Not a promise that autonomous implementation is always safe without human review

## Core Capabilities

- Codex-first execution with Gemini fallback only for quota, token, rate-limit, and context-length failures
- `done` guarded by explicit conditions instead of Engineer self-reporting
- Secure runtime helpers for path traversal, symlink, hardlink, and atomic write handling
- Specialized Engineer routing via `engineer_type`
- Copyable setup for new repositories through `setup.sh`

## Naming

The repository name is `totonoe`, and the installed runtime path is `.claude/totonoe/`.

## Repository Layout

- `.claude/totonoe/`: runtime scripts, schemas, goals, and operational docs
- `.claude/agents/MANAGER.md`: final decision maker
- `.claude/agents/GENERIC-ENGINEER.md`: default Engineer
- `.claude/agents/SECURITY-ENGINEER.md`: security-focused Engineer
- `.claude/agents/TEST-ENGINEER.md`: test-focused Engineer
- `.claude/agents/PERF-ENGINEER.md`: performance-focused Engineer
- `.claude/agents/REFACTOR-ENGINEER.md`: refactor-focused Engineer
- `.claude/settings.json`: base Claude permissions
- `CLAUDE.totonoe.template.md`: template section for repository-level loop instructions
- `AGENTS.totonoe.template.md`: template section for Codex reviewer instructions
- `gitignore.additions`: lines to append to the target repository `.gitignore`

## Quick Start

1. Copy this template into a working directory and run:

```bash
./setup.sh --target /path/to/your/repo
```

2. Merge these files into the target repository as needed:
   - `CLAUDE.totonoe.template.md`
   - `AGENTS.totonoe.template.md`
3. Customize the target repository agents:
   - `.claude/agents/GENERIC-ENGINEER.md`
   - optional specialized Engineers under `.claude/agents/`
4. If you want provider fallback, export:

```bash
export GEMINI_API_KEY="..."
export GEMINI_MODEL="gemini-2.5-pro"
export AI_PROVIDER_COOLDOWN_BASE_SECONDS="1800"
```

5. Initialize a job in the target repository:

```bash
.claude/totonoe/bin/init_job.sh \
  --job-name sample-feature \
  --goal-template feature_loop
```

6. Render the loop prompt and hand it to Claude Code:

```bash
.claude/totonoe/bin/render_loop_prompt.sh --job-name sample-feature
```

The detailed operator guide lives in [`RUNBOOK.md`](./.claude/totonoe/RUNBOOK.md).

## How Engineer Routing Works

The Analyst may return an optional `engineer_type` in `judge.json`. Manager treats it as a recommendation, not a hard constraint.

| `engineer_type` | Default dispatch |
|---|---|
| `security` | `Security-Engineer` |
| `test` | `Test-Engineer` |
| `performance` | `Perf-Engineer` |
| `refactor` | `Refactor-Engineer` |
| `generic` or unset | `Generic-Engineer` |

If classification is unclear or the fix spans multiple categories, Manager should prefer `Generic-Engineer`.

## Requirements

- `bash`
- `jq >= 1.6`
- `codex`
- `curl`
- `perl` or `realpath`

Most runtime and agent documents are currently written in Japanese.

## Validation

This repository is intended to ship with basic CI checks:

- shell syntax validation
- JSON schema parsing
- `setup.sh` smoke test
- minimal job initialization and round-recording smoke test

See [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).

## Security

This template makes security-sensitive choices in the runtime layer, especially around path normalization and state writes. Read [`SECURITY.md`](./SECURITY.md) before publishing a derived repository.

## License

MIT. See [`LICENSE`](./LICENSE).
