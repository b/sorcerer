#!/usr/bin/env bash
# Mint a GitHub App installation token.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/refresh-token.sh [options]

Mints a fresh GitHub App installation token using the App identity from the environment.

Reads from environment:
  GH_APP_CLIENT_ID            preferred JWT issuer
  GH_APP_APP_ID               fallback JWT issuer if client id absent
  GH_APP_PRIVATE_KEY_PATH     PEM file path used to sign the JWT
  GH_APP_INSTALLATION_ID      explicit installation id (skips lookup)
  GH_APP_INSTALLATION_OWNER   filter by account login when picking installation

Options:
  --installation-id <id>          override env / explicit pick
  --installation-owner <login>    override env / filter by login
  --token-only                    print only the token, no exports
  -h, --help                      show this message

Default output: shell export lines on stdout. Source it with:
  source <(bash scripts/refresh-token.sh)
USAGE
}

err()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"; }

INSTALLATION_ID="${GH_APP_INSTALLATION_ID:-}"
INSTALLATION_OWNER="${GH_APP_INSTALLATION_OWNER:-}"
TOKEN_ONLY=0
OWNER_EXPLICIT=0
ID_EXPLICIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --installation-id)
      [[ $# -ge 2 ]] || err "--installation-id requires a value"
      INSTALLATION_ID="$2"; ID_EXPLICIT=1; shift 2 ;;
    --installation-owner)
      [[ $# -ge 2 ]] || err "--installation-owner requires a value"
      INSTALLATION_OWNER="$2"; OWNER_EXPLICIT=1; shift 2 ;;
    --token-only) TOKEN_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1" ;;
  esac
done

# If --installation-owner was passed explicitly and the caller didn't ALSO pass
# --installation-id, clear any pre-existing INSTALLATION_ID from env. Otherwise
# the env-inherited id silently wins and the owner filter is never consulted.
if [[ "$OWNER_EXPLICIT" == "1" && "$ID_EXPLICIT" == "0" ]]; then
  INSTALLATION_ID=""
fi

need curl
need jq
need openssl

issuer="${GH_APP_CLIENT_ID:-${GH_APP_APP_ID:-}}"
[[ -n "$issuer" ]] || err "set GH_APP_CLIENT_ID (preferred) or GH_APP_APP_ID"

key_file="${GH_APP_PRIVATE_KEY_PATH:-}"
[[ -n "$key_file" ]] || err "set GH_APP_PRIVATE_KEY_PATH"
[[ -f "$key_file" ]] || err "private key not found at $key_file"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
exp=$((now + 540))
hdr='{"alg":"RS256","typ":"JWT"}'
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$now" "$exp" "$issuer")
unsigned="$(printf '%s' "$hdr" | b64url).$(printf '%s' "$payload" | b64url)"
sig="$(printf '%s' "$unsigned" | openssl dgst -binary -sha256 -sign "$key_file" | b64url)"
jwt="$unsigned.$sig"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "https://api.github.com$path" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $jwt" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body"
  else
    curl -fsS -X "$method" "https://api.github.com$path" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $jwt" \
      -H "X-GitHub-Api-Version: 2022-11-28"
  fi
}

if [[ -z "$INSTALLATION_ID" ]]; then
  installs="$(api GET "/app/installations")"
  if [[ -n "$INSTALLATION_OWNER" ]]; then
    INSTALLATION_ID=$(jq -r --arg o "$INSTALLATION_OWNER" \
      '[.[] | select(.account.login == $o)][0].id // empty' <<<"$installs")
  fi
  if [[ -z "$INSTALLATION_ID" ]]; then
    count=$(jq 'length' <<<"$installs")
    if [[ "$count" == "1" ]]; then
      INSTALLATION_ID=$(jq -r '.[0].id' <<<"$installs")
    fi
  fi
  [[ -n "$INSTALLATION_ID" ]] || {
    {
      echo "Available installations:"
      jq -r '.[] | "  id=\(.id) owner=\(.account.login) target_type=\(.target_type)"' <<<"$installs"
    } >&2
    err "could not auto-pick installation; pass --installation-id, --installation-owner, or set GH_APP_INSTALLATION_OWNER"
  }
fi

resp="$(api POST "/app/installations/$INSTALLATION_ID/access_tokens" '{}')"
token=$(jq -r '.token // empty' <<<"$resp")
expires=$(jq -r '.expires_at // empty' <<<"$resp")
[[ -n "$token" ]] || err "no token in response"

if [[ "$TOKEN_ONLY" == "1" ]]; then
  printf '%s\n' "$token"
else
  cat <<ENVOUT
export GITHUB_TOKEN='$token'
export GH_TOKEN='$token'
export GH_APP_INSTALLATION_ID='$INSTALLATION_ID'
export GH_APP_TOKEN_EXPIRES_AT='$expires'
ENVOUT
fi
