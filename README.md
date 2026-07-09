<h1 align="center">⚡ Volt</h1>

<p align="center">
  <strong>Fast, native and beautiful file transfer for macOS.</strong>
  <br>
  Modern SFTP client built with SwiftUI.
</p>

---

## Features

- ⚡ Native SwiftUI interface
- 📂 Dual-pane file manager
- 🔐 Secure SFTP connections
- 📤 Drag & drop uploads and downloads
- ✏️ Remote file editing with automatic upload
- 🔑 Secure password storage using macOS Keychain
- 🗂️ Multi-tab sessions
- 👀 Quick Look support for local and remote files
- 🚀 Optimized for the macOS desktop experience

---

## Why Volt?

Volt is designed to feel like a first-party macOS application.

It focuses on:

- Native performance
- Clean and modern interface
- Keyboard-friendly workflow
- Secure file transfers
- Simple, distraction-free experience

---

## Requirements

- macOS 14 Sonoma or later
- Swift 6+
- Xcode 16+ (recommended)

---

## Getting Started

Clone the repository:

```bash
git clone https://github.com/<your-account>/Volt.git
cd Volt
```

Build the application:

```bash
./Scripts/package-app.sh
```

The generated application will be located in:

```
build/Volt.app
```

Or run directly with Swift Package Manager:

```bash
swift run Volt
```

---

## Remote Editing

Edit remote files directly using your preferred editor.

1. Select a remote file.
2. Click **Edit**.
3. Volt downloads a temporary local copy.
4. The file opens in your default editor.
5. Save your changes.
6. Return to Volt and click **Upload Edited**.

---

## Roadmap

### Current

- [x] Native SwiftUI interface
- [x] SFTP support
- [x] Dual-pane file browser
- [x] Multi-tab support
- [x] Remote editing
- [x] Quick Look
- [x] Keychain integration

### Planned

- [ ] SSH terminal
- [ ] Folder synchronization
- [ ] Bookmark manager
- [ ] Transfer queue improvements
- [ ] Background transfers
- [ ] Amazon S3
- [ ] WebDAV
- [ ] FTP / FTPS

---

## Contributing

Contributions are welcome!

If you'd like to improve Volt, feel free to open an issue or submit a pull request.

---

## License

Volt is released under the MIT License.

See the [LICENSE](LICENSE) file for details.

---

<p align="center">
Built with ❤️ using SwiftUI for macOS.
</p>