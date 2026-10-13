# Template Operations

## Activation Prerequisites

1. Merge trusted lifecycle scripts before asset PRs: PR validation executes the validator from the PR base commit, never candidate scripts.
2. The caller pins both workflow and tooling to the reviewed `onemail` implementation commit `03fae304d9ceeda80f0271426a29de41b563e249`. Publish that commit before enabling remote validation; a local-only commit cannot be resolved by GitHub. Keep both references identical when updating tooling. Inputs are `source_ref`, `base_ref`, and matching `tooling_ref`.
3. Configure reusable-workflow access for `pagopa/onemail` and `pagopa/onemail-template`; confirm private-repository checkout permissions if applicable.
4. Protect `main` with reviews and the `Template validation` check. Configure repository variable `PUBLISH_ENVIRONMENT` as `dev`, `uat`, or `prod` for automatic main publication.
5. Create protected repository environments `dev`, `uat`, and `prod`. Each supplies variables `ACCOUNT_ID`, `REGISTRY_TABLE`, and `AWS_ROLE_ARN`. Use target-specific values and production approval protection. Restrict deployment branches to `main`.
6. Cloud engineers provision both-region SES tenants/permissions, the minimal replicated registry, and environment-scoped OIDC trust. Restrict the role to this repository's environment subject, expected account, managed template ARNs, permitted tenants, and the registry. No static keys or Lambda invocation rights.
7. Developers/cloud engineers reconcile pre-existing manual templates and foreign associations before activation. No automatic backfill or inventory service is supplied. Enable strict runtime lookup only after alignment and live validation of the runtime implementation.

Do not enable publication until both `eu-south-1` and `eu-central-1` exist for the selected environment. Dev/UAT secondary SES resources and permissions remain external prerequisites. Runtime cache, placeholder validation, and registry-outage/replica-lag handling are owned by `onemail`, not delivered by these scripts. Runtime must distinguish missing/foreign metadata from a database outage.

## Local Validation

Requirements: Bash, Git, jq. Mutation additionally requires a recent AWS CLI v2 supporting SES tenant APIs and credentials for the configured account. Scripts can be invoked through Bash without executable permissions.

```bash
bash scripts/validate-templates.sh --input-dir . --base-ref origin/main
bash scripts/validate-templates.sh --input-dir . --file templates/fixture/welcome/v1/template.json --paths-only
bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix --dry-run
bash scripts/tests/template-lifecycle.test.sh
```

`--input-dir` is the explicit repository root containing `templates/` and `retirements/`. Repeat `--file` to select exact repository-relative assets. With `--base-ref`, the standalone validator selects **only changed asset paths**, including deleted/renamed paths, using NUL-delimited Git output. Without it, it validates the asset trees only. All selected paths are checked before any JSON is parsed. Dry-run validates source and retained requests without STS, SES, or DynamoDB calls; it cannot prove cloud readiness or replace PR sanitization.

The uploader preserves optional `--profile` and validates legacy `--tenant` against derived identity. Old URL-clone, prefix, single-region, recursive, and skip-invalid modes deliberately fail with migration guidance: clone/fetch separately, select an approved checkout, and use this contract. No moving-branch clone runs in CI. There were no repository workflow callers of the old script.

## Publication And Recovery

Protected-main pushes publish active versions in the environment selected by `PUBLISH_ENVIRONMENT`. Manual dispatch selects a configured environment directly, without release artifacts or a separate promotion workflow. Publication validates all assets/retirement guards, then excludes retired names. The script requires clean approved source and a full SHA equal to latest protected `origin/main`; it fetches/rechecks before every AWS mutation attempt. A stale or locally modified checkout fails closed. Private remotes require read-only Git authentication for these fetches.

Example for an authorized latest-main checkout:

```bash
bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix \
  --account-id 123456789012 --table-name CONFIGURED_REGISTRY \
  --approved-ref "$(git rev-parse HEAD)"
```

