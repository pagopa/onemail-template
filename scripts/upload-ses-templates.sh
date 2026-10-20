#!/usr/bin/env bash
# Purpose: Publish active SES templates and retire versions deleted through reviewed pull requests.
# Usage examples:
#   bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix --dry-run
#   bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix \
#     --account-id 123456789012 --table-name REGISTRY --approved-ref COMMIT
#   Add --change-base PREVIOUS_MAIN_SHA to retire templates deleted by a merged change.
#   For another environment, add --retire --file templates/demo/welcome/v1/template.json \
#     --retirement-authorization queued-send-risk-accepted for an approved retirement.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=validate-templates.sh
source "$SCRIPT_DIR/validate-templates.sh"

ROOT="" ENVIRONMENT="" ACCOUNT_ID="" TABLE_NAME="" APPROVED_REF="" CHANGE_BASE="" PROFILE="" LEGACY_TENANT=""
DRY_RUN=false RETIRE=false NO_PREFIX=false RETIREMENT_AUTHORIZATION=""
MAX_ATTEMPTS=3 RETRY_DELAY=2 RATE_DELAY=1.1
REGIONS=(eu-south-1 eu-central-1)
FILES=() RETIRED_FILES=()
AWS_OUTPUT="" AWS_ERROR="" PARTITION=""

usage() {
    printf '%s\n' \
        'Usage: upload-ses-templates.sh --input-dir ROOT --env dev|uat|prod --no-prefix [options]' \
        'ROOT contains templates/. --file PATH may be repeated; otherwise scan all active templates.' \
        'Mutation requires --account-id ID --table-name NAME --approved-ref COMMIT matching latest protected origin/main.' \
        'Options: --dry-run (no AWS), --profile NAME, --max-attempts 1..5, --retry-delay 0..30, --rate-delay 0..5.' \
        'Merged deletions: --change-base PREVIOUS_MAIN_SHA retires templates removed since that commit.' \
        'Manual retirement: --retire --file templates/PRODUCT/LOGICAL/vN/template.json --retirement-authorization queued-send-risk-accepted; the file must be deleted in Git.' \
        'Both eu-south-1 and eu-central-1 are mandatory; --regions eu-south-1,eu-central-1 is accepted.' \
        'Legacy --tenant is accepted only if it matches the derived tenant. URL clones, prefixes, and single-region writes are no longer supported.' \
        'Existing TemplateName values are synchronized to approved Git content after tenant ownership checks. Errors leave partial work for a forward rerun; no rollback deletion.'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --retire) RETIRE=true; shift ;;
        --no-prefix) NO_PREFIX=true; shift ;;
        --input-dir|--env|--account-id|--table-name|--approved-ref|--change-base|--profile|--tenant|--file|--max-attempts|--retry-delay|--rate-delay|--retirement-authorization|--regions)
            [[ $# -ge 2 && -n $2 ]] || fail "Missing value for $1"
            case "$1" in
                --input-dir) ROOT=$2 ;;
                --env) ENVIRONMENT=$2 ;;
                --account-id) ACCOUNT_ID=$2 ;;
                --table-name) TABLE_NAME=$2 ;;
                --approved-ref) APPROVED_REF=$2 ;;
                --change-base) CHANGE_BASE=$2 ;;
                --profile) PROFILE=$2 ;;
                --tenant) LEGACY_TENANT=$2 ;;
                --file) FILES+=("$2") ;;
                --max-attempts) MAX_ATTEMPTS=$2 ;;
                --retry-delay) RETRY_DELAY=$2 ;;
                --rate-delay) RATE_DELAY=$2 ;;
                --retirement-authorization) RETIREMENT_AUTHORIZATION=$2 ;;
                --regions) [[ $2 == eu-south-1,eu-central-1 ]] || fail 'Both required regions must be eu-south-1,eu-central-1.' ;;
            esac
            shift 2 ;;
        --url|--prefix|--region|--recursive|--no-fail-fast)
            fail "Legacy option $1 is unsafe for publication; use --input-dir ROOT --env ENV --no-prefix and both regions. See --help." ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -n $ROOT && -d $ROOT ]] || fail 'Explicit --input-dir ROOT is required.'
