#!/usr/bin/env bash
# Return the single client scoped, or error if multiple clients are found
set -euo pipefail

[[ $# -gt 0 ]] || { printf 'Provide at least one template path.\n' >&2; exit 1; }
client=''
for path in "$@"; do
    # Extract the client name from the template path
    current=${path#templates/}
    current=${current%%/*}
    # Check if the current client differs from the previously found client (more client)
    if [[ -n $client && $client != "$current" ]]; then
        printf 'Only one client is allowed per batch: %s and %s.\n' "$client" "$current" >&2
        exit 1
    fi
    client=$current
done
printf '%s\n' "$client"
