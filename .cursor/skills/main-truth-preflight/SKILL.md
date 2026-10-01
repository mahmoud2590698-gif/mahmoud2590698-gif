---
name: main-truth-preflight
description: Verifies the remote default branch as source of truth, prevents duplicate work, minimizes context and token usage, and runs repository preflight. Use before any implementation phase, feature, branch, push, pull request, deployment, recording, migration, or substantial code change.
---

# Main Truth Preflight

Before substantial implementation:

1. Locate the repository root.
2. Run `scripts/preflight.sh` when it exists, and stop if it prints `PREFLIGHT_BLOCK`.
3. Fetch the remote default branch. Do not assume the name `main`.
4. Treat `origin/<default>` as the source of truth.
5. Check whether the requested work already exists on that branch.
6. Check whether an equivalent PR, branch, or implementation already exists.
7. Check whether the current branch is behind the remote default.
8. Do not recreate functionality that is already implemented.
9. Do not introduce migrations unless the requested change requires them.
10. For phased repositories, one phase is one branch and one PR unless repository policy explicitly says otherwise. If no real phase is identified, treat the work as a standard workstream.
11. Never claim READY while conflicts, failing required checks, or unresolved integration issues exist.
12. Never record a demo or deployment before required tests and build pass and the user explicitly requested it.
13. Respect the repository diff limit in `.cursor/governance.json`.
14. Read only the files required for the current task.
15. Prefer search, `git diff`, symbols, targeted ranges, and `PROJECT_STATE.md` over reopening entire large files.
16. Reuse existing implementations, scripts, utilities, components, prompts, workflows, and patterns before creating alternatives.
17. Keep agent responses concise during implementation unless detail is needed for a decision.

Run preflight at task start, phase change, push, PR, and recording or deployment. Do not rerun it after every small edit. Full policy: `~/.cursor/governance/POLICY.md`.

<!-- cursor-governance-managed:1.0.0 -->
