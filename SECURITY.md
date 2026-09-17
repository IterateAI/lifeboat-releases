# Security

## Reporting a vulnerability

Email **security@iterate.ai**. Please do not open a public issue.

Include what you found, how to reproduce it, and the version
(`lifeboat-core version`, or the console footer). We will acknowledge within
two working days.

## Verifying a download

macOS and Windows builds are code-signed by **Iterate Studio Inc**, so the
operating system verifies them for you. A build that Gatekeeper or SmartScreen
refuses did not come from us — do not bypass the warning, tell us instead.

Linux has no equivalent, so each release carries a `SHA256SUMS` file and you
should check it yourself:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Take `SHA256SUMS` from the release page over HTTPS, not from the same directory
you were sent the binary in. We do **not** currently publish detached GPG
signatures for the Linux builds — if you need one for a procurement or
air-gapped review, write to security@iterate.ai and say so.

## What the product sends

See [docs/telemetry.md](docs/telemetry.md). No model names, prompts,
completions or token counts are ever collected, and an air-gapped licence
contacts nothing.
