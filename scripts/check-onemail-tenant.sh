#!/usr/bin/env bash
# Purpose: Verify that a template client is configured as a OneMail tenant.
# Usage examples:
#   bash scripts/check-onemail-tenant.sh news-ioapp
set -euo pipefail

[[ $# -eq 1 ]] || { printf 'Usage: %s <client>\n' "$0" >&2; exit 1; }
client=$1

for command in curl jq; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

tenant_url='https://raw.githubusercontent.com/pagopa/onemail/refs/heads/main/src/infra/src/data/tenants/tenants.json'
if ! tenants=$(curl --fail --silent --show-error --location --max-time 30 "$tenant_url"); then
    printf 'Failed to retrieve the OneMail tenant configuration.\n' >&2
    exit 1
fi

if ! jq -e -s 'length == 1 and (.[0] | type == "object" and length > 0)' <<< "$tenants" >/dev/null; then
    printf 'The OneMail tenant configuration must be a non-empty JSON object.\n' >&2
    exit 1
fi

if ! jq -e --arg client "$client" 'has($client)' <<< "$tenants" >/dev/null; then
    printf 'Client "%s" is not configured as a OneMail tenant.\n' "$client" >&2
    exit 1
fi

printf 'Verified OneMail tenant: %s\n' "$client"
