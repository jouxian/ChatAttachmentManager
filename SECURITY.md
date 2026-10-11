# Security notes

Chat Attachment Manager follows HTTP(S) URLs found in user-selected source files. Only process exports you trust.

Potential risks:

- URLs may target localhost, private-network hosts, cloud metadata endpoints, or other internal services.
- Redirects are followed.
- Signed URLs can contain sensitive tokens and may be written to inventories/checkpoints/logs.
- The current Scheduled Task runs as `SYSTEM`.

Do not publish runtime output/state from real projects. Keep `_chat_attachment_manager`, logs, checkpoints, inventories, and URL lists out of public repositories.

For a hardened future release, consider an opt-in/opt-out private-network policy, least-privilege Manager execution, and an allowlist/denylist for hosts.
