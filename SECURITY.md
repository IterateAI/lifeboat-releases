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

Linux builds carry a detached GPG signature and a `SHA256SUMS` file on each
release:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gpg --verify lifeboat-desktop_2.2.40_amd64.deb.asc
```

The signing key fingerprint is published on each release page.

## What the product sends

See [docs/telemetry.md](docs/telemetry.md). No model names, prompts,
completions or token counts are ever collected, and an air-gapped licence
contacts nothing.
