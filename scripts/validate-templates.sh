#!/usr/bin/env bash
# Purpose: Validate template paths, names, and required SES JSON fields.
# Usage examples (run from the repository root or candidate checkout):
#   bash scripts/validate-templates.sh templates/checkout/welcome/v1/template.json
#   bash scripts/validate-templates.sh templates/checkout/welcome/v1/template.json templates/payments/receipt/v2/template.json
set -euo pipefail

[[ $# -gt 0 ]] || { printf 'Usage: %s template.json [template.json ...]\n' "$0" >&2; exit 1; }

validate_file() {
    local path=$1 expected current='' component
    local components=()
    local pattern='^templates/([a-z][a-z0-9]*(-[a-z0-9]+)*)/([a-z][a-z0-9]*(-[a-z0-9]+)*)/(v[1-9][0-9]*)/template\.json$'

    # The existing folder convention determines the exact, case-sensitive SES name.
    if [[ ! $path =~ $pattern ]]; then
        printf 'Expected templates/<client>/<template>/vN/template.json (lowercase kebab case, positive version).\n'
        return 1
    fi

    # Extract the expected SES template name from the path components.
    expected="${BASH_REMATCH[1]}_${BASH_REMATCH[3]}_${BASH_REMATCH[5]}"

    # Check ancestors too: a regular file may otherwise be reached through a symlink.
    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        current="${current:+$current/}$component"
        if [[ -L $current ]]; then
            printf 'Symlink not allowed: %s\n' "$current"
            return 1
        fi
    done
    [[ -f $path ]] || { printf 'Expected an existing regular file.\n'; return 1; }

    # Accept only SES keys: required non-empty Subject/Html and optional string Text.
    if ! jq -e -s --arg name "$expected" '
        def required_string: type == "string" and length > 0;
        length == 1 and (.[0] |
            type == "object" and keys == ["TemplateContent", "TemplateName"] and
            .TemplateName == $name and
            (.TemplateContent | type == "object" and
                (keys == ["Html", "Subject"] or keys == ["Html", "Subject", "Text"]) and
                (.Subject | required_string) and
                (.Html | required_string) and
                (if has("Text") then (.Text | type == "string") else true end)))
    ' "$path" >/dev/null; then
        printf 'Expected only TemplateName="%s" and TemplateContent with required non-empty Subject/Html strings and optional Text string.\n' "$expected"
        return 1
    fi
}

# Check every file and return one failure summary instead of stopping at the first error.
errors=()
for path in "$@"; do
    if details=$(validate_file "$path" 2>&1); then
        printf 'Validated: %s\n' "$path"
    else
        errors+=("$path: $details")
    fi
done

if [[ ${#errors[@]} -gt 0 ]]; then
    printf 'ERROR: Validation failed for %s file(s):\n' "${#errors[@]}" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    exit 1
fi