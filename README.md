<div align="center">

# Chat Attachment Manager

**Resilient Windows tool for scanning chat/export archives, extracting URLs, identifying real downloadable files, and downloading attachments with persistent resume support.**

[![Release](https://img.shields.io/github/v/release/jouxian/ChatAttachmentManager?sort=semver)](https://github.com/jouxian/ChatAttachmentManager/releases/latest)
[![Static Checks](https://github.com/jouxian/ChatAttachmentManager/actions/workflows/static-checks.yml/badge.svg)](https://github.com/jouxian/ChatAttachmentManager/actions/workflows/static-checks.yml)
[![Build Windows EXE](https://github.com/jouxian/ChatAttachmentManager/actions/workflows/build-exe.yml/badge.svg)](https://github.com/jouxian/ChatAttachmentManager/actions/workflows/build-exe.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11%2FServer-0078D4?logo=windows&logoColor=white)](https://www.microsoft.com/windows/)
[![License](https://img.shields.io/github/license/jouxian/ChatAttachmentManager)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/jouxian/ChatAttachmentManager/total)](https://github.com/jouxian/ChatAttachmentManager/releases)

[**Download Windows EXE**](https://github.com/jouxian/ChatAttachmentManager/releases/latest/download/ChatAttachmentManager.exe) · [Latest Release](https://github.com/jouxian/ChatAttachmentManager/releases/latest) · [Security Policy](SECURITY.md) · [Changelog](CHANGELOG.md)

</div>

---
## End-user release

For normal users, publish **`ChatAttachmentManager.exe`** from `dist/` as the GitHub Release asset. The EXE is a native Windows x64 launcher and embeds the matching `Manager.ps1`, `Scanner.ps1`, `Downloader.ps1`, and `Supervisor.ps1` sources. At runtime it materializes them under `%LOCALAPPDATA%\ChatAttachmentManager\App\1.4.0` and launches the GUI.

Windows PowerShell 5.1 is still the execution engine behind the GUI/download logic, but users do not need to keep `.ps1` or `.cmd` files next to the EXE.

## Highlights

- Content-based source detection instead of `*.txt`-only scanning.
- Supports TXT, JSON/JSONL, CSV/TSV, LOG, HTML, XML, Markdown, YAML/YML, INI/CFG/CONF, and extensionless text-like files.
- Recognizes `CHAT #...`, `RECORD #...`, `[FILE]`, `[IMAGE]`, `[ATTACHMENT]` JSON, and ordinary URLs.
- Normalizes plain, JSON-escaped, Unicode-escaped, and HTML-escaped URLs.
- Creates `all_urls.txt` after the scan: one extracted URL per line.
- Uses the real HTTP response (`Content-Type`, `Content-Disposition`, redirects/final URL) before deciding whether a URL is a file.
- Resume survives internet loss, DNS/TLS errors, process crashes, Windows restarts, and partially downloaded files.
- Host-specific cooldown and retry/backoff for 429/network/transient errors.
- Two storage layouts: per-chat folders or one flat folder with chat prefixes.
- Rebuildable cache is automatically cleaned after a truly successful project completion.

## Resume behavior

While work is active, the program keeps all state needed to continue:

- Scanner checkpoints completed source files independently.
- `download_state.jsonl` records the latest outcome for each URL.
- `storage_map.jsonl` preserves stable output numbering/path decisions.
- Incomplete downloads are kept as `.part` files under `_chat_attachment_manager\partials`.
- Partial downloads store ETag/Last-Modified metadata and use `If-Range` when the server supports it.
- A resumed HTTP `206` response must have the expected `Content-Range`; otherwise the partial is discarded and restarted safely.
- Download data is durably flushed periodically, reducing redownload after a hard shutdown or power failure.
- If the network is unavailable, Supervisor retries Downloader directly with exponential backoff up to 15 minutes; it does not waste time rescanning the source archive between network retries.

The Scheduled Task is configured to start at Windows boot. If Windows restarts before completion, the same project resumes from on-disk state.

## Completion and automatic cache cleanup

New projects include a checked **Auto cleanup cache after successful completion** option, stored as:

```json
"AutoCleanupCache": true
```

After Scanner has no source errors and Downloader has no pending/transient items, Supervisor writes `completion.json`, creates the final reports, and removes rebuildable cache directories:

- `scan\`
- `preflight\`
- `partials\`

It intentionally **keeps** `download_state.jsonl` and `storage_map.jsonl`. These are compact state/checkpoint files, not disposable cache: deleting them would lose idempotence and stable file numbering on a manual rerun.

After completion, an automatic Windows startup does not rerun the finished project. Clicking **Start / Continue** in Manager is treated as an explicit request to run the project again and clears the completion marker.

## Performance changes in 1.4

- Scanner streams per-source URL inventory to disk instead of retaining all URL rows in RAM.
- `all_urls.txt` is produced during inventory merge without reparsing the final CSV.
- Compiled URL regex and lower-frequency status-clock checks reduce hot-loop overhead.
- Known text extensions use an 8 KiB binary sanity sample; unknown/extensionless files keep the deeper 64 KiB content check.
- Downloader status JSON writes are throttled.
- `download_state.jsonl` uses a persistent AutoFlush writer during each pass and is compacted on a stable final pass (or earlier if it grows beyond 128 MiB).
- Download buffer is 128 KiB.
- Default inter-request delay is 50 ms and configurable.

## Requirements

- Windows 10/11 or Windows Server x64.
- Windows PowerShell 5.1.
- Administrator rights are required by the current Manager because it registers a Scheduled Task that runs as `SYSTEM`.

## Start

### Release user

1. Download `ChatAttachmentManager.exe` from GitHub Releases.
2. Run it.
3. Approve the UAC prompt.
4. Create a new project or open an existing output folder.
5. Choose whether subfolders should be scanned and the download storage layout.
6. Click **Start / Continue**.

### Source checkout

`OPEN_MANAGER.cmd` remains as a development/fallback entry point.

## Important output files

| File/folder | Purpose |
|---|---|
| `all_urls_inventory.csv` | URL inventory with source/context/evidence/classification |
| `all_urls.txt` | Plain-text URL list, one URL per line |
| `source_files_detected.csv` | Source files accepted as text-like, including extension |
| `files\` | Downloaded files |
| `attachments_index.csv` | Downloaded/already-existing file index |
| `attachments_failed.csv` | Permanent/transient failures |
| `urls_skipped_as_nonfiles.csv` | URLs whose HTTP response was not considered a file |
| `_chat_attachment_manager\download_state.jsonl` | Compact persistent per-URL resume/idempotence state |
| `_chat_attachment_manager\storage_map.jsonl` | Stable output numbering/path reservations |
| `_chat_attachment_manager\completion.json` | Terminal completion marker |

## Performance setting

New projects include this field in `_chat_attachment_manager\project.json`:

```json
"RequestDelayMs": 50
```

Allowed by Downloader: `0` to `5000` ms. Lower values can be faster but may trigger rate limits. Downloader still respects 429 `Retry-After` and per-host cooldowns.

## Building the EXE

The repository intentionally keeps the PowerShell source readable. The EXE is a launcher generated from the tracked source, not a hand-maintained second copy.

On a development machine with Go 1.22+:

```powershell
.\build\build-exe.ps1
```

Output:

```text
dist\ChatAttachmentManager.exe
```

The `Build Windows EXE` GitHub Actions workflow runs the same build and uploads the EXE plus `SHA256SUMS.txt` as artifacts. Pushing a `v*` tag also creates a GitHub Release with both files attached.

## Security / privacy

This program makes network requests to URLs found in the selected source files and follows redirects. Use trusted exports. A malicious/untrusted source file can contain URLs to internal/private services.

URLs can contain signed tokens or other sensitive query parameters. Runtime reports and checkpoints may therefore contain sensitive URLs. Do **not** commit project outputs, logs, `all_urls.txt`, inventories, or `_chat_attachment_manager` state to a public repository. The included `.gitignore` excludes the common runtime files.

## Testing

`tests/StaticChecks.ps1` verifies PowerShell syntax, engine-version consistency, accidental `*.txt` filtering, local absolute paths, URL text export, resume safeguards, and completion cleanup wiring.

GitHub Actions runs the PowerShell checks on `windows-latest`; a separate workflow builds the Windows x64 launcher.

A real Windows smoke test is still recommended before tagging a stable public release, especially against the exact Windows Server version used in production.

## License

Chat Attachment Manager is released under the **MIT License**. See [LICENSE](LICENSE) for the full license text.
