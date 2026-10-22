#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ -f .env ]; then
  source .env
fi

BASE="http://127.0.0.1:${REGISTRY_PORT:-5000}"
AUTH="${REGISTRY_USER}:${REGISTRY_PASSWORD}"

CATALOG=$(curl -sf -u "$AUTH" "$BASE/v2/_catalog")
REPOS=$(python3 -c 'import sys, json; print("\n".join(json.load(sys.stdin).get("repositories", [])))' <<< "$CATALOG")

if [ -z "$REPOS" ]; then
  echo "Registry пуст"
  exit 0
fi

printf "%-35s %s\n" "REPOSITORY" "TAGS"
while IFS= read -r repo; do
  TAGS=$(curl -sf -u "$AUTH" "$BASE/v2/${repo}/tags/list" \
    | python3 -c 'import sys, json; print(" ".join(json.load(sys.stdin).get("tags") or []))')
  printf "%-35s %s\n" "$repo" "$TAGS"
done <<< "$REPOS"
