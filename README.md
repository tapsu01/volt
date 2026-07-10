# Volt

Volt is a native SFTP file manager for macOS, built with SwiftUI and libssh2.
It provides a dual-pane browser for working with local and remote files without
passing SFTP passwords through shell commands.

## Features

- Native SwiftUI interface for macOS
- Local and remote dual-pane file browser
- Password, SSH private key, and SSH agent authentication
- Upload and download with a visible transfer queue
- Create, rename, move, duplicate, and delete files and folders
- Remote editing with a selectable macOS application
- Multiple tabs that preserve their connection and current folders
- Context menus, selection highlighting, and an Inspector sidebar
- Configurable remote permission presets
- Host-key verification and persistent `known_hosts` pinning

## Requirements

- macOS 15 Sequoia or later
- Swift 6 and Xcode 16 or the matching Command Line Tools
- Homebrew
- Native-architecture Homebrew installations of `libssh2` and `openssl@3`

Install the required libraries:

```bash
brew install libssh2 openssl@3
```

## Build and Run

Clone the repository and create a release application:

```bash
git clone https://github.com/<your-account>/Volt.git
cd Volt
./Scripts/package-app.sh
open build/Volt.app
```

The packaging script automatically finds Homebrew at `/opt/homebrew` or
`/usr/local`, builds for the current Mac architecture, bundles the required
dylibs, applies hardened runtime signing, and creates:

```text
build/Volt.app
build/Volt-macOS-<architecture>.zip
```

To run directly through Swift Package Manager:

```bash
VOLT_LIBSSH2_PREFIX="$(brew --prefix libssh2)" swift run Volt
```

Volt currently produces a native `arm64` or `x86_64` build. The selected
Homebrew libraries must have the same architecture as the requested build.

## Packaging Options

Create a DMG in addition to the ZIP archive:

```bash
CREATE_DMG=1 ./Scripts/package-app.sh
```

Build for a specific native architecture:

```bash
ARCH=arm64 ./Scripts/package-app.sh
```

Sign and notarize a distribution build:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="volt-notary" \
CREATE_DMG=1 \
./Scripts/package-app.sh
```

Without `CODE_SIGN_IDENTITY`, the script uses an ad-hoc signature. Notarization
requires a Developer ID Application certificate and a configured `notarytool`
Keychain profile.

## Remote Permissions

Each saved connection can select a permission preset used for newly uploaded or
created remote items:

| Preset | Files | Folders |
| --- | --- | --- |
| Web | `0644` | `0755` |
| Private | `0600` | `0700` |
| Team | `0660` | `0770` |

Volt reports a warning when the transfer succeeds but the server refuses the
requested permission change.

## Security Model

- SFTP transport and authentication are implemented with libssh2.
- The first connection performs an unauthenticated SSH handshake, displays the
  SHA-256 host-key fingerprint, and requires explicit confirmation.
- Accepted host keys are stored with `0600` permissions. Updates use an
  inter-process lock, a temporary file, `fsync`, and atomic replacement.
- A changed host key is rejected before authentication.
- Passwords are kept only in the memory of their current tab and are never
  written to Keychain, UserDefaults, connection files, or command arguments.
- Saved connection metadata uses `0600`; application support and temporary edit
  directories use `0700`.
- Connection and host-key probes have a 15-second timeout.
- Downloaded and temporary edit files are created with restrictive permissions.

SSH key or agent authentication is recommended for long-lived server access.

## Verification

Run the host-key storage and concurrent-write security test:

```bash
./Scripts/test-security.sh
```

Check whether bundled security dependencies need an update:

```bash
./Scripts/audit-dependencies.sh
```

Release builds include third-party license files and a
`DependencyManifest.json` containing dependency versions, architecture, source
provenance, and SHA-256 hashes of the signed dylibs. See
[`Support/DEPENDENCY_MAINTENANCE.md`](Support/DEPENDENCY_MAINTENANCE.md) for the
release maintenance process.

## Project Status

Volt currently supports SFTP only. FTP, FTPS, WebDAV, Amazon S3, folder
synchronization, background transfers, and an SSH terminal are not implemented.

## License

A project license has not been added yet. Third-party dependency notices are
available in [`Support/THIRD_PARTY_NOTICES.txt`](Support/THIRD_PARTY_NOTICES.txt).
