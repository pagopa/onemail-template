#!/usr/bin/env bash
# Purpose: Validate mutable template assets and approved deletion paths, paths first.
# Usage examples:
#   bash scripts/validate-templates.sh --input-dir . --base-ref origin/main
#   bash scripts/validate-templates.sh --input-dir . --file templates/demo/welcome/v1/template.json
set -euo pipefail

fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

asset_name() {
    local path=$1
    local template_pattern='^templates/([a-z][a-z0-9]*(-[a-z0-9]+)*)/([a-z][a-z0-9]*(-[a-z0-9]+)*)/(v[1-9][0-9]*)/template\.json$'
    if [[ $path =~ $template_pattern ]]; then
        printf '%s_%s_%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"
        return
    fi
    fail "Invalid asset path $path: expected templates/<product>/<logical-template>/v<positive-integer>/template.json; lowercase kebab case, no leading zeros."
}

safe_path() {
    local root=$1 path=$2 component current=$1 absolute
    local components=()
    absolute="$root/$path"
    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        [[ $component != . && $component != .. ]] || fail "Path escape: $path"
        current="$current/$component"
        [[ ! -L $current ]] || fail "Symlink not allowed: $path ($current)"
    done
    [[ -f $absolute ]] || fail "Asset must be a regular file: $path."
}

validate_assets() {
    local root=$1 base=$2 paths_only=$3 path name prior_name
    shift 3
    local paths=("$@") names=()
    [[ -d $root ]] || fail "Input directory not found: $root"
    [[ ! -L $root ]] || fail "Symlink input directory: $root"
    root=$(cd -- "$root" && pwd -P)
    if [[ -n $base ]]; then
        git -C "$root" rev-parse --verify "$base^{commit}" >/dev/null || fail "Invalid base commit: $base"
    fi
    for path in "${paths[@]+"${paths[@]}"}"; do
        name=$(asset_name "$path")
        [[ ${#name} -le 64 ]] || fail "TemplateName exceeds SES 64-character limit: $name"
        if [[ ! -f $root/$path ]]; then
            [[ -n $base ]] || fail "Asset must be a regular file: $path."
            git -C "$root" cat-file -e "$base:$path" 2>/dev/null || fail "Deleted asset was not present in base commit: $path"
            continue
        fi
        safe_path "$root" "$path"
    done
    [[ $paths_only == false ]] || return 0
    command -v jq >/dev/null || fail "Missing dependency: jq"
    for path in "${paths[@]+"${paths[@]}"}"; do
        [[ -f $root/$path ]] || continue
        name=$(asset_name "$path")
        jq -e -s --arg name "$name" '
            length == 1 and (.[0] | type == "object" and
            (keys == ["TemplateContent", "TemplateName"]) and .TemplateName == $name and
            (.TemplateContent | type == "object" and
            ((keys == ["Html", "Subject"]) or (keys == ["Html", "Subject", "Text"])) and
            (.Subject | type == "string") and (.Html | type == "string") and
            (if has("Text") then (.Text | type == "string") else true end)))
        ' "$root/$path" >/dev/null || fail "Invalid template schema or TemplateName: $path (expected $name)"
        for prior_name in "${names[@]+"${names[@]}"}"; do
            [[ $prior_name != "$name" ]] || fail "Duplicate TemplateName: $name"
        done
        names+=("$name")
        printf '✅ Validated: %s -> %s\n' "$path" "$name"
    done
}

collect_assets() {
    local root=$1 base=$2 path
    ASSET_PATHS=()
    if [[ -n $base ]]; then
        git -C "$root" rev-parse --verify "$base^{commit}" >/dev/null || fail "Invalid base commit: $base"
        while IFS= read -r -d '' path; do
            ASSET_PATHS+=("$path")
        done < <(git -C "$root" diff --name-only --no-renames -z "$base" -- templates/)
        return
    fi
    path=templates
    [[ ! -L $root/$path ]] || fail "Symlink not allowed: $path"
    [[ -d $root/$path ]] || return
    while IFS= read -r -d '' asset; do
        ASSET_PATHS+=("${asset#"$root/"}")
    done < <(find "$root/$path" \( -type f -o -type l \) -print0)
}

validate_main() {
    local root="." base="" paths_only=false
    local files=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --paths-only) paths_only=true; shift ;;
            --help) printf '%s\n' 'Usage: validate-templates.sh --input-dir ROOT [--base-ref COMMIT] [--file PATH ...] [--paths-only]'; return ;;
            --input-dir|--base-ref|--file)
                [[ $# -ge 2 && -n $2 ]] || fail "Missing value for $1"
                case "$1" in
                    --input-dir) root=$2 ;;
                    --base-ref) base=$2 ;;
                    --file) files+=("$2") ;;
                esac
                shift 2 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
    [[ -d $root ]] || fail "Input directory not found: $root"
    [[ ! -L $root ]] || fail "Symlink input directory: $root"
    root=$(cd -- "$root" && pwd -P)
    if [[ ${#files[@]} -eq 0 ]]; then
        collect_assets "$root" "$base"
        files=("${ASSET_PATHS[@]+"${ASSET_PATHS[@]}"}")
    fi
    validate_assets "$root" "$base" "$paths_only" "${files[@]+"${files[@]}"}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    validate_main "$@"
fi