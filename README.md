# One Mail Templates

## Contents

- [What is this repo?](#what-is-this-repo)
- [Managed templates](#managed-templates)
- [What is a template?](#what-is-a-template)
- [Prerequisites](#prerequisites)
- [How to add a template](#how-to-add-a-template)
  - [Example](#example)
  - [Naming rules](#naming-rules)
- [Check your changes locally](#check-your-changes-locally)
- [Update an existing template](#update-an-existing-template)
- [Remove an existing template or version](#remove-an-existing-template-or-version)
- [Prepare a PR with Copilot](#prepare-a-pr-with-copilot)
- [Workflow guides](#workflow-guides)

## What is this repo?

Central repository for email templates used by [OneMail](https://github.com/pagopa/onemail), PagoPA's email delivery building block.

Product teams submit templates through pull requests. Validation checks their format and HTML; after merge, a pipeline publishes them directly to AWS SES and records their metadata in DynamoDB.

## Managed templates

See [the managed templates list](docs/templates-tree.md) for clients and template identifiers currently managed by this repository. 

After adding, removing or renaming templates, refresh the list with `bash scripts/generate-template-tree.sh`. To keep the template catalog automatically up to date, enable the repository’s pre-commit:


```bash
git config core.hooksPath .githooks
```

## What is a template

A template contains an email's subject, HTML body, and optional plain-text alternative. Handlebars placeholders such as `{{name}}` let callers personalize the message without sending the whole HTML each time. Clients use the template's `TemplateName` as their OneMail `templateId` and supply the values through the OneMail API.

This repository owns versioned template files, the [onemail repository](https://github.com/pagopa/onemail) owns infrastructure.

## Prerequisites

- Git
- Bash
- jq

After cloning the repository, run this command from the repository root to enable the pre-commit hook (once per clone):

```bash
git config core.hooksPath .githooks
```

## How to add a template?

> [!IMPORTANT]
> Each PR may include template changes for **one client only**. 

You need to:

1. Ensure the repository’s pre-commit hook is enabled in order to keep templates tree file update (see [Prerequisites](#prerequisites)).
2. Create a branch from an up-to-date `main`.
3. Add the file under `templates/<product>/<logical-name>/<version>/template.json`.
4. Set `TemplateName` to `<product>_<logical-name>_<version>` and add your email content.
5. Run the local checks below and open a PR. Resolve validation errors before merging.
6. Wait for approval from the BB team (the repository owners), then merge the PR.
7. After merge, check the **Sync templates** workflow for the result (a merged PR alone does not prove the upload succeeded).

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

| Part         | Rule                                                                        | Example                  |
| ------------ | --------------------------------------------------------------------------- | ------------------------ |
| Product      | Lowercase letters/numbers, separated by single hyphens; start with a letter | `ced`, `building-blocks` |
| Logical name | Lowercase letters/numbers, separated by single hyphens; start with a letter | `login`, `welcome-email` |
| Version      | `v` followed by a positive integer, without leading zeros                   | `v1`, `v12`              |
| Filename     | Always exactly `template.json`                                              | Not `welcome.json`       |
| TemplateName | Matches the path                                                            | `ced_welcome-email_v1`   |

## Check Your Changes Locally

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

For templates used in production, avoid changing the content of a version that product code already uses: callers of `ced_welcome-email_v1` would immediately receive the new content and could behave unexpectedly. Instead, you should add and publish a new version `v2`, migrate the product code to use `ced_welcome-email_v2`, then delete `v1` only after confirming no production callers still need it. A template update replaces the existing SES content.

## Remove an existing template or version

To retire a template, delete its exact file in a PR, for example `templates/ced/welcome-email/v1/template.json`.

After the deletion is merged, the synchronization workflow removes the SES template.

Coordinate deletion with consumers before merging: removing the SES template can affect clients that still reference its identifier.

## Prepare a PR with Copilot

The [`onemail-template-pr`](.github/agents/onemail-template-pr.agent.md) Copilot agent prepares the files for a template PR (in Italian or English), for example: _"partendo da questo repo con i template preparami una PR verso onemail-template"_. It creates or updates the template files with the repository scripts, validates them, refreshes the [managed templates](#managed-templates) tree, and drafts the PR description. It never commits or pushes.

## Workflow Guides

- [PR validation](docs/extending/pr-validation.md): what the PR checks and validate.
- [Publish and synchronize](docs/extending/publish-and-synchronize.md): how template changes are synchronized to the infrastructure, including deletions.
