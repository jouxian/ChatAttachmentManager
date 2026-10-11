# Changelog

## 1.4.2-GITHUB

### Fixed
- Fixed English UI layout after the localization update.
- Moved the main title to the left to prevent clipping.
- Rebalanced scan and download statistic columns to prevent label/value overlap.
- Fixed the Skipped non-files label so it is fully visible.

### Validation
- PowerShell syntax checks pass.
- Static checks pass.
- git diff --check passes.
- Manual Windows UI smoke test passed.

## 1.4.1-GITHUB

### Changed
- Converted the Windows GUI, dialogs, runtime status messages, and downloader/scanner messages to English.
- Removed Persian and legacy FA documentation files from the public repository.
- Removed obsolete Persian documentation links from the README.
- Preserved support for recognizing Persian Name/Customer fields in imported chat exports without keeping literal Persian characters in the source.

### Validation
- PowerShell syntax checks pass.
- Repository static checks pass.
- Repository scan contains no Persian characters.

## 1.4.0-GITHUB

### Added
- Native Windows `ChatAttachmentManager.exe` launcher built with Go. The EXE embeds `Manager.ps1` and all three PowerShell engines and materializes the matching version under LocalAppData at runtime.
- GitHub Actions workflow to build the Windows x64 EXE and attach it automatically to tagged GitHub Releases.
- `completion.json` terminal marker so a finished project is not started again just because Windows rebooted.
- `AutoCleanupCache` project option (enabled by default).

### Reliability / resume
- Supervisor now retries Downloader directly after internet/DNS/TLS/transient HTTP failures instead of needlessly rescanning the source archive first.
- Exponential retry backoff up to 15 minutes for repeated network or child-process failures; state remains on disk throughout.
- Unexpected Scanner/Downloader exits are retried instead of permanently stopping the automatic workflow.
- Partial downloads now persist ETag/Last-Modified metadata and use `If-Range` when resuming when possible.
- Resume validates `Content-Range`; a mismatched/rejected range is reset safely instead of risking a corrupted concatenated file.
- Active `.part` files are durably flushed periodically, reducing redownload after a hard shutdown/power loss.
- Compressed HTTP transfers are restarted rather than range-resumed using incompatible decompressed offsets.
- `download_state.jsonl` is compacted on a stable final pass, or earlier if it grows beyond 128 MiB, to keep only the latest state per URL key.

### Cleanup
- After a fully successful scan/download pass with no transient items or scan errors, rebuildable `scan`, `preflight`, and `partials` caches are deleted automatically.
- Critical compact resume/idempotence state (`download_state.jsonl` and `storage_map.jsonl`) is intentionally preserved so a manual rerun does not lose download identity or numbering.
- Final CSV/TXT reports and downloaded files are never removed by automatic cleanup.

### Performance
- Known text extensions use a smaller 8 KiB binary sanity sample during source discovery; unknown/extensionless inputs keep the deeper 64 KiB content test.
- Internet retry cycles reuse the existing inventory and do not rerun Scanner while the network is unavailable.

## 1.3.0-GITHUB

### Added
- `all_urls.txt` plain-text URL export after full scan.
- GitHub `.gitignore`, bilingual README, security guidance, and Windows static-check CI.
- Configurable `RequestDelayMs` (default 50 ms).
- YAML/YML/TSV/INI/CFG/CONF file-extension recognition for attachment URLs.

### Performance
- Stream per-source scanner inventory directly to cache CSV instead of retaining all URL rows in memory.
- Compiled URL regex and reduced per-line wall-clock checks.
- Throttled downloader status-file writes.
- Persistent AutoFlush checkpoint writer during a download pass.
- 128 KiB download buffer.
- Lower default inter-request delay (150 ms -> 50 ms).

### Reliability
- Bound repeated 429 retries per pass.
- Reset partial and retry after HTTP 416 range rejection.
- Honor Retry-After for 502/503/504 when supplied.
- Enable TLS 1.2 on older Windows PowerShell environments.
- Sanitize reserved Windows device filenames.
- Fix UTF-32 BOM detection order.
- Apply control-character heuristics even when a byte sample is valid UTF-8.
- Fix GUI subfolder checkbox being reset by the refresh timer.

### Privacy
- Store recent-project UI state under LocalAppData when possible instead of next to repository source files.
