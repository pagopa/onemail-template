# onemail-template

Central repository for email templates used by [OneMail](https://github.com/pagopa/onemail), PagoPA's email delivery building block.

Product teams submit templates through pull requests. Validation checks their format and HTML; after merge, a GitHub Actions workflow publishes them directly to AWS SES and records their owning tenant in DynamoDB. Publication requires the platform configuration described below.

## What Is A Template?

A template contains an email's subject, HTML body, and optional plain-text alternative. Handlebars placeholders such as `{{name}}` let callers personalize the message without sending the whole HTML each time. Clients use the template's `TemplateName` as their OneMail `templateId` and supply the values through the OneMail API.

This repository owns versioned template files and publication scripts. The [onemail repository](https://github.com/pagopa/onemail) owns the production HTML sanitizer, AWS infrastructure, IAM policies, and runtime template lookup.

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

The file contains exactly `TemplateName` and `TemplateContent`. `Subject` and `Html` are required non-empty strings; `Text` is optional but recommended for accessibility and compatibility. Additional JSON fields are rejected.

### Naming Rules

| Part                         | Rule                                                                        | Example                |
| ---------------------------- | --------------------------------------------------------------------------- | ---------------------- |
| Product and logical template | Lowercase letters/numbers, separated by single hyphens; start with a letter | `ced`, `welcome-email` |
| Version directory            | `v` followed by a positive integer, without leading zeros                   | `v1`, `v12`            |
| Filename                     | Always exactly `template.json`                                              | Not `welcome.json`     |
| TemplateName                 | Matches the path; SES requires at most 64 characters                         | `ced_welcome-email_v1` |

Do not use symlinks, uppercase names, spaces, or path escapes. The PR checks filenames and paths **before reading template content** and reports the expected format if they are invalid.

The local validator does not enforce the SES name-length limit; keep the complete derived name within 64 characters.

The product folder also determines the SES tenant. For `templates/ced/...`, the tenant is `oml-d-tenant-ced` in dev, `oml-u-tenant-ced` in UAT, and `oml-p-tenant-ced` in production. Those tenants must already exist; adding a folder does not provision AWS resources. CODEOWNERS remains the source of repository ownership and review requirements.

## Check Your Changes Locally

Requirements: Bash and jq; curl and network access to UAT are also needed for the HTML check. Run from the repository root and pass the files you want to check explicitly:

```bash
# Validate names, paths, and JSON fields for one or more files.
bash scripts/validate-templates.sh templates/ced/welcome-email/v1/template.json

# Check only the HTML content through the UAT template sanitizer.
SANITIZER_URL=https://uat.onemail.pagopa.it/v1/emails/sanitize-template \
  bash scripts/sanitize-templates.sh templates/ced/welcome-email/v1/template.json
```

Both scripts accept multiple positional file paths. They do not discover changed files or scan the repository automatically; the PR workflow selects the files. Run the format validator before the HTML check.

No Node.js setup or AWS credentials are needed for these checks. Local validation does not prove AWS readiness. Publication uses `scripts/sync-ses-templates.sh` through GitHub Actions with OIDC; there is no dry-run mode.

## What Happens In A PR?

The **Validate templates** workflow selects added or changed assets under `templates/**`, validates their paths and JSON fields, then runs `scripts/sanitize-templates.sh` for the same file list. Deleted files are not read or sanitized. Validation scripts come from the PR base commit, not from the candidate branch.

For each selected file, the script sends `TemplateContent.Html` as `htmlContent` to `POST https://uat.onemail.pagopa.it/v1/emails/sanitize-template`. This unauthenticated route is exposed only in dev and UAT. It accepts 10 to 500000 characters, converts unescaped placeholders (`{{{...}}}` and `{{& ...}}`) to escaped `{{...}}` placeholders before applying OneMail's HTML sanitizer, and returns HTTP 200 with `isSanitized: true` when either operation changes the content. It does not perform complete Handlebars syntax validation or check `Subject` and `Text` content.

An HTTP error, invalid response, or `isSanitized: true` fails the check. Fix the source HTML and rerun; the workflow never rewrites templates, saves HTML copies, or publishes to AWS. It does not check out onemail code or install Node.js. PR jobs receive no AWS credentials. UAT availability is required for the HTML check.

The aggregate **Template validation** check succeeds only when path/contract validation succeeds and the HTML check either succeeds or is correctly skipped because there are no selected templates. Require this check in branch protection.

## Publish And Verify

Pushes to `main` affecting `templates/**` trigger **Sync templates**. The pinned environment-matrix action selects dev and UAT in `eu-south-1`, plus production in both `eu-south-1` and `eu-central-1`. There is no `PUBLISH_ENVIRONMENT` variable.

Maintainers can also use **Actions > Sync templates > Run workflow**, select `main`, and choose `dev`, `uat`, or `prod`. Manual runs use the same change selection: the selected commit is compared with its immediate parent. They do not publish every existing version. The workflow also uses this immediate-parent comparison for pushes, so a multi-commit push is not a full reconciliation.

For each added or changed template, every selected environment/region job independently:

1. Derives the SES template name and tenant from the asset path.
2. Creates the SES template, or updates it if it already exists, then ensures the tenant association in that job's region.
3. Writes the registry item through DynamoDB in `eu-south-1`, setting `status: ACTIVE` and refreshing `lastModifiedDate`. The conditional write allows only an absent item or the same owning tenant. This ownership condition is checked after the SES operations, not before them.

The table defaults to `TemplateRegistry` and can be overridden with `AWS_TEMPLATE_DB_TABLE`. Active items contain `TemplateName` (partition key), `tenantName`, `lastModifiedDate`, and `status: ACTIVE`. Retired items also contain `retiredAt`. Publication replaces the item, so reactivating it removes `retiredAt`.

The global registry is replicated to `eu-central-1`, but regional jobs do not wait for one another before writing metadata. A successful registry write does not prove that every region succeeded. SES and DynamoDB are not a single transaction. OneMail's runtime registry lookup must be configured separately.

### Update An Existing Template

The path and `TemplateName` identify the version selected by clients; they do not make its content immutable. A PR may change `templates/ced/welcome-email/v1/template.json`, and after merge the workflow updates `ced_welcome-email_v1` in the selected environments and regions. Clients that keep using `v1` receive the updated content; they do not get switched to a new identifier automatically.

Create `v2` when clients should be able to opt into a distinct version while other clients continue using `v1`. The script calls `UpdateEmailTemplate` whenever creation reports that the template already exists; it does not compare or read back the SES content. The SES name is derived from the asset path without additional prefixes.

### If Publication Fails

Inspect the workflow logs for the template, environment, and region. AWS CLI standard retries are configured with up to five attempts per call; permissions, invalid configuration, and ownership conflicts require intervention. Independent templates are still processed before the batch reports failure.

A partial failure can leave SES regions or DynamoDB out of sync. Fix the cause and rerun the failed workflow or jobs to retry the same selected changes. A new manual run on a later commit selects that commit's diff, not previously failed templates. Already-existing associations and already-absent deletion targets are tolerated. There is no automatic rollback or post-write verification. Contact the platform team for tenant, account, registry-schema, or IAM conflicts.

## Remove A Version

Open a PR that deletes the exact file, for example `templates/ced/welcome-email/v1/template.json`. Do not add a retirement marker or move the template elsewhere. Deleted files are not read or sanitized in the PR.

After merge to `main`, **Sync templates** selects deleted paths from the commit diff and invokes `scripts/sync-ses-templates.sh -e <environment-short-name> -d <paths>`. Each matrix job removes the tenant association and SES template in its region, then writes a retained DynamoDB item with `status: RETIRED` and `retiredAt`. It does not republish unchanged versions. There is no separate retirement operation or authorization input in the workflow.

Partial deletion can be retried by rerunning the failed workflow or jobs. The script tolerates already-absent associations and templates, but does not list associations or verify absence after deletion. No AWS deletion occurs in the PR job.

**Removal can break remaining callers and already queued emails.** No automatic grace period or queue-draining mechanism is provided. Coordinate the impact before merging the deletion PR. Restoring the historical file through a new PR causes it to be published again.

## Maintainer Setup

Before enabling publication or requiring the PR check:

- Deploy `/v1/emails/sanitize-template` to UAT, including its API Gateway integration, before enabling the HTML check. No cross-repository sanitizer checkout or reusable workflow is required.
- Merge trusted validator scripts before product asset PRs: PR validation runs the script from the PR base, never candidate scripts.
- Protect `main`, require **Template validation**, and restrict deployment environments to `main` with suitable approvals.
- Configure GitHub environments `dev`, `uat`, `prod/eu-south-1`, and `prod/eu-central-1`, with `AWS_ROLE_ARN` and optionally `AWS_TEMPLATE_DB_TABLE`. The AWS account ID comes from the configured credentials action, not an `ACCOUNT_ID` variable.
- Provision environment-scoped OIDC/IAM access, the global registry, and SES tenants in the matrix's regions. The publisher role needs SES template/tenant-association operations and conditional DynamoDB `PutItem` in `eu-south-1`. Use short-lived credentials, not static AWS keys.
- Align existing manual templates and tenant associations with developers/cloud engineers before enabling strict OneMail lookup. Test the real publish/send/rerun/retire flow; local stubs do not prove live cloud readiness.

Changing an existing Terraform-managed registry table from `Template` to `TemplateRegistry` replaces the physical table. If the old table contains records, migrate and verify them before applying the rename; the pipeline does not copy registry data between tables.

Publication jobs run only for `refs/heads/main`. The script does not fetch Git refs or reject a run whose commit has since become stale. Jobs targeting the same environment and region are serialized without cancelling in-progress operations; different matrix targets run independently.

Use **Actions > Sync templates** for publication and retirement with the configured environment and role. The synchronization script uses paths relative to the current checkout and expects AWS credentials, `AWS_REGION`, and `AWS_ACCOUNT_ID` from the workflow.

## Repository Checks

```bash
bash -n scripts/validate-templates.sh
bash -n scripts/sanitize-templates.sh
bash -n scripts/sync-ses-templates.sh
```

Run ShellCheck and actionlint when available. Workflows live in [.github/workflows](.github/workflows); executable tooling lives in [scripts](scripts).
