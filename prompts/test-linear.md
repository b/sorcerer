# Linear MCP write-path self-test

You are running as a self-test for sorcerer's Linear MCP integration. Use ONLY the `mcp__plugin_linear_linear__*` tools. Do not invoke Bash, Read, Write, Edit, Agent, or any other built-in tool.

The wrapper script parses your output for these exact line markers:
- One `STEP <n>: PASS: <details>` or `STEP <n>: FAIL: <reason>` per step.
- A final line: `TEST_PASSED` or `TEST_FAILED: step <N> — <reason>`.

If any step fails, do NOT proceed to later steps. Emit the FAIL line and the TEST_FAILED line.

Inputs (filled in by the wrapper):
- TEAM_KEY: __TEAM_KEY__

Steps:

1. Resolve the team via `mcp__plugin_linear_linear__get_team` with `query` = TEAM_KEY. Capture the team's `id` (UUID) and `name`.
   - On success: `STEP 1: PASS: team TEAM_KEY = <name> (<id>)`
   - On failure: `STEP 1: FAIL: team TEAM_KEY not found`

2. Create a test issue via `mcp__plugin_linear_linear__save_issue`:
   - `team`: the team UUID from step 1
   - `title`: `Sorcerer MCP self-test (auto-cancelled)`
   - `description`: `Created by sorcerer's Linear MCP self-test. Cancelled immediately. Safe to delete.`
   Capture the response's `identifier` (e.g. ETH-XYZ) and `id` (UUID).
   - On success: `STEP 2: PASS: created <ETH-XYZ> (<id>)`
   - On failure: `STEP 2: FAIL: <reason from API>`

3. Read the issue back via `mcp__plugin_linear_linear__get_issue` with `id` = the identifier from step 2. Verify the returned `title` matches `Sorcerer MCP self-test (auto-cancelled)`.
   - On success: `STEP 3: PASS: read-back title verified`
   - On failure: `STEP 3: FAIL: <reason — title mismatch or fetch error>`

4. Cancel the issue via `mcp__plugin_linear_linear__save_issue` with `id` = the identifier from step 2 and `state` = `Cancelled`. Confirm the response indicates the new state.
   - On success: `STEP 4: PASS: cancelled <ETH-XYZ>`
   - On failure: `STEP 4: FAIL: <reason>`

5. Final line:
   `TEST_PASSED`

If any earlier step failed, emit `TEST_FAILED: step <N> — <reason>` instead and stop.
