# Security Policy

## Supported versions

Security fixes are provided for the latest released version of Omakanvas.

| Release | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Do not publish vulnerability details in a GitHub issue. Until a private
reporting channel is listed here, open an issue titled `Security contact
request` containing only a request for the maintainer to arrange private
contact. Do not describe the vulnerability in that issue. If GitHub Private
Vulnerability Reporting becomes available for this repository, it may be used
instead.

Include enough information to reproduce and assess the issue, such as the
affected version, relevant configuration, expected behavior, observed
behavior, and reproducible steps. Never include a Canvas API token, password,
browser session cookie, or other credential in a report, screenshot, log, or
example.

Security concerns include, but are not limited to:

- Exposure of Canvas API tokens, browser sessions, or other sensitive data.
- Authenticated requests being sent somewhere other than the configured Canvas
  installation.
- Bypasses of Canvas base URL validation.
- Command, argument, or configuration injection.
- Insecure system-keyring handling.
- Sensitive information being written to logs or plain-text configuration.

Please use regular GitHub issues for feature requests, usability problems, and
bugs that do not have a security impact.

## Exposed credentials

If a Canvas API token may have been exposed, revoke it immediately in Canvas,
generate a replacement, and save the replacement with Omakanvas's `set-token`
command. Do not wait for a vulnerability report to be reviewed before rotating
a potentially compromised token.

If a harvested browser session may have been exposed, remove it with
`clear-session` and use the institution's session-management controls (or ask
its Canvas administrator) to invalidate active sessions before running `login`
again. Omakanvas stores tokens and browser sessions in separate desktop Secret
Service keyring entries and sends them only to the user-configured Canvas
installation. Browser login uses a private temporary Chromium profile, a
process-private debugging pipe, and retains only the validated Canvas session
value and API base URL.
Fetched course data, including grades, announcement/discussion bodies, and
latest conversation messages, is saved separately in
`$XDG_DATA_HOME/omakanvas/latest.json` (defaulting to
`~/.local/share/omakanvas/latest.json`). The directory uses mode `0700` and
the file uses `0600`; it contains no authentication credentials. Other programs
running as the same user can read this snapshot. It remains after plugin
removal until the user deletes the data directory.
Because Omarchy plugins run as unsandboxed user code, users should review plugin
source and updates before installing them.

## Disclosure

Please allow the maintainer a reasonable opportunity to investigate and
release a fix before publicly disclosing a vulnerability. Receipt of a report
will be acknowledged when possible, but no guaranteed response or remediation
timeline is offered.
