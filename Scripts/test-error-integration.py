#!/usr/bin/env python3
"""Exercise Volt error messages against a temporary loopback-only SSH server."""
import os
from pathlib import Path
import pwd
import socket
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
prefix = subprocess.check_output(["brew", "--prefix", "libssh2"], text=True).strip()
username = pwd.getpwuid(os.getuid()).pw_name
with tempfile.TemporaryDirectory(prefix="volt-errors-") as temporary:
    root = Path(temporary)
    for name in ("host", "client", "wrong"):
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
    key = (root / "host.pub").read_text().split()
    (root / "known_hosts").write_text(f"[127.0.0.1]:{port} {key[0]} {key[1]}\n")
    source = root / "source.txt"
    source.write_text("Volt error integration\n")
    denied = root / "denied"
    denied.mkdir()
    denied.chmod(0o500)
    driver = root / "driver.c"
    driver.write_text(r'''
#include "VoltSSH.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 8) return 2;
    char error[4096] = {0};
    int result;
    if (strcmp(argv[1], "list") == 0) {
        VoltSFTPItem *items = NULL;
        int count = 0, skipped = 0, truncated = 0;
        result = volt_sftp_list("127.0.0.1", atoi(argv[2]), argv[3], "", argv[4], argv[5], argv[7],
                                100, &items, &count, &skipped, &truncated, error, sizeof(error));
        volt_sftp_free_items(items, count);
    } else {
        result = volt_sftp_upload("127.0.0.1", atoi(argv[2]), argv[3], "", argv[4], argv[5], argv[6], argv[7],
                                  0600, 0, NULL, NULL, error, sizeof(error));
    }
    printf("%s\n", error);
    return result == 0 ? 0 : 1;
}
''')
    executable = root / "driver"
    subprocess.run(["clang", f"-I{prefix}/include", f"-I{repo}/Sources/CVoltSSH/include",
                    str(driver), str(repo / "Sources/CVoltSSH/VoltSSH.c"), f"-L{prefix}/lib", "-lssh2",
                    "-o", str(executable)], check=True)
    with (root / "sshd.log").open("w+") as log:
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd.conf")], stdout=log, stderr=log)
        try:
            time.sleep(0.4)
            if server.poll() is not None:
                log.seek(0)
                raise RuntimeError(log.read())
            def run(operation, key_name, target):
                return subprocess.run([str(executable), operation, str(port), username, str(root / key_name),
                    str(root / "known_hosts"), str(source), str(target)], capture_output=True, text=True, timeout=25)
            success = run("upload", "client", root / "success.txt")
            assert success.returncode == 0, success.stdout + success.stderr
            assert (root / "success.txt").read_bytes() == source.read_bytes()
            print("Successful upload: passed")
            wrong = run("list", "wrong", root)
            assert wrong.returncode == 1 and wrong.stdout.strip(), wrong
            print("Wrong SSH key:", wrong.stdout.strip())
            failed = run("upload", "client", denied / "file.txt")
            assert failed.returncode == 1 and "Permission denied" in failed.stdout, failed
            assert not list(denied.iterdir())
            print("Denied upload:", failed.stdout.strip())
            denied.chmod(0)
            failed = run("list", "client", denied)
            assert failed.returncode == 1 and "Permission denied" in failed.stdout, failed
            print("Denied directory:", failed.stdout.strip())
        finally:
            denied.chmod(0o700)
            server.terminate()
            server.wait(timeout=5)
