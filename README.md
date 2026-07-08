# TransmitLite

TransmitLite is a native macOS SwiftUI file-transfer client inspired by the workflow of dual-pane transfer tools. It is not affiliated with Panic and does not copy Transmit assets, branding, or proprietary behavior.

## Features

- macOS-only native SwiftUI interface
- Saved SFTP connections
- SSH private-key or agent authentication through macOS OpenSSH
- Local and remote file browsing
- Upload and download with a transfer queue
- Upload files/folders with a picker
- Download remote items to the current local pane or a chosen folder
- Edit local files in the default macOS editor
- Edit remote files by downloading a temporary copy, opening it locally, then uploading the edited copy back
- Rename local and remote items
- Create local and remote files
- Create and delete local folders/files
- Create and delete remote folders/files
- Password field is stored in Keychain for future expansion, but SFTP execution currently uses key/agent auth because OpenSSH password prompts require an interactive TTY

## Build

```sh
/usr/bin/swift build
```

## Run

```sh
/usr/bin/swift run TransmitLite
```

For SFTP connections, make sure the server accepts your SSH key or your key is loaded in `ssh-agent`.

## Remote editing

Select a remote file and click the pencil button. TransmitLite downloads the file to a temporary local copy and opens it in your default editor. Save the file in that editor, then return to TransmitLite and click `Upload Edited` in the Remote Edits panel.
