#!/usr/bin/env bash
# Test: scripts/list-in-flight-architect-plans.sh
#
# Covers the overlap-detection path SOR-533 introduced (architect
# context-injection of in-flight plans). Run as a developer check or
# from any CI step that doesn't already lint prompts.
#
# Usage: tests/list-in-flight-architect-plans.test.sh
#
# Exit: 0 on all-pass, 1 on first fail (loud).
set -euo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

SCRIPT="$SORCERER_REPO/scripts/list-in-flight-architect-plans.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: missing or non-executable $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ok:   $1"; PASS=$((PASS+1)); }

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

ROOT=$(mktemp -d)

# ---------- case 1: no .sorcerer dir → empty array ----------
echo "case 1: missing .sorcerer/sorcerer.json → []"
out=$(bash "$SCRIPT" "$ROOT")
[[ "$out" == "[]" ]] && pass "empty array" || fail "expected '[]', got '$out'"

# ---------- case 2: empty active_architects → empty array ----------
echo "case 2: empty active_architects → []"
mkdir -p "$ROOT/.sorcerer"
echo '{"active_architects":[],"active_wizards":[]}' > "$ROOT/.sorcerer/sorcerer.json"
out=$(bash "$SCRIPT" "$ROOT")
[[ "$out" == "[]" ]] && pass "empty array" || fail "expected '[]', got '$out'"

# ---------- case 3: in-flight architect with plan, cites SOR-479 ----------
echo "case 3: in-flight architect with plan + SOR cite"
mkdir -p "$ROOT/.sorcerer/architects/aaaaaaaa-1111-2222-3333-444444444444"
cat > "$ROOT/.sorcerer/sorcerer.json" <<'EOF'
{"active_architects":[{"id":"aaaaaaaa-1111-2222-3333-444444444444","status":"awaiting-tier-2"}],"active_wizards":[]}
EOF
cat > "$ROOT/.sorcerer/architects/aaaaaaaa-1111-2222-3333-444444444444/plan.json" <<'EOF'
{
  "design_doc": "design.md",
  "sub_epics": [
    {"name": "thread dest-VR best-paths", "mandate": "SOR-479 site #1: dest-VR best-paths borrow on PolicyEnvironment.", "repos": ["github.com/owner/repo"]},
    {"name": "wire AsPathExpr::Reference", "mandate": "Site #2 of SOR-479: resolve AsPathExpr::Reference arm. Also touches SOR-450.", "repos": ["github.com/owner/repo"]}
  ]
}
EOF
echo "request body for arch A" > "$ROOT/.sorcerer/architects/aaaaaaaa-1111-2222-3333-444444444444/request.md"

out=$(bash "$SCRIPT" "$ROOT")
arch_count=$(jq 'length' <<< "$out")
[[ "$arch_count" == "1" ]] && pass "one architect entry" || fail "expected 1 entry, got $arch_count"

arch_id=$(jq -r '.[0].architect_id' <<< "$out")
[[ "$arch_id" == "aaaaaaaa" ]] && pass "architect_id shortened to 8 chars" || fail "expected 'aaaaaaaa', got '$arch_id'"

sor_first=$(jq -r '.[0].sub_epics[0].cited_sors | join(",")' <<< "$out")
[[ "$sor_first" == "SOR-479" ]] && pass "cited_sors[0] = [SOR-479]" || fail "expected 'SOR-479', got '$sor_first'"

sor_second=$(jq -r '.[0].sub_epics[1].cited_sors | join(",")' <<< "$out")
[[ "$sor_second" == "SOR-450,SOR-479" ]] && pass "cited_sors[1] = [SOR-450,SOR-479] (sorted, deduped)" \
  || fail "expected 'SOR-450,SOR-479', got '$sor_second'"

req_excerpt=$(jq -r '.[0].request_excerpt' <<< "$out")
[[ "$req_excerpt" == "request body for arch A" ]] && pass "request_excerpt populated" \
  || fail "expected 'request body for arch A', got '$req_excerpt'"

# ---------- case 4: --exclude-id filters out the named architect ----------
echo "case 4: --exclude-id filters"
out=$(bash "$SCRIPT" --exclude-id "aaaaaaaa-1111-2222-3333-444444444444" "$ROOT")
[[ "$out" == "[]" ]] && pass "exclude removes the only entry → []" || fail "expected '[]', got '$out'"

# ---------- case 5: terminal-status architect is excluded ----------
echo "case 5: completed architect is excluded"
cat > "$ROOT/.sorcerer/sorcerer.json" <<'EOF'
{"active_architects":[{"id":"aaaaaaaa-1111-2222-3333-444444444444","status":"completed"}],"active_wizards":[]}
EOF
out=$(bash "$SCRIPT" "$ROOT")
[[ "$out" == "[]" ]] && pass "completed architect excluded → []" || fail "expected '[]', got '$out'"

# ---------- case 6: architect mid-decomposition (no plan.json yet) ----------
echo "case 6: architect with no plan.json yet"
cat > "$ROOT/.sorcerer/sorcerer.json" <<'EOF'
{"active_architects":[{"id":"aaaaaaaa-1111-2222-3333-444444444444","status":"running"}],"active_wizards":[]}
EOF
rm -f "$ROOT/.sorcerer/architects/aaaaaaaa-1111-2222-3333-444444444444/plan.json"
out=$(bash "$SCRIPT" "$ROOT")
empty_subs=$(jq '.[0].sub_epics | length' <<< "$out")
[[ "$empty_subs" == "0" ]] && pass "running-no-plan architect has empty sub_epics" \
  || fail "expected 0 sub_epics, got $empty_subs"

# ---------- summary ----------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) || exit 1
exit 0
