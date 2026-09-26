# First prompt for the coding agent

Copy this prompt into the coding agent with the full bundle available in its working context:

```text
Read AGENTS.md, SPEC.md, IMPLEMENTATION_PLAN.md, BACKLOG.json,
ACCEPTANCE_TESTS.md, THREAT_MODEL.md, TOOLCHAIN.json, and SOURCES.md.

We are building Recortia, a native, local-first macOS screenshot utility
and independent open-source alternative to Shottr. Recortia is only a
working codename. The application does not require an embedded AI agent.

Your first assignment is planning and read-only inspection, not application
implementation. Inspect the real repository, existing instructions, branch,
uncommitted work, projects, schemes, dependencies, tests, and Mac toolchain.
Do not assume the proposed paths already exist. Do not capture my screen,
read my clipboard, grant permissions, access credentials, install tools,
change application code, or publish anything.

Return an M0 plan that identifies exact proposed files, toolchain/API
availability checks, capture/geometry/redaction/scroll feasibility spikes,
test fixtures, benchmark endpoints, permission and sandbox decisions,
risks, dependencies, and the smallest useful vertical slice.

Distinguish verified repository/toolchain facts from assumptions. On a
non-Mac environment, identify which checks cannot be run. Do not invent
successful builds or hardware results. Wait for explicit approval before
implementation.
```

After reviewing that plan, the owner can explicitly authorize the selected milestone and its listed code/test actions. Each later handoff should name the milestone/task IDs rather than asking an agent to generate the entire application in one pass.
