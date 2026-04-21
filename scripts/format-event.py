#!/usr/bin/env python3
"""Format sorcerer event-log entries (JSONL) into human-readable progress lines.

Reads lines from stdin. Each line is a JSON object with at minimum {ts, event}.
Emits one pretty line per event to stdout. Silent on events that aren't worth
surfacing to the user (e.g. tick-complete — noisy).
"""
import json
import sys


def short(v, n=8):
    return str(v)[:n] if v else ""


def fmt_architect_spawned(e):
    return f"Architect spawned (id: {short(e.get('id'))})"


def fmt_architect_completed(e):
    sub_epics = e.get("sub_epics") or []
    preview = ", ".join(sub_epics[:3])
    extra = f" (+{len(sub_epics) - 3} more)" if len(sub_epics) > 3 else ""
    return f"Architect completed: {len(sub_epics)} sub-epic(s) — {preview}{extra}"


def fmt_designer_spawned(e):
    return f"Designer spawned for sub-epic '{e.get('sub_epic')}' (id: {short(e.get('id'))})"


def fmt_designer_completed(e):
    return (
        f"Designer completed: Linear epic {short(e.get('epic_linear_id'))}, "
        f"{e.get('issues')} issue(s)"
    )


def fmt_implement_spawned(e):
    return f"Implement wizard spawned on {e.get('issue_key')} (pid {e.get('pid')})"


def fmt_implement_completed(e):
    extra = f" (cycle {e['cycle']})" if e.get("cycle") else ""
    return f"Implement completed{extra}: {e.get('issue_key')}, {e.get('pr_count')} PR(s) opened"


def fmt_feedback_completed(e):
    return f"Feedback cycle {e.get('cycle')} done on {e.get('issue_key')}"


def fmt_review_merge(e):
    return f"Review passed; merging {e.get('issue_key')} ({e.get('pr_count')} PR(s))"


def fmt_review_refer_back(e):
    return (
        f"Refer-back (cycle {e.get('cycle')}): {e.get('issue_key')} — "
        f"see {e.get('primary_pr')}"
    )


def fmt_issue_merged(e):
    return f"Merged and cleaned up: {e.get('issue_key')}"


def fmt_stale_respawn(e):
    return f"Stale respawn: {e.get('event').split('-stale-respawn')[0]} {short(e.get('id'))}"


def fmt_token_refreshed(_e):
    return "GitHub token refreshed"


def fmt_architect_archived(e):
    return f"Archived architect {short(e.get('id'))} (prior: {e.get('prior_status')})"


def fmt_wizard_archived(e):
    return f"Archived wizard {short(e.get('id'))} ({e.get('mode')}, prior: {e.get('prior_status')})"


FORMATTERS = {
    "token-refreshed": fmt_token_refreshed,
    "architect-spawned": fmt_architect_spawned,
    "architect-completed": fmt_architect_completed,
    "architect-stale-respawn": fmt_stale_respawn,
    "architect-archived": fmt_architect_archived,
    "designer-spawned": fmt_designer_spawned,
    "designer-completed": fmt_designer_completed,
    "designer-stale-respawn": fmt_stale_respawn,
    "implement-spawned": fmt_implement_spawned,
    "implement-completed": fmt_implement_completed,
    "implement-stale-respawn": fmt_stale_respawn,
    "feedback-completed": fmt_feedback_completed,
    "review-merge": fmt_review_merge,
    "review-refer-back": fmt_review_refer_back,
    "issue-merged": fmt_issue_merged,
    "wizard-archived": fmt_wizard_archived,
    # Silent (too noisy to surface): tick-complete
}


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            e = json.loads(raw)
        except json.JSONDecodeError:
            # Surface raw line if it doesn't parse as JSON.
            print(raw, flush=True)
            continue
        evt = e.get("event")
        if evt not in FORMATTERS:
            continue  # silent
        try:
            msg = FORMATTERS[evt](e)
        except Exception:
            msg = f"{evt}: {raw}"
        ts = e.get("ts", "")
        print(f"[{ts}] {msg}", flush=True)


if __name__ == "__main__":
    main()
