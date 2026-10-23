#!/usr/bin/env bash
# Purpose: Check selected template HTML through the OneMail template sanitizer API.
# Usage examples (run from the candidate checkout):
#   SANITIZER_URL=https://..../sanitize-template bash ../trusted/scripts/sanitize-templates.sh templates/checkout/welcome/v1/template.json
set -euo pipefail

[[ $# -gt 0 ]] || { printf '❌ Provide template paths to check.\n' >&2; exit 1; }
: "${SANITIZER_URL:?Provide the template sanitizer URL}"

failed=0
for path in "$@"; do
    printf 'Checking template HTML: %s\n' "$path"
    # jq safely JSON-encodes the HTML string, including quotes and newlines.
    # Send the encoded JSON directly as the request body.
    if ! response=$(jq -c '{htmlContent: .TemplateContent.Html}' "$path" |
        curl --silent --show-error --fail \
            --connect-timeout 10 --max-time 60 --retry 2 \
            --header 'Content-Type: application/json' \
            --data-binary @- "$SANITIZER_URL"); then
        printf '❌ Template API check failed: %s\n' "$path" >&2
        failed=1
        continue
    fi
    # Require a valid response confirming that the template needs no sanitization.
    if ! jq -e -s '
        length == 1 and (.[0] | type == "object" and
            .isSanitized == false and (.sanitizedHtml | type == "string"))
    ' <<< "$response" >/dev/null 2>&1; then
        printf '❌ Template requires sanitization or the API response is invalid: %s\n' "$path" >&2
        failed=1
        continue
    fi
    printf '✅ Template HTML check passed: %s\n' "$path"
done

exit "$failed"