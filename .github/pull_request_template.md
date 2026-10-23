<!-- Identify the client, affected templates and versions, operation, and purpose of this PR. -->

## Changes

- Client: `<client>`
- Templates path:
    - `templates/<client>/<template>/<version>/template.json`
- Operation:
  - [ ] ➕ Add
  - [ ] 📝 Update
  - [ ] 🗑️ Delete
- Summary:

<!-- Confirm each applicable item before requesting review; mark non-applicable items as N/A. -->

## Checklist

- [ ] Template files follow `templates/<client>/<template>/vN/template.json`;
- [ ] Client and template folders use lowercase kebab-case; versions are `v1`, `v2`, etc., without leading zeros;
- [ ] `TemplateName` property inside the JSON matches `<client>_<template>_<version>`, e.g. `checkout_welcome_v1`;
- [ ] JSON contains only `TemplateName` and `TemplateContent`; content contains only `Subject`, `Html`, and optional `Text`.

<!-- Review the template guidelines before submitting this PR. -->

## Reference

[Template Email guidelines](https://pagopa.atlassian.net/wiki/spaces/Technology/pages/2672263432/Template+Email)