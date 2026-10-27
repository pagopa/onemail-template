# One Mail Templates

## Summary

This repository stores versioned OneMail email templates, validates pull requests, and synchronizes approved changes to AWS SES.

## Contents

- [What is this repo?](#what-is-this-repo)
- [What is a template?](#what-is-a-template)
- [How to add a template](#how-to-add-a-template)
  - [Example](#example)
  - [Naming rules](#naming-rules)
- [Check your changes locally](#check-your-changes-locally)
- [Update an existing template](#update-an-existing-template)
- [Remove an existing template or version](#remove-an-existing-template-or-version)
- [Workflow guides](#workflow-guides)

## What is this repo?

Central repository for email templates used by [OneMail](https://github.com/pagopa/onemail), PagoPA's email delivery building block.

Product teams submit templates through pull requests. Validation checks their format and HTML; after merge, a GitHub Actions workflow publishes them directly to AWS SES and records their owning tenant in DynamoDB. Publication requires the platform configuration described below.

## What is a template

A template contains an email's subject, HTML body, and optional plain-text alternative. Handlebars placeholders such as `{{name}}` let callers personalize the message without sending the whole HTML each time. Clients use the template's `TemplateName` as their OneMail `templateId` and supply the values through the OneMail API.

This repository owns versioned template files and the synchronization scripts. The [onemail repository](https://github.com/pagopa/onemail) owns the HTML sanitizer, infrastructure, and runtime template lookup.

## How to add a template?

1. Create a branch from an up-to-date `main`.
2. Add the file under `templates/<product>/<logical-name>/<version>/template.json`.
3. Set `TemplateName` to `<product>_<logical-name>_<version>` and add your email content.
4. Run the local checks below and open a PR. Resolve validation errors before merging.
5. Wait for approval from the BB team (the repository owners), then merge the PR.
6. After merge, check the **Sync templates** workflow for the result (a merged PR alone does not prove the upload succeeded).

To generate the initial JSON structure, you can run from the repository root:

```bash
# Create templates/ced/welcome-email/v1/template.json (v1 is the default).
bash scripts/create-template.sh ced welcome-email

# Create a separate version.
bash scripts/create-template.sh ced welcome-email v2
```

Pass the client folder name, the logical template name and the optional version (default is v1).

Only `TemplateName` is populated; `Subject`, `Html`, and `Text` are empty strings to fill in.

### Example 

For example, `templates/ced/welcome-email/v1/template.json`:

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

> [!NOTE]
> The `TemplateName` in this JSON must match the template path; for this example, use `ced_welcome-email_v1`.

### Naming Rules

| Part                         | Rule                                                                        | Example                |
| ---------------------------- | --------------------------------------------------------------------------- | ---------------------- |
| Product | Lowercase letters/numbers, separated by single hyphens; start with a letter | `ced`, `building-blocks` |
 Logical name | Lowercase letters/numbers, separated by single hyphens; start with a letter | `login`, `welcome-email` |
| Version            | `v` followed by a positive integer, without leading zeros                   | `v1`, `v12`            |
| Filename                     | Always exactly `template.json`                                              | Not `welcome.json`     |
| TemplateName                 | Matches the path                         | `ced_welcome-email_v1` |

The PR checks filenames and paths **before reading template content** and fails if they are invalid.

The product folder also determines the SES tenant. For `templates/ced/...`, the tenant is `oml-d-tenant-ced` in dev, `oml-u-tenant-ced` in UAT, and `oml-p-tenant-ced` in production. Those tenants must already exist; adding a folder does not provision AWS resources. CODEOWNERS remains the source of repository ownership and review requirements.

## Check Your Changes Locally

Requirements:
- bash
- jq
- curl
- network access (for the HTML check).

Run from the repository root and pass the files you want to check explicitly:

```bash
# Validate names, paths, and JSON fields for one or more files.
bash scripts/validate-templates.sh templates/ced/welcome-email/v1/template.json

# Check only the HTML content through the UAT template sanitizer.
SANITIZER_URL=https://uat.onemail.pagopa.it/v1/emails/sanitize-template \
  bash scripts/sanitize-templates.sh templates/ced/welcome-email/v1/template.json
```

## Update an existing template

For templates used only in UAT (or lower environments), you can update the existing version (for example, `templates/ced/welcome-email/v1/template.json`) to test revised content using the same template identifier.

For templates also used in production, avoid changing the content of a version that product code already uses: callers of `ced_welcome-email_v1` would immediately receive the new content and could behave unexpectedly. Instead, you should add and publish a new version `v2`, migrate the product code to use `ced_welcome-email_v2`, then delete `v1` only after confirming no production callers still need it. A template update replaces the existing SES content.

## Remove an existing template or version

To retire a template, delete its exact file in a PR, for example `templates/ced/welcome-email/v1/template.json`.

After the deletion is merged, the synchronization workflow removes the SES template.

Coordinate deletion with consumers before merging: removing the SES template can affect clients that still reference its identifier.

## Workflow Guides

- [PR validation](docs/extending/pr-validation.md): what the PR checks and validate.
- [Publish and synchronize](docs/extending/publish-and-synchronize.md): how template changes are synchronized to the infrastructure, including deletions.
