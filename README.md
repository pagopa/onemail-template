# onemail-template

Central repository for email templates used by [OneMail](https://github.com/pagopa/onemail), PagoPA's email delivery building block.

Templates use the AWS SES JSON format, with Handlebars placeholders for personalized content. Each template defines its name, subject and HTML body; a plain-text alternative is recommended for accessibility and compatibility.

The repository is intended to collect templates from product teams and track changes through pull requests. Automated validation and publishing to AWS SES are planned and will be documented as they are introduced.

This repository is at its initial setup stage. Template organization and contribution guidelines will follow.
