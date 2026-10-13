#!/usr/bin/env bash
# Purpose: Exercise lifecycle guards and forward recovery without AWS credentials or repository changes.
# Usage examples:
#   bash scripts/tests/template-lifecycle.test.sh
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=$(cd -- "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"
cp "$TEST_DIR/aws-stub.sh" "$WORK/bin/aws"
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export AWS_STUB_STATE="$WORK/state" AWS_STUB_LOG="$WORK/aws.log"
ROOT="$WORK/repo"
TEMPLATE=templates/fixture/welcome/v1/template.json
RETIREMENT=retirements/fixture/welcome-v1.json
export AWS_STUB_SCENARIO=normal
TESTS=0

check() { [[ $1 == "$2" ]] || { printf '❌ Expected %s, got %s: %s\n' "$2" "$1" "$3" >&2; exit 1; }; }
pass() { TESTS=$((TESTS + 1)); printf '✅ %s\n' "$1"; }
expect_failure() {
    local message=$1
    shift
    if "$@" > "$WORK/output" 2>&1; then printf '❌ Expected failure: %s\n' "$message" >&2; exit 1; fi
    grep -F -- "$message" "$WORK/output" >/dev/null || { cat "$WORK/output"; exit 1; }
}
fixture() {
    rm -rf -- "$ROOT" "$AWS_STUB_STATE"
    : > "$AWS_STUB_LOG"
    mkdir -p "$ROOT/scripts" "$ROOT/templates/fixture/welcome/v1"
    cp "$SOURCE_DIR/upload-ses-templates.sh" "$SOURCE_DIR/validate-templates.sh" "$ROOT/scripts/"
    jq -cn '{TemplateName:"fixture_welcome_v1",TemplateContent:{Subject:"Test fixture",Html:"<p>{{name}}</p>"}}' > "$ROOT/$TEMPLATE"
    git -C "$ROOT" init -q -b main
    git -C "$ROOT" config core.hooksPath /dev/null
    git -C "$ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid add .
    git -C "$ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
    git -C "$ROOT" remote add origin "$ROOT"
    APPROVED=$(git -C "$ROOT" rev-parse HEAD)
    export AWS_STUB_SCENARIO=normal
}
upload() {
    bash "$ROOT/scripts/upload-ses-templates.sh" --input-dir "$ROOT" --env dev --no-prefix \
        --account-id 123456789012 --table-name fixture-registry --approved-ref "$APPROVED" \
        --rate-delay 0 --retry-delay 0 "$@"
}
retirement_request() {
    mkdir -p "$ROOT/retirements/fixture"
    jq -cn '{TemplateName:"fixture_welcome_v1"}' > "$ROOT/$RETIREMENT"
    git -C "$ROOT" add retirements
    git -C "$ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm retirement
    APPROVED=$(git -C "$ROOT" rev-parse HEAD)
}
retire() { upload --retire --file "$RETIREMENT" --retirement-authorization queued-send-risk-accepted; }

fixture
jq() { printf 'parser called\n' >> "$AWS_STUB_LOG"; return 1; }
export -f jq
expect_failure 'Invalid asset path' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --file templates/fixture/welcome/v01/email.json
expect_failure 'Invalid asset path' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --file "$TEMPLATE" --file templates/fixture/welcome/v2/email.json
check "$(wc -l < "$AWS_STUB_LOG" | tr -d ' ')" 0 'filename before parser'
mv "$ROOT/$TEMPLATE" "$WORK/original.json"
ln -s "$WORK/original.json" "$ROOT/$TEMPLATE"
expect_failure 'Symlink not allowed' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --file "$TEMPLATE"
check "$(wc -l < "$AWS_STUB_LOG" | tr -d ' ')" 0 'symlink before parser'
unset -f jq
pass 'Filename and symlink gates precede content parsing'

fixture
upload --dry-run >/dev/null
check "$(wc -l < "$AWS_STUB_LOG" | tr -d ' ')" 0 'no AWS on dry-run'
pass 'Dry-run does not call AWS'
expect_failure 'Duplicate TemplateName' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --file "$TEMPLATE" --file "$TEMPLATE"
pass 'Duplicate selection of the same immutable name is rejected'
bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --base-ref "$APPROVED" >/dev/null
jq '.TemplateContent.Subject = "Changed fixture"' "$ROOT/$TEMPLATE" > "$WORK/changed.json"
cp "$WORK/changed.json" "$ROOT/$TEMPLATE"
expect_failure 'Immutable asset changed' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --base-ref "$APPROVED"
rm "$ROOT/$TEMPLATE"
expect_failure 'retain historical assets' bash "$ROOT/scripts/validate-templates.sh" --input-dir "$ROOT" --base-ref "$APPROVED"
pass 'Base-commit edits and deletions are rejected'

fixture
upload >/dev/null 2>&1
first_item=$(jq -cS . "$AWS_STUB_STATE/registry.json")
upload >/dev/null 2>&1
check "$(jq -cS . "$AWS_STUB_STATE/registry.json")" "$first_item" 'preserve successful timestamp'
check "$(grep -c 'dynamodb put-item' "$AWS_STUB_LOG")" 1 'single registry write'
check "$(grep -c 'update-email-template' "$AWS_STUB_LOG" || true)" 0 'never update'
pass 'Empty registry response, both-region publication and identical rerun preserve metadata'
jq -cn '{Subject:"Conflicting fixture",Html:"<p>conflict</p>"}' > "$AWS_STUB_STATE/template-eu-south-1.json"
expect_failure 'Immutable content conflict' upload
check "$(grep -c 'dynamodb put-item' "$AWS_STUB_LOG")" 1 'conflict does not write registry'
pass 'Existing SES content cannot be overwritten'

fixture
jq -cn '{TemplateName:"fixture_welcome_v1",TemplateContent:{Subject:"Large fixture",Html:("a" * 140000)}}' > "$ROOT/$TEMPLATE"
git -C "$ROOT" add -- "$TEMPLATE"
git -C "$ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm large-fixture
APPROVED=$(git -C "$ROOT" rev-parse HEAD)
upload >/dev/null 2>&1
check "$(jq '.Html | length' "$AWS_STUB_STATE/template-eu-south-1.json")" 140000 'large file payload'
pass 'Large template uses file input instead of a process argument'

for scenario in throttle timeout; do
    fixture; export AWS_STUB_SCENARIO=$scenario
    upload >/dev/null 2>&1
    check "$(grep -c 'eu-south-1 sesv2 create-email-template' "$AWS_STUB_LOG")" 3 'bounded transient recovery'
    pass "$scenario recovers within three attempts"
done
fixture; export AWS_STUB_SCENARIO=exhausted
expect_failure 'Retry limit reached' upload
check "$(grep -c 'create-email-template' "$AWS_STUB_LOG")" 3 'retry ceiling'
pass 'Retries stop at their fixed ceiling'
fixture; export AWS_STUB_SCENARIO=denied
expect_failure 'Template creation failed' upload
check "$(grep -c 'create-email-template' "$AWS_STUB_LOG")" 1 'terminal error not retried'
pass 'Terminal AWS errors are not retried'

fixture; export AWS_STUB_SCENARIO=partial
expect_failure 'Association failed' upload
check "$(grep -c 'dynamodb put-item' "$AWS_STUB_LOG" || true)" 0 'secondary failure gates metadata'
[[ -f $AWS_STUB_STATE/template-eu-south-1.json ]] || exit 1
export AWS_STUB_SCENARIO=normal; upload >/dev/null 2>&1
pass 'Partial regional publication resumes without rollback deletion'
fixture; export AWS_STUB_SCENARIO=db-failure
expect_failure 'Registry write failed' upload
export AWS_STUB_SCENARIO=normal; upload >/dev/null 2>&1
pass 'Registry failure after SES publication resumes forward'

for scenario in wrong-account secondary-tenant; do
    fixture; export AWS_STUB_SCENARIO=$scenario
    if [[ $scenario == wrong-account ]]; then expect_failure 'cancelled.' upload
    else expect_failure 'Tenant not accessible' upload; fi
    check "$(grep -c 'create-email-template' "$AWS_STUB_LOG" || true)" 0 'preflight identity'
    pass "$scenario blocks mutation"
done
fixture; upload >/dev/null 2>&1
jq '.tenantName.S = "oml-d-tenant-other"' "$AWS_STUB_STATE/registry.json" > "$WORK/foreign.json"
cp "$WORK/foreign.json" "$AWS_STUB_STATE/registry.json"
: > "$AWS_STUB_LOG"
expect_failure 'Registry ownership/schema conflict' upload
check "$(grep -c 'create-email-template' "$AWS_STUB_LOG" || true)" 0 'foreign registry protects SES'
retirement_request
expect_failure 'Registry ownership/schema conflict' retire
check "$(grep -c 'delete-email-template' "$AWS_STUB_LOG" || true)" 0 'foreign registry protects retirement'
pass 'Foreign tenant metadata blocks publication and retirement'

fixture; upload >/dev/null 2>&1; retirement_request
expect_failure 'authorization' upload --retire --file "$RETIREMENT"
export AWS_STUB_SCENARIO=shared
expect_failure 'Shared/unknown resource tenants' retire
check "$(grep -c 'delete-email-template' "$AWS_STUB_LOG" || true)" 0 'shared resource protected'
export AWS_STUB_SCENARIO=truncated
expect_failure 'Shared/unknown resource tenants' retire
pass 'Explicit authorization, shared tenants, and incomplete pagination fail closed'
export AWS_STUB_SCENARIO=retire-partial
expect_failure 'Template deletion failed' retire
[[ -f $AWS_STUB_STATE/registry.json && ! -f $AWS_STUB_STATE/template-eu-south-1.json ]] || exit 1
export AWS_STUB_SCENARIO=normal; retire >/dev/null 2>&1; retire >/dev/null 2>&1
[[ ! -f $AWS_STUB_STATE/registry.json && ! -f $AWS_STUB_STATE/template-eu-central-1.json ]] || exit 1
: > "$AWS_STUB_LOG"; upload >/dev/null 2>&1
check "$(grep -c 'create-email-template' "$AWS_STUB_LOG" || true)" 0 'retired version not recreated'
pass 'Partial retirement resumes, deletes metadata last, and guards recreation'

fixture
old_ref=$APPROVED
retirement_request
APPROVED=$old_ref
expect_failure 'Stale publication/retirement' upload
check "$(wc -l < "$AWS_STUB_LOG" | tr -d ' ')" 0 'stale checkout blocks even identity calls'
pass 'Latest protected-main check rejects stale runs'
printf '✅ Passed %s lifecycle tests. All AWS operations were stubbed.\n' "$TESTS"