For each name: verify registry ownership, create or canonically compare SES content, verify exclusive/expected tenant association in both regions, then write minimal metadata in `eu-south-1`. `AlreadyExistsException` is inspected, not overwritten. A conditional absent-key write protects competing registry ownership; same-tenant completed records retain their timestamp. Metadata never precedes regional success.

All AWS calls use JSON output, disabled prompts, 10-second connect and 30-second read timeouts. The script disables nested SDK retries and defaults to three attempts with two-second linear backoff. Throttling, service/internal errors, and connection/request timeouts retry; access denial, invalid arguments, ownership conflicts, and other terminal errors do not. `--max-attempts` is capped at five, `--retry-delay` at 30 seconds, and backoff has a fixed ceiling. SES calls are rate-limited conservatively by a default 1.1-second wait; `--rate-delay` supports 0..5 seconds for controlled tests/tuning. Never disable production rate limiting without an operational reason.

Failure exits nonzero with operation, region, and template context. Partial SES resources remain for a forward rerun; no compensation deletes them. Re-run publication against **latest** main, not an old workflow revision. Both workflows grant no PR AWS role; publication uses OIDC and environment-level serialization with `cancel-in-progress: false`.

## Explicit Retirement

Merge the retained request through review. Then manually dispatch `Publish templates`, choose the target environment and `retire`, provide the exact request path, and explicitly accept `authorize_retirement`. This acknowledgment is mandatory because queued-send/drain timing and submission sequencing are unresolved; no automatic drain period is assumed.

Equivalent authorized local operation:

```bash
bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix \
  --account-id 123456789012 --table-name CONFIGURED_REGISTRY \
  --approved-ref "$(git rev-parse HEAD)" \
  --retire --file retirements/fixture/welcome-v1.json \
  --retirement-authorization queued-send-risk-accepted
```

The owning tenant is derived from the request path. In each region, inspect the template and all resource tenants before deleting associations. Foreign tenants or incomplete/unknown listing responses stop the operation. Remove the approved association, verify no associations remain, delete the template, and verify absence. AWS CLI auto-pagination is retained; no `--max-items` or `--no-paginate` truncation is permitted. Already-absent resources are resumable, but permission/service errors are never treated as absence.

Only after both regions complete, delete metadata through the single primary writer with an absent-or-same-tenant condition. If interrupted in the second region, metadata remains and a rerun resumes the retained request. The request permanently prevents stale recreation: every mutation attempt checks latest main and clean source. A push containing retirement requests **does not** delete cloud resources automatically.

SES checks and deletion are not transactional with external writers. Limit resource modification to this serialized workflow; foreign tools can race association checks. Registry presence is not proof of immediate global replication. New calls may still pass while deletion is incomplete, and queued emails can fail after removal. Verify missing-template behavior with the sender maintainers. No status flag, tombstone, drain, cache, or rollback can be inferred from this implementation.

AWS references: [ListResourceTenants](https://docs.aws.amazon.com/cli/latest/reference/sesv2/list-resource-tenants.html), [ListTenantResources](https://docs.aws.amazon.com/cli/latest/reference/sesv2/list-tenant-resources.html), [DeleteTenantResourceAssociation](https://docs.aws.amazon.com/cli/latest/reference/sesv2/delete-tenant-resource-association.html).

## Verification And Rollout

Run `bash -n` for changed scripts, the stub-AWS suite, ShellCheck and actionlint when available, and workflow YAML parsing. The fixture suite creates isolated temporary Git repositories only; it never stages, commits, or changes branches in either working repository. It covers path-before-parser guards, no-AWS dry-run, immutable reruns/conflicts, bounded retries, both-region metadata gating, identity/ownership failures, interrupted retirement, shared tenants, pagination refusal, and stale runs.

Live integration is an external activation gate, not proven by stubs: publish in authorized dev in both regions, inspect the minimal registry item, send through the runtime, rerun unchanged, inject a recoverable failure, execute reviewed retirement, and verify missing-template rejection. Resolve cloud prerequisites, sanitizer pins/access, branch protection, and environment approvals first. No dependencies are installed for the template repository.
