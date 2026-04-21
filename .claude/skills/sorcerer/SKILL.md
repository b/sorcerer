---
name: sorcerer
description: Build or refactor a large system autonomously. Sorcerer's Tier-1 architect decomposes the system into sub-epics, Tier-2 designers turn each sub-epic into a Linear epic + issues, Tier-3 wizards implement each issue across the relevant repositories, and the coordinator reviews and merges PRs. Usage - /sorcerer followed by a description of the system to build or refactor (multi-line markdown OK). The user types this and walks away; sorcerer drives the entire pipeline from there. NOT for minor features or small bug fixes — those don't need this machinery.
allowed-tools: Bash
---

# /sorcerer — submit a system to build or refactor

The user invoked you via `/sorcerer`. Their full message describes a system they want sorcerer to build or refactor — typically a multi-component, possibly multi-repo undertaking.

## Job

Extract the argument — everything after `/sorcerer ` in the user's message (or after a `/sorcerer` line for multi-line input) — and pass it as a single argument to the submit script. Print the script's output verbatim and stop.

```bash
bash $SORCERER_REPO/scripts/sorcerer-submit.sh "<extracted arg>"
```

That one Bash call is the entire skill. Pre-approved in `~/.claude/settings.json` by `scripts/install-skill.sh`, so this runs without prompting.

The submit script dispatches on the first word:
- `stop` → stop the coordinator for the current project
- `status` → print sorcerer.yaml + coordinator pid state
- `attach` → stream live event updates from a running coordinator
- `log` → print the full formatted event history for this project
- anything else → submit as a new request and auto-attach to the live event stream

All five forms are just `bash sorcerer-submit.sh "<whatever user typed>"` from the skill's perspective.

If the user's message is literally empty after `/sorcerer`, the submit script prints a usage block on stderr and exits 2 — just print that verbatim.

## Rules

- Do not narrate steps, summarize the request, or add "let me know if…" lines.
- Do not propose changes to the request — sorcerer's architect will decompose it.
- Do not ask the user clarifying questions.
- Print the script's stdout/stderr verbatim. Nothing else.
- If the script prints a usage block (because you passed an empty prompt) or an error (SORCERER_REPO unset, etc.), print it and stop.
