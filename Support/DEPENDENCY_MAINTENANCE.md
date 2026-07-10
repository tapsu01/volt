# Dependency maintenance

Volt bundles libssh2 and OpenSSL. Before every release and at least monthly:

1. Run `Scripts/audit-dependencies.sh`.
2. Review the official libssh2 and OpenSSL security advisories.
3. Upgrade patched dependencies and run `Scripts/test-security.sh`.
4. Rebuild with `Scripts/package-app.sh`.
5. Verify `DependencyManifest.json` hashes match the signed dylibs in the app.

For reproducible distribution builds, use source archives pinned by version and SHA-256 instead of mutable package-manager state. Pin and verify the complete downstream security patch set as well as the upstream archive: Homebrew formula revisions can contain CVE backports not present in the upstream release tarball. Keep source/patch hashes separate from signed binary hashes.
