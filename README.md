# onemail-template

Central repository for email templates used by [OneMail](https://github.com/pagopa/onemail), PagoPA's email delivery building block.

Product teams submit templates through pull requests. Validation checks their format and HTML; after merge, a GitHub Actions workflow publishes them directly to AWS SES and records their owning tenant in DynamoDB. Publication requires the platform configuration described below.

## What Is A Template?

A template contains an email's subject, HTML body, and optional plain-text alternative. Handlebars placeholders such as `{{name}}` let callers personalize the message without sending the whole HTML each time. Clients use the template's `TemplateName` as their OneMail `templateId` and supply the values through the OneMail API.

This repository owns template files, retirement requests, and publication scripts. The [onemail repository](https://github.com/pagopa/onemail) owns the production HTML sanitizer, AWS infrastructure, IAM policies, and runtime template lookup.

## Add A Template

1. Create a branch from an up-to-date `main`.
2. Add the file under `templates/<product>/<logical-template>/vN/template.json`.
3. Set `TemplateName` to `<product>_<logical-template>_vN` and add your email content.
4. Run the local checks below and open a PR. Resolve validation errors before merging.
5. After merge, check the **Publish templates** workflow for the result. A merged PR alone does not prove the upload succeeded.

For example, `templates/ced/welcome-email/v1/template.json` must contain `"TemplateName": "ced_welcome-email_v1"`. The following content is illustrative, not an approved product email:

```json
{
  "TemplateName": "ced_welcome-email_v1",
  "TemplateContent": {
    "Subject": "Welcome, {{name}}",
    "Html": "<p>Hello {{name}}, welcome to our service.</p>",
    "Text": "Hello {{name}}, welcome to our service."
  }
}
```

The file contains exactly `TemplateName` and `TemplateContent`. `Subject` and `Html` are required strings; `Text` is optional but recommended for accessibility and compatibility. Additional JSON fields are rejected.

### Naming Rules

| Part                         | Rule                                                                        | Example                |
| ---------------------------- | --------------------------------------------------------------------------- | ---------------------- |
| Product and logical template | Lowercase letters/numbers, separated by single hyphens; start with a letter | `ced`, `welcome-email` |
| Version directory            | `v` followed by a positive integer, without leading zeros                   | `v1`, `v12`            |
| Filename                     | Always exactly `template.json`                                              | Not `welcome.json`     |
| TemplateName                 | Matches the path; at most 64 characters                                     | `ced_welcome-email_v1` |

Do not use symlinks, uppercase names, spaces, or path escapes. The PR checks filenames and paths **before reading template content** and reports the expected format if they are invalid.

The product folder also determines the SES tenant. For `templates/ced/...`, the tenant is `oml-d-tenant-ced` in dev, `oml-u-tenant-ced` in UAT, and `oml-p-tenant-ced` in production. Those tenants must already exist; adding a folder does not provision AWS resources. CODEOWNERS remains the source of repository ownership and review requirements.

## Check Your Changes Locally

Requirements: Bash, Git, and jq. Run from the repository root, with an up-to-date `origin/main` reference:

```bash
# Validate changed assets, including their names and version immutability.
bash scripts/validate-templates.sh --input-dir . --base-ref origin/main

# Validate assets and retirement requests without any AWS calls.
bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix --dry-run
```

To check one file, use `--file templates/ced/welcome-email/v1/template.json`; add `--paths-only` to the validator for a filename/path-only check. To validate all current assets rather than only changes, omit `--base-ref`.

Local checks validate JSON, naming, paths, and immutability. They do **not** prove AWS readiness or replace the PR's HTML sanitization and Handlebars syntax checks. No Node.js setup is needed for these local Bash commands.

## What Happens In A PR?

The **Template validation** check runs path/schema/immutability checks and calls a SHA-pinned workflow in `onemail` to check supported Handlebars syntax and HTML with the real production sanitizer.

Meaningful sanitization changes fail the PR: fix the source HTML and rerun the checks. The workflow never silently rewrites your template, saves original/sanitized HTML copies, or publishes to AWS. PR jobs receive no AWS credentials. Required values and placeholder types are not inferred or checked at runtime by this feature.

The sanitizer supports developer and CI modes; both produce console output only. CI exits with an error when sanitization changes the HTML. The Bash dry-run is not a substitute for that check.

## Publish And Verify

Protected `main` pushes affecting assets or publication tooling trigger **Publish templates** in the environment selected by the repository's `PUBLISH_ENVIRONMENT` variable. Maintainers can also use **Actions > Publish templates > Run workflow**, select `main`, choose an environment, and set `operation` to `publish`. There is no separate release or promotion workflow.

For every active version, the script:

1. Verifies the configured AWS account, derived tenant, and existing registry ownership.
2. Creates or verifies identical SES content and its tenant association in **both `eu-south-1` and `eu-central-1`**.
3. Only after both regions succeed, writes metadata through DynamoDB in `eu-south-1`.

The registry is a global table replicated to `eu-central-1`. Each item contains only `TemplateName` (partition key), `tenantName`, and `lastModifiedDate` (UTC timestamp). Replication is not instantaneous; SES and DynamoDB are not a single transaction. OneMail's existence/tenant check must be enabled separately after initial alignment. There is no placeholder registry, runtime cache, or lifecycle-status field.

### Update An Existing Template

**Versions are immutable.** Add `v2`, `v3`, and so on, then update callers to use the new `templateId`. Keep older files unchanged, including formatting; edits, deletion, and renaming of existing assets or retirement requests fail validation.

An identical SES version is reused on a rerun; different content under an existing name fails instead of being overwritten. The uploader never calls `UpdateEmailTemplate` or adds a prefix: `--no-prefix` is required.

### If Publication Fails

Inspect the workflow logs for the template, operation, and region. Transient throttling, service failures, and timeouts receive bounded retries (three attempts by default); permissions, invalid configuration, and content/ownership conflicts require intervention.

A partial failure can leave a template in SES without metadata. Fix the cause and rerun **latest main**: existing identical content is verified and missing operations resume forward. No automatic rollback deletes resources. A complete same-tenant rerun preserves the metadata timestamp. Contact the platform team for tenant, account, registry-schema, or IAM conflicts.

## Retire A Version

Deleting a template file does not authorize AWS deletion. Instead, open a PR adding `retirements/<product>/<logical-template>-vN.json`, for example `retirements/ced/welcome-email-v1.json`:

```json
{ "TemplateName": "ced_welcome-email_v1" }
```

Coordinate all environments before merging: a retained request excludes that version from future publication **in every environment**, although physical deletion is performed per environment. Keep the request and historical template file permanently.

After merge, an authorized maintainer runs **Publish templates** manually on `main`, selects `operation: retire`, supplies the exact `retirement_request` path, and explicitly accepts `authorize_retirement`. Merging the request alone does not delete cloud resources.

The script checks for foreign tenant associations, removes the approved association/template in both regions, verifies absence, and then deletes the DynamoDB item. Partial deletion can be resumed. Shared resources and unknown/incomplete listing responses fail closed.

**Retirement can break remaining callers and already queued emails.** Drain timing and new-submission sequencing remain unresolved; no automatic grace period or immediate blocking flag is provided. Agree the impact before authorizing deletion. Retained requests and latest-main checks prevent stale runs from recreating retired versions.

## Maintainer Setup

Before enabling publication or requiring the PR check:

- Publish the pinned `onemail` implementation commit and enable cross-repository reusable-workflow access. Keep `uses` and `tooling_ref` pinned to the same reviewed SHA; confirm checkout access if repositories are private.
- Merge trusted validator scripts before product asset PRs: PR validation runs the script from the PR base, never candidate scripts.
- Protect `main`, require **Template validation**, and restrict deployment environments to `main` with suitable approvals.
- Set repository variable `PUBLISH_ENVIRONMENT` to `dev`, `uat`, or `prod`.
- Configure protected environments `dev`, `uat`, and `prod`, each with `ACCOUNT_ID`, `REGISTRY_TABLE`, and `AWS_ROLE_ARN` variables.
- Provision environment-scoped OIDC/IAM access, the global registry, and SES tenants in **both regions**, including dev/UAT. Use short-lived credentials, not static AWS keys.
- Align existing manual templates and tenant associations with developers/cloud engineers before enabling strict OneMail lookup. Test the real publish/send/rerun/retire flow; local stubs do not prove live cloud readiness.

Publication uses the already checked-out source, which must be clean and equal to latest protected `origin/main`. The script fetches and rechecks before mutations; private remotes need read access. Publishing a stale commit is rejected. Jobs targeting the same environment are serialized without cancelling in-progress operations.

For an explicitly authorized manual upload from such a checkout, with the correct credentials and environment variables already configured:

```bash
bash scripts/upload-ses-templates.sh --input-dir . --env dev --no-prefix \
  --account-id "$ACCOUNT_ID" --table-name "$REGISTRY_TABLE" \
  --approved-ref "$(git rev-parse HEAD)"
```

Mutation requires AWS CLI v2 with SES tenant API support. Use `--help` for retry, profile, and retirement options. The old URL-clone, prefix, single-region, recursive, and skip-invalid options are no longer supported: check out approved source and use the current contract.

## Repository Checks

```bash
bash -n scripts/validate-templates.sh scripts/upload-ses-templates.sh
bash scripts/tests/template-lifecycle.test.sh
```

The lifecycle suite uses isolated temporary Git repositories and stub AWS responses; it does not access AWS or modify this repository's Git history. Run ShellCheck and actionlint when available. Workflows live in [.github/workflows](.github/workflows); executable tooling and tests live in [scripts](scripts).
