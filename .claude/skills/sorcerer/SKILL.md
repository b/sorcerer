---
name: sorcerer
description: Build or refactor a large system autonomously. Sorcerer's Tier-1 architect decomposes the system into sub-epics, Tier-2 designers turn each sub-epic into a Linear epic + issues, Tier-3 wizards implement each issue across the relevant repositories, and the coordinator reviews and merges PRs. Usage - /sorcerer followed by a description of the system to build or refactor (multi-line markdown OK). The user types this and walks away; sorcerer drives the entire pipeline from there. NOT for minor features or small bug fixes — those don't need this machinery.
allowed-tools: Bash
---

# /sorcerer — submit a system to build or refactor

The user invoked you via `/sorcerer`. Their full message describes a system they want sorcerer to build or refactor — typically a multi-component, possibly multi-repo undertaking that justifies autonomous decomposition and parallel execution.

Submit it. Don't design it, don't decompose it, don't ask clarifying questions — sorcerer's Tier-1 architect will do all of that, producing a design doc and sub-epic plan before any code is written. The architect, designer wizards, and implement wizards each handle their own clarifying. Your only job here is to write the request to disk and ensure the coordinator is alive.

If the request is a minor fix or a tiny one-file change, gently note that sorcerer is overkill for that and recommend doing it manually — but proceed with submission anyway if the user insists.

## Steps

Do all three Bash steps below, then print the final block. No other output.

### 1. Validate

Extract the prompt body from the user's message — everything after `/sorcerer ` (or after a `/sorcerer` line, if the user sent a multi-line message). If the prompt body is empty, print:

```
Usage: /sorcerer <description of the system to build or refactor>

Sorcerer is for ambitious work — a new service, a cross-repo refactor, a
multi-component feature. Describe the desired end state; the architect
will decompose it.

Example:
  /sorcerer Build a real-time pricing service: ingestion from Kafka, in-memory
  cache backed by Redis, gRPC API for clients, Prometheus metrics. Owns its
  own deployment manifests in our gitops repo.
```

…and stop. Do not run subsequent steps.

### 2. Write the request

Write the prompt to a timestamped file under `state/requests/`:

```bash
set -e
mkdir -p state/requests
TS=$(date -u +%Y%m%dT%H%M%SZ)
# slug from the first line of the prompt, alphanumeric-and-dash, max 60 chars
FIRST_LINE='<the prompt's first line, verbatim>'
SLUG=$(printf '%s' "$FIRST_LINE" | head -c 80 | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//' | head -c 60 | sed 's/-$//')
[[ -z "$SLUG" ]] && SLUG=request
FILE="state/requests/${TS}-${SLUG}.md"
cat > "$FILE" <<'PROMPT'
<the user's full prompt body, verbatim, with no modifications>
PROMPT
echo "$FILE"
```

Capture the filename (the script's last `echo`).

### 3. Ensure the coordinator is running

```bash
bash scripts/start-coordinator.sh
```

This is idempotent: if a coordinator is already running it reports the existing pid; otherwise it spawns a new detached loop. Capture the output.

## Final output

Print exactly this block, with the captured values substituted:

```
Request submitted: <filename from step 2>
<output from step 3>

Sorcerer will autonomously:
  1. Architect — decompose the system into sub-epics with explicit boundaries
  2. Design — turn each sub-epic into a Linear epic with concrete issues
  3. Implement — spawn wizards to work each issue across the relevant repos
  4. Review — gate every PR set against acceptance criteria, then merge

Monitor:  tail -f state/coordinator.log state/events.log
Stop:     bash scripts/stop-coordinator.sh
```

Don't add commentary, summary of the request, or "let me know if…" lines.
