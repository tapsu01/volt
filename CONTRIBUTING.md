# Contributing to Volt

Thanks for taking the time to improve Volt. This project is a native macOS SFTP
file manager, so changes should keep the app focused, secure, and comfortable to
use in daily file-transfer workflows.

## Before You Start

- Open an issue first for large UI changes, protocol support, storage changes,
  or security-sensitive behavior.
- Keep pull requests focused. Smaller changes are easier to review and test.
- Do not include real server addresses, usernames, passwords, private keys,
  `known_hosts`, or saved connection files in issues, screenshots, tests, or
  commits.

## Development Setup

Install the native dependencies:

```bash
brew install libssh2 openssl@3
```

Build the app:

```bash
VOLT_LIBSSH2_PREFIX="$(brew --prefix libssh2)" swift build
```

Run Swift unit tests when using a full Xcode toolchain with XCTest available:

```bash
swift test
```

Run the security-focused C tests:

```bash
./Scripts/test-security.sh
```

Check bundled dependency freshness:

```bash
./Scripts/audit-dependencies.sh
```

## Pull Request Checklist

- The change matches Volt's current SwiftUI style and project structure.
- SFTP credentials and host-key handling remain private and explicit.
- Local file writes continue to guard against path traversal and unsafe remote
  names.
- UI changes work in both light and dark appearances.
- README, screenshots, or maintenance docs are updated when behavior changes.
- `swift build` passes.
- `./Scripts/test-security.sh` passes when the change touches transfers,
  filenames, SSH/SFTP, host-key storage, or local file writes.

## Security Reports

Please do not report suspected vulnerabilities in public issues. Use the process
in [`SECURITY.md`](SECURITY.md) instead.
