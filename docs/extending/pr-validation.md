# PR Validation

The **Validate templates** workflow runs for pull requests targeting `main`. It checks new and changed template assets.

## Which files are checked?

The workflow selects changed paths under `templates/**`. It takes added, copied, modified, and renamed paths. Deleted paths are not passed to the validator or HTML check.

The workflow uses templates data from the pull request, but uses the validation scripts from main branch. This prevents proposed pull request changes to the scripts from being used to validate that same pull request.

## Path and JSON validation

[`scripts/validate-templates.sh`](../../scripts/validate-templates.sh) checks each selected path and file:

- The path must match `templates/<client>/<template>/<version>/template.json`; client and template names must be lowercase kebab-case and the version must be a positive integer without leading zeroes.
- No path component may be a symbolic link, and the target must be a regular file.
- The JSON must contain exactly `TemplateName` and `TemplateContent`.
- `TemplateName` must match the client, template, and version derived from the path.
- `TemplateContent` must contain `Subject` and `Html` as non-empty strings, with an optional string `Text`. No additional content fields are accepted.

Next HTML check runs only if this validation job succeeds and there are selected template paths.

## HTML check

[`scripts/sanitize-templates.sh`](../../scripts/sanitize-templates.sh) reads `TemplateContent.Html`, encodes it as the a JSON request body and sends it to the URL provided by the One Mail for sanitization.

The script fails if the request does not succeed or if the response contains `isSanitized: true`, therefore the source template needs to be corrected.

