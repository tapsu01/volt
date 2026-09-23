#!/usr/bin/env python3
"""Exercise full remote size scans through a temporary loopback SFTP server."""

import os
from pathlib import Path
import pwd
import shlex
import socket
import subprocess
import tempfile
import time


repo = Path(__file__).resolve().parent.parent
prefix = subprocess.check_output(["brew", "--prefix", "libssh2"], text=True).strip()
username = pwd.getpwuid(os.getuid()).pw_name

with tempfile.TemporaryDirectory(prefix="volt-remote-size-") as temporary:
    root = Path(temporary)
    tree = root / "tree"
    tree.mkdir()
    for index in range(2001):
        folder = tree / f"folder-{index:04d}"
        folder.mkdir()
        (folder / "data").write_bytes(b"abc")
    wide = tree / "wide"
    wide.mkdir()
    for index in range(20001):
        (wide / f"file-{index:05d}").write_bytes(b"x")
    (tree / "link").symlink_to(tree, target_is_directory=True)
    expected = 2001 * 3 + 20001
    unsafe = root / "unsafe"
    unsafe.mkdir()
    (unsafe / "bad\nname").write_bytes(b"x")
    denied = root / "denied"
    denied.mkdir()
    (denied / "file").write_bytes(b"x")

    for name in ("host", "client"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    (root / "sshd.conf").write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {username}
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
""")
    host_key = (root / "host.pub").read_text().split()
    (root / "known_hosts").write_text(f"[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n")
    driver = root / "driver.c"
    driver.write_text(r'''
#include "VoltSSH.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int cancel; uint64_t directories, entries; int64_t bytes; } ProgressState;

static int progress(uint64_t directories, uint64_t entries, int64_t bytes, void *context) {
    ProgressState *state = context;
    state->directories = directories;
    state->entries = entries;
    state->bytes = bytes;
    return state->cancel && entries > 100;
}

int main(int argc, char **argv) {
    if (argc != 7) return 2;
    char error[4096] = {0};
    int64_t size = -1;
    ProgressState state = { .cancel = strcmp(argv[6], "cancel") == 0 };
    int result = volt_sftp_calculate_size("127.0.0.1", atoi(argv[1]), argv[2], "", argv[3], argv[4],
                                         argv[5], &size, progress, &state, error, sizeof(error));
    if (state.cancel) {
        if (result == 0 || size != -1 || strstr(error, "cancelled") == NULL) return 3;
    } else if (strcmp(argv[6], "error") == 0) {
        if (result == 0 || size != -1 || error[0] == '\0') return 5;
    } else if (result != 0) {
        fprintf(stderr, "%s\n", error);
        return 4;
    }
    printf("%" PRId64 " %" PRIu64 " %" PRIu64 " %" PRId64 " %s\n",
           size, state.directories, state.entries, state.bytes, error);
    return 0;
}
''')
    executable = root / "driver"
    sanitizer_flags = shlex.split(os.environ.get("VOLT_SIZE_SANITIZER_FLAGS", ""))
    subprocess.run(["clang", *sanitizer_flags, f"-I{prefix}/include", f"-I{repo}/Sources/CVoltSSH/include",
                    str(driver), str(repo / "Sources/CVoltSSH/VoltSSH.c"), f"-L{prefix}/lib", "-lssh2",
                    "-o", str(executable)], check=True)

    with (root / "sshd.log").open("w+") as log:
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd.conf")],
                                  stdout=log, stderr=log)
        try:
            time.sleep(0.4)
            if server.poll() is not None:
                log.seek(0)
                raise RuntimeError(log.read())
            queue_dir = root / "queue"
            queue_dir.mkdir()

            def scan(target, mode="complete"):
                return subprocess.run([str(executable), str(port), username, str(root / "client"),
                                       str(root / "known_hosts"), str(target), mode],
                                      capture_output=True, text=True, timeout=180, check=True,
                                      env={**os.environ, "TMPDIR": str(queue_dir)})

            total, folders, entries, progress_bytes, *_ = scan(tree).stdout.split()
            assert (int(total), int(folders), int(entries), int(progress_bytes)) == (
                expected, 2003, 24005, expected)
            assert int(scan(wide).stdout.split()[0]) == 20001
            assert int(scan(tree, "cancel").stdout.split()[0]) == -1
            assert "unsafe entry" in scan(unsafe, "error").stdout
            denied.chmod(0)
            assert "open remote directory" in scan(denied, "error").stdout
            assert not list(queue_dir.iterdir())
            print("Remote size: 2002 child folders, 20001 files in one folder, symlink, cancellation and errors: passed")
        finally:
            denied.chmod(0o700)
            server.terminate()
            server.wait(timeout=5)
