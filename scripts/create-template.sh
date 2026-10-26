#!/usr/bin/env bash
# Purpose: Create an empty template scaffold from the repository root.
# Usage: bash scripts/create-template.sh <client> <template> [vN]
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s <client> <template> [vN] (default: v1)\n' "$0" >&2
    exit 1
fi

client=$1
template=$2
# Use v1 only when the version argument is omitted.
version=${3-v1}
name_pattern='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
version_pattern='^v[1-9][0-9]*$'

if [[ ! $client =~ $name_pattern || ! $template =~ $name_pattern ]]; then
    printf 'Client and template names must use lowercase kebab-case and start with a letter.\n' >&2
    exit 1
fi
if [[ ! $version =~ $version_pattern ]]; then
    printf 'Version must use vN with a positive integer and no leading zeroes (for example, v1 or v12).\n' >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to create a template.\n' >&2
    exit 1
fi

directory="templates/$client/$template/$version"
# Reject symlinks in every path component before creating directories or writing files.
for ancestor in templates "templates/$client" "templates/$client/$template" "$directory"; do
    if [[ -L $ancestor ]]; then
        printf 'Symlink not allowed: %s\n' "$ancestor" >&2
        exit 1
    fi
done
# Reject an existing version directory even if it contains no template.json yet.
if [[ -e $directory ]]; then
    printf 'Template version path already exists: %s\n' "$directory" >&2
    exit 1
fi

# Populate the path-derived SES name and leave all content fields empty.
content=$(jq -n --arg name "${client}_${template}_${version}" '
    {TemplateName: $name, TemplateContent: {Subject: "", Html: "", Text: ""}}
')
# Reuse existing parent folders, or create them if missing.
mkdir -p "templates/$client/$template"
# Create the version directory exclusively so an existing version is never overwritten.
mkdir "$directory"
printf '%s\n' "$content" > "$directory/template.json"
printf '✅ Created: %s/template.json\nFill in Subject, Html and Text.\n' "$directory"
