# Template Contract

## Ownership And Layout

`onemail-template` owns reviewed source assets, retained retirement requests, validation, and direct SES publication. `onemail` owns the production sanitizer, global registry infrastructure, IAM, and runtime lookup. The uploader now lives in `scripts/upload-ses-templates.sh`; existing CODEOWNERS is unchanged.

Assets belong at `templates/<product>/<logical-template>/vN/template.json`, not `src/templates/`. Product and logical-template segments match `[a-z][a-z0-9]*(-[a-z0-9]+)*`. Versions are positive integers without leading zeros. The filename is exactly `template.json`. Files and their asset-directory ancestors must not be symlinks; path escapes are rejected before JSON parsing.

The SES name is `<product>_<logical-template>_vN`, with a maximum of 64 characters. For example, the **test-only** path `templates/fixture/welcome/v1/template.json` maps to `fixture_welcome_v1`. No production sample has been approved or added. Templates are created only by products through reviewed PRs.

## JSON Schema

Each file contains one object with exactly `TemplateName` and `TemplateContent`. `TemplateName` must equal the path-derived name. `TemplateContent` contains string `Subject` and `Html`, and optionally string `Text`; additional fields are rejected. Providing a plain-text alternative is recommended, not required.

Fixture example, not approved email copy:

```json
{
  "TemplateName": "fixture_welcome_v1",
  "TemplateContent": {
    "Subject": "Test fixture",
    "Html": "<p>{{name}}</p>"
  }
}
```

The SHA-pinned reusable `onemail` workflow validates supported Handlebars syntax and HTML with the production sanitizer. It must fail meaningful sanitization changes without rewriting source or creating diagnostic assets. The lightweight Bash/jq validator does not implement a second HTML sanitizer or Handlebars parser.

Names must be unique in an explicit asset set. Strict path/name matching makes names unique across canonical paths. JSON schema validation is not required-placeholder inference: placeholder lists, ASTs, and placeholder schemas are deferred and never stored in the registry.

## Immutable Versions

Retain existing version files unchanged, including formatting, and add a new version for corrections. Base-commit validation rejects edits, deletions, and renames of existing assets or retirement requests. Use the PR base commit, not just the last parent. Changed asset paths are gated before any changed content is read; unrelated JSON is ignored.

SES publication compares canonical `TemplateContent` using sorted JSON keys. An existing identical version is verified and reused; conflicting content fails, including pre-existing manual templates. The uploader never calls `UpdateEmailTemplate` and never adds a name prefix. Invoke it with explicit `--no-prefix`.

## Tenant And Registry Contract

Environments map as `dev=d`, `uat=u`, and `prod=p`. The tenant is `oml-<d/u/p>-tenant-<product>`, with no arbitrary mapping supplied by template authors. Verify the configured account with STS and tenant accessibility in **both** `eu-south-1` and `eu-central-1` before publication. Both regional tenant/IAM prerequisites must be provisioned separately; global-table replication does not create SES tenants.

After both SES regions have verified the template and association, the sole writer in `eu-south-1` writes:

| Attribute          | DynamoDB Type         | Meaning                                                 |
| ------------------ | --------------------- | ------------------------------------------------------- |
| `TemplateName`     | String, partition key | Unmodified public template identifier and SES name      |
| `tenantName`       | String                | Derived owning tenant                                   |
| `lastModifiedDate` | String                | Successful publication time, UTC `YYYY-MM-DDTHH:mm:ssZ` |

There is no sort key, lifecycle state, digest, durable manifest, AST, placeholder data, release, or cache. Initial writes require an absent partition key. A complete same-tenant rerun preserves the existing timestamp. Foreign ownership or unexpected registry schema is a conflict, not an overwrite.

## Retained Retirement Requests

A reviewed request is `retirements/<product>/<logical-template>-vN.json`, containing exactly:

```json
{ "TemplateName": "fixture_welcome_v1" }
```

The field is consistently named `TemplateName`, including tests and AWS calls. Retain requests permanently and keep historical assets. File deletion never authorizes AWS deletion. A retained request immediately excludes that name from subsequent publication; physical deletion requires a separately authorized manual retirement operation after merge.

Retirement is environment-specific when executed, but the retained request guards publication in every environment. Coordinate all target environments before merging the request. No per-environment lifecycle flags or promotion manifests are introduced.
