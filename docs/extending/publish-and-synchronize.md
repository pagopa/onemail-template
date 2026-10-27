# Publish and Verify

The **Sync templates** workflow applies template changes (new templates, modified templates and removed templates) to Amazon SES and writes template metadata to DynamoDB.

## When publishing runs

- A push to `main` branch that changes something under `templates/**` triggers the workflow.
- A maintainer can also start it manually from **Actions > Sync templates > Run workflow**, choosing the env.

The workflow detects `templates/**/template.json` changes, and added, copied, modified, and renamed template files are synchronized; deleted template files are retired.

## Tenant prerequisites

The product folder also determines the SES tenant. For `templates/ced/...`, the tenant is `oml-<env-short>-tenant-ced`.

## What the workflow does

For each added or updated template:

1. Get the SES template name (derived from the path).
2. Derives the tenant name from the client directory. For example, the `ced` client in `uat` uses `oml-u-tenant-ced`.
3. Creates the SES template, or updates it if SES reports that it already exists, then creates the tenant-resource association in the selected region.
4. Writes an `ACTIVE` item to DynamoDB. The item contains `TemplateName`, `tenantName`, `lastModifiedDate`, and `status`.

> Publication runs only if the tenant exists in the target environment and region. Otherwise, the template is skipped with a warning, without failing the job.

For each deleted template:

1. Removes the tenant-resource association and deletes the SES template in the selected region.
2. Keeps a record in DynamoDB with status `RETIRED` and a `retiredAt` timestamp.

## Verify a run

After a merge, inspect the run for the merge commit. Check each expected job and review the logs.

## If publication fails

The script uses a retry mode, with up to five attempts per call. It continues processing other paths after a template fails, then exits with a failure summary. Inspect the logs for the affected template.

After correcting the issue, rerun the failed workflow to retry.
