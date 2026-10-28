#!/usr/bin/env bash
# `mix hex.audit`, allowing only the advisories listed in DESIGN.md §6 (no patched release yet).
# Remove an entry as soon as a patched version is locked.
set -uo pipefail

allowed=(
  "cowlib 2.21.0 - EEF-CVE-2026-43966"
)

output=$(mix hex.audit 2>&1)
status=$?
echo "$output"
[ "$status" -eq 0 ] && exit 0

if echo "$output" | grep -qi "retired"; then
  echo "::error::retired packages found"
  exit 1
fi

unexpected=$(echo "$output" | grep -E '^\s+[a-z0-9_]+ [0-9][^ ]* - ' | sed -E 's/^\s+//' | while read -r line; do
  ok=0
  for entry in "${allowed[@]}"; do
    [[ "$line" == "$entry"* ]] && ok=1
  done
  [ "$ok" -eq 0 ] && echo "$line"
done)

if [ -n "$unexpected" ]; then
  echo "::error::unexpected security advisories:"
  echo "$unexpected"
  exit 1
fi

echo "only allowed advisories found (see DESIGN.md §6)"
