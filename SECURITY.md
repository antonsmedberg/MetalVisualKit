# Security policy

## Supported versions

MetalVisualKit has no tagged release yet. Security fixes are applied to the
latest `main` branch. Once releases exist, this policy will list supported
versions explicitly.

## Report a vulnerability

Please do not disclose a suspected vulnerability in a public issue, discussion or
pull request. Use GitHub's private
[Report a vulnerability](https://github.com/antonsmedberg/MetalVisualKit/security/advisories/new)
form instead.

Include, when possible:

- the affected commit or branch;
- the affected API, shader, workflow or build path;
- reproduction steps or a minimal sample;
- the security impact and prerequisites;
- any suggested mitigation;
- whether the report may be credited publicly after a fix.

Reports will be reviewed privately before any public issue or advisory is opened.
Please allow time to reproduce the problem and coordinate a fix. Do not include
real credentials, personal data or unrelated private material in a report.

## Scope

Security reports may include unsafe memory or resource handling, malicious input
that crosses a documented trust boundary, workflow or dependency compromise, and
privacy-manifest inconsistencies. Rendering defects, unsupported hardware and
feature requests should use the normal issue templates unless they create a
security or privacy impact.
