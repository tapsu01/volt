# Security Policy

Volt handles SFTP credentials, SSH host keys, and local file writes, so security
reports are welcome and appreciated.

## Self-Build Safety

For personal use with important servers, build from a clean working tree and run:

```bash
./Scripts/verify-self-build.sh
```

This verifies the security-focused C tests, dependency freshness, app signing,
bundled dylib hashes, and runtime library paths. Ad-hoc signed builds are for
self-use on the build Mac only; use Developer ID signing and notarization before
distributing Volt to anyone else.

Volt is a high-trust local file manager and is not fully App Sandbox hardened in
this phase. Verify SSH host-key fingerprints out of band and keep server backups
or snapshots before destructive remote operations.

## Reporting a Vulnerability

Please avoid opening a public issue for a suspected vulnerability. If GitHub
private vulnerability reporting is enabled for this repository, use that flow.
Otherwise, contact the maintainer through their GitHub profile and include:

- A short description of the issue.
- Steps to reproduce.
- The affected commit or release.
- Any logs, screenshots, or proof-of-concept files that are safe to share.

The project maintainer will triage the report, prepare a fix when needed, and
publish an advisory or release note once users have a reasonable upgrade path.
