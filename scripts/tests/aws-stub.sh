#!/usr/bin/env bash
# Purpose: Emulate only the lifecycle AWS operations in isolated test state.
# Usage examples:
#   AWS_STUB_STATE=/tmp/state AWS_STUB_LOG=/tmp/calls aws --region eu-south-1 sts get-caller-identity
set -euo pipefail

region="" service="" operation="" tenant="" resource="" payload="" item="" condition="" values=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) region=$2; shift 2 ;;
        --output|--cli-connect-timeout|--cli-read-timeout|--profile|--table-name|--key) shift 2 ;;
        --tenant-name) tenant=$2; shift 2 ;;
        --template-name) shift 2 ;;
        --resource-arn) resource=$2; shift 2 ;;
        --cli-input-json) payload=$2; shift 2 ;;
        --item) item=$2; shift 2 ;;
        --condition-expression) condition=$2; shift 2 ;;
        --expression-attribute-values) values=$2; shift 2 ;;
        --no-cli-pager|--no-cli-auto-prompt|--consistent-read) shift ;;
        sts|sesv2|dynamodb) service=$1; operation=$2; shift 2 ;;
        *) printf 'Unexpected stub argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
printf '%s %s %s\n' "$region" "$service" "$operation" >> "$AWS_STUB_LOG"
mkdir -p "$AWS_STUB_STATE"
error() { printf 'An error occurred (%s) when calling the %s operation: fixture\n' "$1" "$operation" >&2; exit 254; }
scenario=${AWS_STUB_SCENARIO:-normal}
case "$scenario:$operation" in
    throttle:create-email-template|timeout:create-email-template)
        counter="$AWS_STUB_STATE/attempts-$region"
        attempts=0
        [[ ! -f $counter ]] || attempts=$(< "$counter")
        attempts=$((attempts + 1)); printf '%s' "$attempts" > "$counter"
        if [[ $attempts -lt 3 ]]; then
            if [[ $scenario == timeout ]]; then printf 'Read timeout on endpoint URL\n' >&2; exit 255; fi
            error TooManyRequestsException
        fi ;;
    exhausted:create-email-template) error TooManyRequestsException ;;
    denied:create-email-template) error AccessDeniedException ;;
    partial:create-tenant-resource-association) [[ $region != eu-central-1 ]] || error AccessDeniedException ;;
    retire-partial:delete-email-template) [[ $region != eu-central-1 ]] || error AccessDeniedException ;;
    secondary-tenant:get-tenant) [[ $region != eu-central-1 ]] || error NotFoundException ;;
    db-failure:put-item) error AccessDeniedException ;;
esac

template="$AWS_STUB_STATE/template-$region.json"
association="$AWS_STUB_STATE/association-$region"
registry="$AWS_STUB_STATE/registry.json"
case "$service:$operation" in
    sts:get-caller-identity)
        account=123456789012
        [[ $scenario != wrong-account ]] || account=999999999999
        jq -cn --arg account "$account" '{Account:$account,Arn:("arn:aws:sts::"+$account+":assumed-role/fixture/session")}' ;;
    sesv2:get-tenant) jq -cn --arg tenant "$tenant" '{Tenant:{TenantName:$tenant}}' ;;
    sesv2:create-email-template)
        [[ ! -f $template ]] || error AlreadyExistsException
        [[ $payload == file://* ]] || error InlineTemplatePayload
        jq -c '.TemplateContent' "${payload#file://}" > "$template"
        printf '{}\n' ;;
    sesv2:get-email-template)
        [[ -f $template ]] || error NotFoundException
        jq -c '{TemplateContent:.}' "$template" ;;
    sesv2:list-resource-tenants)
        if [[ $scenario == shared ]]; then
            printf '{"ResourceTenants":[{"TenantName":"oml-d-tenant-other"}]}\n'
        elif [[ $scenario == truncated ]]; then
            printf '{"ResourceTenants":[],"NextToken":"unconsumed"}\n'
        elif [[ -f $association ]]; then
            jq -cn --arg tenant "$(< "$association")" --arg resource "$resource" '{ResourceTenants:[{TenantName:$tenant,ResourceArn:$resource}]}'
        else printf '{"ResourceTenants":[]}\n'; fi ;;
    sesv2:create-tenant-resource-association)
        [[ ! -f $association ]] || error AlreadyExistsException
        printf '%s' "$tenant" > "$association"; printf '{}\n' ;;
    sesv2:delete-tenant-resource-association)
        [[ -f $association ]] || error NotFoundException
        rm -- "$association"; printf '{}\n' ;;
    sesv2:delete-email-template)
        [[ -f $template ]] || error NotFoundException
        rm -- "$template"; printf '{}\n' ;;
    dynamodb:get-item)
        if [[ -f $registry ]]; then jq -c '{Item:.}' "$registry"; fi ;;
    dynamodb:put-item)
        [[ $region == eu-south-1 && $condition == 'attribute_not_exists(TemplateName)' ]] || error InvalidCondition
        [[ ! -f $registry ]] || error ConditionalCheckFailedException
        [[ -f $AWS_STUB_STATE/association-eu-south-1 && -f $AWS_STUB_STATE/association-eu-central-1 ]] || error PrematureMetadata
        jq -e 'keys == ["TemplateName","lastModifiedDate","tenantName"]' <<< "$item" >/dev/null || error InvalidItem
        printf '%s' "$item" > "$registry"; printf '{}\n' ;;
    dynamodb:delete-item)
        [[ $region == eu-south-1 && $condition == 'attribute_not_exists(TemplateName) OR tenantName = :tenant' ]] || error InvalidCondition
        [[ ! -f $AWS_STUB_STATE/template-eu-south-1.json && ! -f $AWS_STUB_STATE/template-eu-central-1.json ]] || error PrematureMetadata
        if [[ -f $registry ]]; then
            jq -e --arg tenant "$(jq -r '.[":tenant"].S' <<< "$values")" '.tenantName.S == $tenant' "$registry" >/dev/null || error ConditionalCheckFailedException
            rm -- "$registry"
        fi
        printf '{}\n' ;;
    *) printf 'Unexpected AWS operation: %s/%s\n' "$service" "$operation" >&2; exit 2 ;;
esac