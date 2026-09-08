#!/usr/bin/env python3
"""Benchmark upload C transport against a baseline commit on a temporary localhost SFTP server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-commit", default="caffbb6")
    parser.add_argument("--files", type=int, default=1000)
    parser.add_argument("--report", type=Path, default=Path("build/upload-benchmark.json"))
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", args.baseline_commit) or not 1 <= args.files <= 10000:
        parser.error("Use a commit hash and a file count between 1 and 10000")
    repo = Path(__file__).resolve().parent.parent
    brew = shutil.which("brew")
    if not brew:
        raise SystemExit("Homebrew is required")
    prefix = subprocess.check_output([brew, "--prefix", "libssh2"], text=True).strip()
    username = pwd.getpwuid(os.getuid()).pw_name
    results = []
    with tempfile.TemporaryDirectory(prefix="volt-upload-benchmark-") as temporary:
        root = Path(temporary)
        for name in ("host", "client"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        config = root / "sshd.conf"
        config.write_text(f"""Port {port}
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
        public = (root / "host.pub").read_text().split()
        (root / "known_hosts").write_text(f"[127.0.0.1]:{port} {public[0]} {public[1]}\n")
        (root / "small.dat").write_bytes(b"volt benchmark\n" * 256)
        (root / "large.dat").write_bytes(b"volt" * (16 * 1024 * 1024))
        (root / "baseline.c").write_bytes(subprocess.check_output(
            ["git", "show", f"{args.baseline_commit}:Sources/CVoltSSH/VoltSSH.c"], cwd=repo))
        for name, source, flags in [
            ("baseline", root / "baseline.c", ["-DVOLT_BASELINE"]),
            ("optimized", repo / "Sources/CVoltSSH/VoltSSH.c", []),
        ]:
            subprocess.run(["/usr/bin/clang", "-O2", f"-I{prefix}/include",
                            f"-I{repo}/Sources/CVoltSSH/include", *flags,
                            str(repo / "Tests/upload_benchmark.c"), str(source),
                            f"-L{prefix}/lib", "-lssh2", "-o", str(root / name)], check=True)
        with (root / "sshd.log").open("w+") as log:
            server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
            try:
                time.sleep(0.3)
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError("Temporary sshd failed: " + log.read())
                for name, driver, source, count, workers in [
                    ("baseline-small", "baseline", "small.dat", args.files, 1),
                    ("optimized-small", "optimized", "small.dat", args.files, 4),
                    ("baseline-large", "baseline", "large.dat", 1, 1),
                    ("optimized-large", "optimized", "large.dat", 1, 1),
                ]:
                    destination = root / name
                    destination.mkdir()
                    print(f"Running {name}...", flush=True)
                    output = subprocess.check_output([str(root / driver), str(port), username,
                        str(root / "client"), str(root / "known_hosts"), str(root / source),
                        str(destination), str(count), str(min(workers, count))], text=True)
                    expected = hashlib.sha256((root / source).read_bytes()).digest()
                    files = list(destination.iterdir())
                    if len(files) != count or any(hashlib.sha256(path.read_bytes()).digest() != expected for path in files):
                        raise RuntimeError(f"Content verification failed: {name}")
                    print(output.strip() + " sha256=matched", flush=True)
                    results.append(dict(case=name, measurements=output.strip(), sha256="matched", source_bytes=(root / source).stat().st_size))
                checks = root / "publish-checks"
                checks.mkdir()
                target = checks / "file-0"
                target.write_bytes(b"original contents")
                command = [str(root / "optimized"), str(port), username, str(root / "client"),
                           str(root / "known_hosts"), str(root / "small.dat"), str(checks), "1", "1"]
                # Create-new must refuse to replace an existing destination.
                rejected = subprocess.run(command, capture_output=True, text=True)
                if rejected.returncode == 0 or target.read_bytes() != b"original contents":
                    raise RuntimeError("Create-new replaced an existing file")
                subprocess.run([*command, "1"], check=True)
                if target.read_bytes() != (root / "small.dat").read_bytes():
                    raise RuntimeError("Safe replacement content mismatch")
                command[5] = str(root / "large.dat")
                cancelled = subprocess.run([*command, "1", "262144"], capture_output=True, text=True)
                if cancelled.returncode == 0 or target.read_bytes() != (root / "small.dat").read_bytes():
                    raise RuntimeError("Cancelled replacement changed the existing file")
                if list(checks.glob("*.volt-part-*")):
                    raise RuntimeError("Cancelled upload left temporary files")
                results.append(dict(case="publish-and-cancel", result="passed", checks=["create-new conflict", "safe replacement", "cancelled replacement preserves destination", "temporary cleanup"]))
                print("Publish and cancellation integration checks passed", flush=True)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"baseline_commit": args.baseline_commit, "scope": "localhost C transport, not GUI or WAN", "results": results}, indent=2) + "\n")
    print(f"Report: {args.report}")


if __name__ == "__main__":
    main()
