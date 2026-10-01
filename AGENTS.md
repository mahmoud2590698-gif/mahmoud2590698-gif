# Repository Agent Contract

Before substantial work, run `scripts/preflight.sh` and stop on `PREFLIGHT_BLOCK`.

- Remote default branch is source of truth.
- Search before creating; reuse existing implementation.
- Respect `.cursor/governance.json` and do not bypass hooks.
- Keep the current workstream scoped. No unrelated refactors.
- No migration, recording, or deployment demo without explicit need.
- Prefer targeted reads, search, and diff. Keep context small.
- Update `.cursor/context/PROJECT_STATE.md` only when status materially changes.

<!-- cursor-governance-managed:1.0.0 -->
