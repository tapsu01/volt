# Upload reliability and performance validation

Validated locally on 2026-09-08, native x86_64 macOS, against baseline commit
`caffbb6`. The working-tree implementation adds safe publication, upload batch
tracking, bounded background folder scanning, and four reusable upload workers.

## Automated checks

- Final release `Scripts/package-app.sh` passed, including bundle signing,
  dependency hash verification and dynamic-library linkage checks. Artifacts:
  `build/Volt.app` and `build/Volt-macOS-x86_64.zip`.
- `Scripts/test-security.sh`: host-key storage, entry-name validation, and the
  new upload fault-injection tests passed with AddressSanitizer and UBSan.
- `Scripts/test-upload.sh --scratch-path /private/tmp/volt-upload-build`:
  eight Swift Testing tests passed. Coverage includes out-of-order and duplicate
  completion, independent batch state, tab/connection/path checks, shared worker
  limits, queued cancellation, worker failure, progress aggregation, overflow,
  hidden files, symlinks, and traversal limits.
- A background scan of 10,000 files and a 64-level tree took approximately
  0.166 seconds, excluding fixture creation. Depth 65 was rejected.
- Legacy XCTest suites remain unavailable on this Command Line Tools-only
  installation. They are guarded with explicit build warnings and still run
  with full Xcode. The upload script locates the bundled Swift Testing framework
  and disables its unavailable Foundation cross-import overlay on CLT.

## Local SFTP transport measurements

The benchmark uses a temporary, unprivileged OpenSSH server bound to localhost,
generated test keys, and a dedicated pinned known-hosts file. It does not use
saved app connections or server credentials. The baseline opens one session per
file; the updated driver keeps one session per worker.

| Workload | Baseline | Updated | Sessions before / after |
| --- | ---: | ---: | ---: |
| 1,000 files, 3,840 bytes each | 151.326 s | 0.471 s | 1,000 / 4 |
| One 64 MiB file | 0.405 s | 0.437 s | 1 / 1 |

Every uploaded file matched the source SHA-256 digest. These are single-run C
transport smoke measurements. The small-file baseline overlapped some build
work; they are not controlled statistical benchmarks or an end-to-end speedup
claim. They exclude Swift conflict preparation, UI rendering, and WAN latency.
The large-file difference is too small and insufficiently sampled to infer a
performance change.

Peak RSS reported by the small-file transport driver was 11,563,008 bytes before
and 10,903,552 bytes after. This is driver memory, **not Volt application memory**.

Additional real-server checks passed:

- Create-new refuses an existing destination and preserves its contents.
- POSIX replacement publishes the expected new contents.
- Cancelling a replacement after 256 KiB keeps the previous destination intact
  and removes the temporary upload file.

Reproduce the transport benchmark and integration checks with:

```sh
./Scripts/benchmark-upload.py --baseline-commit caffbb6 --files 1000
```

The report is written to `build/upload-benchmark.json`. For a shorter script
smoke test, use `--files 10` and a separate `--report` path.

## Behavior and limits

- Replacement requires the server's POSIX rename extension. Unsupported or
  rejected replacement fails without deleting the destination as a fallback.
- A lost publish reply is reported as an unknown outcome. The temporary path is
  retained for inspection, and the operation is not automatically retried.
- Cancellation stops queued work and checks between writes/files. A socket call
  already in progress can still wait for the configured 15-second timeout.
- Successfully published files are retained after partial failure or cancellation.
  Queue summaries retain completed/skipped/warning counts and dirty directories
  are invalidated on every terminal outcome.
- Folder scanning uses the existing limits: depth 64, 2,000 directories and
  100,000 entries. One folder plan is active at a time to bound retained memory;
  its workers share the application's four transfer permits with other uploads.
- GUI interaction, full application peak RAM, and WAN/server-specific behavior
  have not been benchmarked in this validation. The legacy XCTest suite still
  needs a full-Xcode run.
