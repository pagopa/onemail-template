---
name: verify-onemail-tenant
description: Verify a client name against the OneMail tenant configuration and identify tenants without a template folder. Use before creating a template client, template, or version, or whenever a OneMail tenant name needs verification.
---

# Verify a OneMail tenant

## Source

The top-level keys of [`tenants.json`](https://github.com/pagopa/onemail/blob/main/src/infra/src/data/tenants/tenants.json) on OneMail's `main` branch are the configured tenant names. Fetch the raw file directly, without cloning a repository, calling an API, or accessing AWS:

```bash
curl --fail --silent --show-error --location --max-time 30 \
  https://raw.githubusercontent.com/pagopa/onemail/refs/heads/main/src/infra/src/data/tenants/tenants.json
```

Use the fresh response for the check; do not use a cached file, a local checkout, template folders, or a hard-coded tenant list as the source of truth.

## Procedure

1. Fetch the file and verify that the request succeeded and the response is a non-empty JSON object. If retrieval or parsing fails, report the error and return an inconclusive result; never treat failure as an absent or valid tenant.
2. Compare the requested client exactly and case-sensitively with the object's top-level keys. For a match, report the tenant name and, when `domain` is an object, its configured environment keys.
3. If there is no match and an `onemail-template` checkout is available, list the configured tenant keys without a corresponding `templates/<client>/` directory. If no such tenants exist, report that the list is empty. Do not infer or automatically substitute a tenant.
4. Report whether the client is **verified**, **absent**, or **inconclusive**. A configured tenant or environment does not prove that it has been deployed to AWS.

When this skill is used before creating templates, only a verified client may proceed. If the client is absent, ask the user whether an available tenant was intended and verify their explicit choice before proceeding. If the check is inconclusive, stop without creating files or directories.
