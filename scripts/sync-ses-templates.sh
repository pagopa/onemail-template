#!/usr/bin/env bash
# Purpose: Synchronize SES templates, tenant associations, and DynamoDB registry metadata.
# Usage examples:
#   bash scripts/sync-ses-templates.sh -e d templates/checkout/welcome/v1/template.json
#   bash scripts/sync-ses-templates.sh -e p templates/checkout/welcome/v1/template.json templates/payments/receipt/v1/template.json
#   bash scripts/sync-ses-templates.sh -e d -d templates/checkout/welcome/v1/template.json
# AWS credentials, AWS_REGION, and AWS_ACCOUNT_ID are supplied by the pipeline.
set -euo pipefail

# The pipeline selects the environment; this script only uses its short name for tenant naming.
DELETE=false ENV_SHORT=''
while getopts ':de:' option; do
    case "$option" in
        d) DELETE=true ;;
        e) ENV_SHORT=$OPTARG ;;
        *) printf '❌ Usage: %s -e env-short [-d] template.json [template.json ...]\n' "$0" >&2; exit 1 ;;
    esac
done
shift "$((OPTIND - 1))"

if [[ -z $ENV_SHORT || $# -eq 0 ]]; then
    printf '❌ Provide -e env-short and template paths (deleted paths do not need to exist).\n' >&2
    exit 1
fi

# Use AWS CLI retries for transient errors, without retrying the whole template sequence.
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
TABLE_NAME=${AWS_TEMPLATE_DB_TABLE:-TemplateRegistry}
REGISTRY_REGION="eu-south-1"

aws_request() {
    local status=0
    aws "$@" || status=$?
    # Wait 1s after every SES v2 request (to avoid hitting rate limits -  1 request per second)
    if [[ $1 == sesv2 ]]; then
        sleep 1 || return 1
    fi
    return "$status"
}

# Only the expected already-existing/already-absent error is safe to ignore on reruns.
aws_call() {
    # Ignore only this optional AWS error code; an empty value means no error is ignored.
    local expected_error=$1 output
    shift
    if output=$(aws_request "$@" 2>&1); then
        return 0
    fi
    # Treat the expected error as success to make create/delete operations safe to rerun.
    if [[ -n $expected_error && $output == *"($expected_error)"* ]]; then
        return 0
    fi
    # Report all other AWS errors and propagate failure to the caller.
    printf '❌ AWS %s failed: %s\n' "$*" "$output" >&2
    return 1
}

publish_template() {
    local path=$1 name=$2 output
    if output=$(aws_request sesv2 create-email-template --cli-input-json "file://$path" 2>&1); then
        return 0
    fi
    if [[ $output != *'(AlreadyExistsException)'* ]]; then
        printf '❌ Cannot create SES template %s: %s\n' "$name" "$output" >&2
        return 1
    fi
    aws_call '' sesv2 update-email-template --cli-input-json "file://$path"
}

sync_template() {
    local path=$1 name=$2 client_path client tenant resource status=ACTIVE date item values output
    # Example path: templates/checkout/welcome/v1/template.json.
    client_path=${path%/*}         # Remove template.json: templates/checkout/welcome/v1.
    client_path=${client_path%/*}  # Remove v1: templates/checkout/welcome.
    client_path=${client_path%/*}  # Remove welcome: templates/checkout.
    client=${client_path##*/}      # Keep the last folder name: checkout.
    tenant="oml-$ENV_SHORT-tenant-$client" # With ENV_SHORT=d: oml-d-tenant-checkout.
    resource="arn:aws:ses:$AWS_REGION:$AWS_ACCOUNT_ID:template/$name" # Example: arn:aws:ses:eu-south-1:123456789012:template/checkout_welcome_v1.
    printf 'ℹ️ Synchronizing %s for %s in %s\n' "$name" "$tenant" "$AWS_REGION" # Log template, tenant, and region; no AWS call.

    # Explicit guards stop this template at the first error, even when called inside an if.
    # SES and DynamoDB cannot share a transaction: reruns complete any partial work forward.
    # Missing associations and templates are already in the desired state during deletion.
    if [[ $DELETE == true ]]; then
        aws_call NotFoundException sesv2 delete-tenant-resource-association \
            --tenant-name "$tenant" --resource-arn "$resource" || return 1
        aws_call NotFoundException sesv2 delete-email-template --template-name "$name" || return 1
        status=RETIRED
    else
        if ! output=$(aws sesv2 get-tenant --tenant-name "$tenant" 2>&1); then
            if [[ $output == *'(NotFoundException)'* ]]; then
                WARNINGS+=("$name: tenant $tenant does not exist in $AWS_REGION; publication skipped.")
                return 0
            fi
            printf '❌ Cannot check SES tenant %s: %s\n' "$tenant" "$output" >&2
            return 1
        fi
        publish_template "$path" "$name" || return 1
        aws_call AlreadyExistsException sesv2 create-tenant-resource-association \
            --tenant-name "$tenant" --resource-arn "$resource" || return 1
    fi

    # Publish metadata only after local SES operations succeed; retain a tombstone on deletion.
    date=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
    item=$(jq -cn --arg name "$name" --arg tenant "$tenant" --arg date "$date" --arg status "$status" '
        {TemplateName:{S:$name}, tenantName:{S:$tenant}, lastModifiedDate:{S:$date}, status:{S:$status}} +
        (if $status == "RETIRED" then {retiredAt:{S:$date}} else {} end)
    ') || return 1
    values=$(jq -cn --arg tenant "$tenant" '{":tenant":{S:$tenant}}') || return 1
    aws_call '' --region "$REGISTRY_REGION" dynamodb put-item --table-name "$TABLE_NAME" \
        --item "$item" --condition-expression 'attribute_not_exists(TemplateName) OR tenantName = :tenant' \
        --expression-attribute-values "$values" || return 1
    printf '✅ Synchronized %s: %s\n' "$name" "$status"
}

# Finish independent templates before failing the batch, and list every failed template.
FAILED=()
WARNINGS=()
for path in "$@"; do
    # PR validation enforces the naming contract; here we only convert the trusted path.
    # Example: templates/checkout/welcome/v1/template.json -> checkout/welcome/v1/template.json.
    name=${path#templates/}
    # Example: checkout/welcome/v1/template.json -> checkout/welcome/v1.
    name=${name%/template.json}
    # Example: checkout/welcome/v1 -> checkout_welcome_v1 (the SES template name).
    name=${name//\//_}
    if ! sync_template "$path" "$name"; then
        FAILED+=("$name")
    fi
done
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf 'WARNING: Skipped templates (%s):\n' "${#WARNINGS[@]}" >&2
    for warning in "${WARNINGS[@]}"; do
        if [[ ${GITHUB_ACTIONS:-} == true ]]; then
            printf '::warning::%s\n' "$warning"
        else
            printf '  - %s\n' "$warning" >&2
        fi
    done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf '❌ Failed templates:\n' >&2
    printf '  - %s\n' "${FAILED[@]}" >&2
    exit 1
fi