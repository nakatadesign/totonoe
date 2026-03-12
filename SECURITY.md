# Security Policy

This repository is a template and reference implementation, not a hosted service. The most security-sensitive areas are the runtime shell scripts under `.claude/totonoe/bin/`.

## Scope

Security reports are especially relevant when they involve:

- path traversal or directory escape
- symlink or hardlink bypasses
- unintended command execution outside the intended wrappers
- runtime state corruption or lock bypass
- secret leakage through logs, prompts, or generated files

## Reporting

If this project is published on GitHub, prefer a private disclosure path first.

Recommended order:

1. Open a GitHub Security Advisory, if enabled for the repository
2. Contact the maintainer through a private channel listed by the maintainer
3. If no private channel exists yet, open a minimal public issue without exploit details and request a private contact path

Please do not publish full exploit details before a fix is available.

## Supported Versions

Security fixes should target the latest `main` branch or the latest published release derived from it.

## Notes For Derived Repositories

If you publish a repository based on this template, you should update this file with:

- a real maintainer contact path
- your supported version policy
- any provider-specific secret handling rules you add