[[ ! -L $ROOT ]] || fail 'Symlink input directory is not allowed.'
ROOT=$(cd -- "$ROOT" && pwd -P)
[[ $NO_PREFIX == true ]] || fail 'Explicit --no-prefix is required; names come from asset paths.'
case "$ENVIRONMENT" in
    dev) ENV_SHORT=d ;;
    uat) ENV_SHORT=u ;;
    prod) ENV_SHORT=p ;;
    *) fail '--env must be dev, uat, or prod.' ;;
esac
[[ $MAX_ATTEMPTS =~ ^[1-5]$ ]] || fail '--max-attempts must be 1..5.'
[[ $RETRY_DELAY =~ ^([0-9]|[12][0-9]|30)$ ]] || fail '--retry-delay must be 0..30 seconds.'
[[ $RATE_DELAY =~ ^([0-4](\.[0-9]+)?|5(\.0+)?)$ ]] || fail '--rate-delay must be 0..5 seconds.'
if [[ $RETIRE == true ]]; then
    [[ ${#FILES[@]} -gt 0 ]] || fail 'Retirement requires explicit --file request paths.'
    [[ $RETIREMENT_AUTHORIZATION == queued-send-risk-accepted ]] || fail 'Retirement requires explicit queued-send-risk-accepted authorization; drain timing is unresolved.'
    [[ -z $CHANGE_BASE ]] || fail '--change-base cannot be combined with explicit --retire.'
elif [[ -n $RETIREMENT_AUTHORIZATION ]]; then
    fail '--retirement-authorization is only valid with --retire.'
fi
if [[ -n $CHANGE_BASE ]]; then
    [[ $RETIRE == false && ${#FILES[@]} -eq 0 ]] || fail '--change-base is only valid for an automatic publish run without --file.'
fi

collect_assets "$ROOT" ""
ALL_ASSETS=("${ASSET_PATHS[@]+"${ASSET_PATHS[@]}"}")
validate_assets "$ROOT" "" false "${ALL_ASSETS[@]+"${ALL_ASSETS[@]}"}"
if [[ $RETIRE == true ]]; then
    RETIRED_FILES=("${FILES[@]+"${FILES[@]}"}")
    FILES=()
else
    if [[ ${#FILES[@]} -eq 0 ]]; then FILES=("${ALL_ASSETS[@]+"${ALL_ASSETS[@]}"}"); fi
    validate_assets "$ROOT" "" false "${FILES[@]+"${FILES[@]}"}"
    if [[ -n $CHANGE_BASE ]]; then
        git -C "$ROOT" rev-parse --verify "$CHANGE_BASE^{commit}" >/dev/null || fail "Invalid change base: $CHANGE_BASE"
        while IFS= read -r -d '' path; do
            asset_name "$path" >/dev/null
            git -C "$ROOT" cat-file -e "$CHANGE_BASE:$path" 2>/dev/null || fail "Deleted template was not present at change base: $path"
            RETIRED_FILES+=("$path")
        done < <(git -C "$ROOT" diff --no-renames --name-only --diff-filter=D -z "$CHANGE_BASE" HEAD -- templates/)
    fi
fi

validate_removed_files() {
    local path deletion_commit
    for path in "${RETIRED_FILES[@]+"${RETIRED_FILES[@]}"}"; do
        asset_name "$path" >/dev/null
        [[ ! -e $ROOT/$path && ! -L $ROOT/$path ]] || fail "Cannot retire a template still present in the repository: $path"
        deletion_commit=$(git -C "$ROOT" log -1 --diff-filter=D --format=%H HEAD -- "$path")
        [[ -n $deletion_commit ]] || fail "Template retirement requires a deletion commit on the current history: $path"
    done
}

validate_removed_files

tenant_for() {
    local path=$1 product
    product=${path#*/}; product=${product%%/*}
    printf 'oml-%s-tenant-%s\n' "$ENV_SHORT" "$product"
}

for path in "${FILES[@]+"${FILES[@]}"}"; do
    [[ $path == templates/* ]] || fail "Publication only accepts template assets: $path"
    tenant=$(tenant_for "$path")
    [[ ${#tenant} -le 64 ]] || fail "Derived tenant exceeds 64 characters: $tenant"
    [[ -z $LEGACY_TENANT || $LEGACY_TENANT == "$tenant" ]] || fail "--tenant does not match derived tenant: $tenant"
done
for path in "${RETIRED_FILES[@]+"${RETIRED_FILES[@]}"}"; do
    tenant=$(tenant_for "$path")
    [[ ${#tenant} -le 64 ]] || fail "Derived tenant exceeds 64 characters: $tenant"
    [[ -z $LEGACY_TENANT || $LEGACY_TENANT == "$tenant" ]] || fail "--tenant does not match derived tenant: $tenant"
done
if [[ $DRY_RUN == true ]]; then
    printf '✅ Dry-run complete. No AWS calls made; validated %s active and %s removed template(s).\n' "${#FILES[@]}" "${#RETIRED_FILES[@]}"
    exit 0
fi

[[ $ACCOUNT_ID =~ ^[0-9]{12}$ ]] || fail 'Mutation requires a valid --account-id.'
[[ $TABLE_NAME =~ ^[A-Za-z0-9_.-]{3,255}$ ]] || fail 'Mutation requires --table-name (3..255 valid characters).'
[[ $APPROVED_REF =~ ^[a-f0-9]{40}$ ]] || fail 'Mutation requires --approved-ref with a full protected-main commit SHA.'
command -v aws >/dev/null || fail 'Missing dependency: AWS CLI v2'
export AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard
AWS_COMMAND=(aws --no-cli-pager --no-cli-auto-prompt --output json --cli-connect-timeout 10 --cli-read-timeout 30)
[[ -z $PROFILE ]] || AWS_COMMAND+=(--profile "$PROFILE")

assert_approved() {
    git -C "$ROOT" fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' || fail 'Cannot verify latest protected main; no mutation authorized.'
    [[ $(git -C "$ROOT" rev-parse HEAD) == "$APPROVED_REF" && $(git -C "$ROOT" rev-parse refs/remotes/origin/main) == "$APPROVED_REF" ]] || fail 'Stale publication/retirement: checkout must equal latest protected origin/main.'
    [[ -z $(git -C "$ROOT" status --porcelain --untracked-files=all -- templates scripts .github/workflows) ]] || fail 'Mutation requires clean approved assets, scripts, and workflows.'
}

aws_call() {
    local region=$1 service=$2 operation=$3 attempt=1
    shift 3
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
        case "$operation" in create-*|update-*|delete-*|put-item) assert_approved ;; esac
        [[ $RATE_DELAY == 0 ]] || sleep "$RATE_DELAY"
        if AWS_OUTPUT=$("${AWS_COMMAND[@]}" --region "$region" "$service" "$operation" "$@" 2>&1); then
            AWS_ERROR=""
            return 0
        fi
        AWS_ERROR=""
        if [[ $AWS_OUTPUT =~ An\ error\ occurred\ \(([^\)]+)\) ]]; then
            AWS_ERROR=${BASH_REMATCH[1]}
        fi
        case "$AWS_ERROR" in
            TooManyRequestsException|Throttling|ThrottlingException|ThrottlingError|ServiceUnavailable|ServiceUnavailableException|InternalServerError|InternalServerErrorException|InternalFailure|RequestTimeout|RequestTimeoutException) ;;
            *)
                if [[ $AWS_OUTPUT != *'Read timeout on endpoint URL'* && $AWS_OUTPUT != *'Connect timeout on endpoint URL'* && $AWS_OUTPUT != *'Could not connect to the endpoint URL'* ]]; then
                    printf '❌ %s %s/%s attempt %s: %s\n' "$region" "$service" "$operation" "$attempt" "$AWS_OUTPUT" >&2
                    return 1
                fi ;;
        esac
        [[ $attempt -lt $MAX_ATTEMPTS ]] || break
        printf '⚠️ Retry %s/%s %s in %s\n' "$attempt" "$MAX_ATTEMPTS" "$operation" "$region" >&2
        [[ $RETRY_DELAY == 0 ]] || sleep "$((RETRY_DELAY * attempt))"
        attempt=$((attempt + 1))
    done
    printf '❌ Retry limit reached: %s %s/%s: %s\n' "$region" "$service" "$operation" "$AWS_OUTPUT" >&2
    return 1
}

read_registry() {
    local name=$1 tenant=$2
    REGISTRY_KEY=$(jq -cn --arg name "$name" '{TemplateName:{S:$name}}')
    aws_call eu-south-1 dynamodb get-item --table-name "$TABLE_NAME" --key "$REGISTRY_KEY" --consistent-read || fail "Registry read failed: $name"
    [[ -n $AWS_OUTPUT ]] || AWS_OUTPUT='{}'
    REGISTRY_ITEM=$(jq -ce '.Item // {}' <<< "$AWS_OUTPUT") || fail "Invalid registry response: $name"
    if [[ $REGISTRY_ITEM != '{}' ]]; then
        jq -e --arg name "$name" --arg tenant "$tenant" '
            keys == ["TemplateName", "lastModifiedDate", "tenantName"] and
            .TemplateName.S == $name and .tenantName.S == $tenant and
            (.lastModifiedDate.S | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        ' <<< "$REGISTRY_ITEM" >/dev/null || fail "Registry ownership/schema conflict: $name (expected $tenant)"
    fi
}

resource_tenants() {
    local region=$1 resource=$2 tenant=$3
    aws_call "$region" sesv2 list-resource-tenants --resource-arn "$resource" || fail "Cannot verify resource tenants: $resource"
    jq -e --arg tenant "$tenant" '
        (.NextToken // null) == null and (.ResourceTenants | type == "array") and
        all(.ResourceTenants[]; (.TenantName | type == "string") and .TenantName == $tenant)
    ' <<< "$AWS_OUTPUT" >/dev/null || fail "Shared/unknown resource tenants; refusing mutation: $resource"
}

publish_region() {
    local region=$1 path=$2 name=$3 tenant=$4 desired existing resource
    desired=$(jq -cS '.TemplateContent' "$ROOT/$path")
    resource="arn:$PARTITION:ses:$region:$ACCOUNT_ID:template/$name"
    if ! aws_call "$region" sesv2 create-email-template --cli-input-json "file://$ROOT/$path"; then
        [[ $AWS_ERROR == AlreadyExistsException ]] || fail "Template creation failed: $name in $region; rerun forward."
    fi
    aws_call "$region" sesv2 get-email-template --template-name "$name" || fail "Cannot verify SES content: $name in $region"
    existing=$(jq -ceS '.TemplateContent | select(type == "object")' <<< "$AWS_OUTPUT") || fail "Invalid SES content: $name in $region"
    if [[ $existing != "$desired" ]]; then
        resource_tenants "$region" "$resource" "$tenant"
        aws_call "$region" sesv2 update-email-template --cli-input-json "file://$ROOT/$path" || fail "Template update failed: $name in $region; rerun forward."
        aws_call "$region" sesv2 get-email-template --template-name "$name" || fail "Cannot verify updated SES content: $name in $region"
        existing=$(jq -ceS '.TemplateContent | select(type == "object")' <<< "$AWS_OUTPUT") || fail "Invalid updated SES content: $name in $region"
        [[ $existing == "$desired" ]] || fail "Updated SES content does not match approved source: $name in $region"
        printf '✅ Regional template updated and verified: %s in %s\n' "$name" "$region"
    fi
    resource_tenants "$region" "$resource" "$tenant"
    if ! aws_call "$region" sesv2 create-tenant-resource-association --tenant-name "$tenant" --resource-arn "$resource"; then
        [[ $AWS_ERROR == AlreadyExistsException ]] || fail "Association failed: $name in $region; registry not written."
    fi
    resource_tenants "$region" "$resource" "$tenant"
    jq -e --arg tenant "$tenant" 'any(.ResourceTenants[]; .TenantName == $tenant)' <<< "$AWS_OUTPUT" >/dev/null || fail "Association not verified: $name in $region"
    printf '✅ Regional publication verified: %s in %s\n' "$name" "$region"
}

retire_region() {
    local region=$1 name=$2 tenant=$3 resource
    resource="arn:$PARTITION:ses:$region:$ACCOUNT_ID:template/$name"
    if ! aws_call "$region" sesv2 get-email-template --template-name "$name"; then
        [[ $AWS_ERROR == NotFoundException ]] || fail "Cannot inspect retirement target: $name in $region"
        printf '✅ Already absent: %s in %s\n' "$name" "$region"
        return 0
    fi
    resource_tenants "$region" "$resource" "$tenant"
    if jq -e --arg tenant "$tenant" 'any(.ResourceTenants[]; .TenantName == $tenant)' <<< "$AWS_OUTPUT" >/dev/null; then
        if ! aws_call "$region" sesv2 delete-tenant-resource-association --tenant-name "$tenant" --resource-arn "$resource"; then
            [[ $AWS_ERROR == NotFoundException ]] || fail "Association deletion failed: $name in $region"
        fi
    fi
    resource_tenants "$region" "$resource" "$tenant"
    jq -e '.ResourceTenants | length == 0' <<< "$AWS_OUTPUT" >/dev/null || fail "Associations remain: $name in $region"
    if ! aws_call "$region" sesv2 delete-email-template --template-name "$name"; then
        [[ $AWS_ERROR == NotFoundException ]] || fail "Template deletion failed: $name in $region"
    fi
    if aws_call "$region" sesv2 get-email-template --template-name "$name"; then
        fail "Template still present after deletion: $name in $region"
    fi
    [[ $AWS_ERROR == NotFoundException ]] || fail "Cannot verify deletion: $name in $region"
    printf '✅ Regional retirement verified: %s in %s\n' "$name" "$region"
}

assert_approved
aws_call eu-south-1 sts get-caller-identity || fail 'Unable to verify AWS identity.'
[[ $(jq -r '.Account' <<< "$AWS_OUTPUT") == "$ACCOUNT_ID" ]] || fail 'Active account differs from --account-id; cancelled.'
PARTITION=$(jq -er '.Arn | split(":")[1] | select(. == "aws")' <<< "$AWS_OUTPUT") || fail 'Expected AWS commercial partition.'
PREFLIGHT_FILES=("${FILES[@]+"${FILES[@]}"}" "${RETIRED_FILES[@]+"${RETIRED_FILES[@]}"}")
for path in "${PREFLIGHT_FILES[@]+"${PREFLIGHT_FILES[@]}"}"; do
    name=$(asset_name "$path")
    tenant=$(tenant_for "$path")
    for region in "${REGIONS[@]}"; do
        aws_call "$region" sesv2 get-tenant --tenant-name "$tenant" || fail "Tenant not accessible: $tenant in $region; no publication started."
        jq -e --arg tenant "$tenant" '.Tenant.TenantName == $tenant' <<< "$AWS_OUTPUT" >/dev/null || fail "Unexpected tenant identity: $tenant in $region"
    done
done

for path in "${FILES[@]+"${FILES[@]}"}"; do
    name=$(asset_name "$path")
    tenant=$(tenant_for "$path")
    printf 'ℹ️ Processing %s for %s\n' "$name" "$tenant"
    assert_approved
    read_registry "$name" "$tenant"
    for region in "${REGIONS[@]}"; do
        publish_region "$region" "$path" "$name" "$tenant"
    done
    values=$(jq -cn --arg tenant "$tenant" '{":tenant":{S:$tenant}}')
    item=$(jq -cn --arg name "$name" --arg tenant "$tenant" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{TemplateName:{S:$name},tenantName:{S:$tenant},lastModifiedDate:{S:$date}}')
    if ! aws_call eu-south-1 dynamodb put-item --table-name "$TABLE_NAME" --item "$item" \
        --condition-expression 'attribute_not_exists(TemplateName) OR tenantName = :tenant' \
        --expression-attribute-values "$values"; then
        [[ $AWS_ERROR == ConditionalCheckFailedException ]] || fail "Registry write failed: $name; rerun forward."
        read_registry "$name" "$tenant"
        [[ $REGISTRY_ITEM != '{}' ]] || fail "Registry disappeared during conditional write: $name"
    fi
    printf '✅ Completed: %s (%s)\n' "$name" "$ENVIRONMENT"
done

for path in "${RETIRED_FILES[@]+"${RETIRED_FILES[@]}"}"; do
    name=$(asset_name "$path")
    tenant=$(tenant_for "$path")
    printf 'ℹ️ Retiring %s for %s\n' "$name" "$tenant"
    assert_approved
    read_registry "$name" "$tenant"
    for region in "${REGIONS[@]}"; do
        retire_region "$region" "$name" "$tenant"
    done
    values=$(jq -cn --arg tenant "$tenant" '{":tenant":{S:$tenant}}')
    aws_call eu-south-1 dynamodb delete-item --table-name "$TABLE_NAME" --key "$REGISTRY_KEY" \
        --condition-expression 'attribute_not_exists(TemplateName) OR tenantName = :tenant' \
        --expression-attribute-values "$values" || fail "Registry deletion failed: $name; rerun retirement."
    printf '✅ Retired: %s (%s)\n' "$name" "$ENVIRONMENT"
done