# ⚡ Volt

Fast, native and beautiful file transfer for macOS.

Volt is a modern file transfer client built with SwiftUI, designed for speed, simplicity and a native macOS experience.

## Features

- **Dual-Pane Interface**: Browse local files on the left and remote files on the right.
- **SFTP Support**: Connect to servers securely using SFTP.
- **Transfers**: Upload and download files and directories using drag-and-drop or context menus.
- **Remote Editing**: Select a file, click the Edit button, and it opens in your default local editor. Save it, and Volt uploads it back to the server.
- **Keychain Integration**: Passwords are securely stored in the macOS Keychain.
- **Multi-Tab Support**: Open multiple remote sessions at once.
- **Quick Look**: Preview local and remote files with the spacebar.

## Requirements

- macOS 14.0 or later
- Swift 6.0 or later (for building)

## Build Instructions

To build the standalone `.app` bundle, use the provided script:

```sh
./Scripts/package-app.sh
```

This will create `Volt.app` inside the `build/` directory.

Alternatively, you can build and run directly via Swift PM:

```sh
/usr/bin/swift run Volt
```

## Remote Editing

Select a remote file and click the pencil button. Volt downloads the file to a temporary local copy and opens it in your default editor. Save the file in that editor, then return to Volt and click `Upload Edited` in the Remote Edits panel.

## License

MIT License. See LICENSE for more information.
