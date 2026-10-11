# چک‌لیست انتشار در GitHub

1. قبل از Public کردن Repository یک License انتخاب کنید (MIT / Apache-2.0 / GPL-3.0 یا گزینه مناسب شما).
2. کل پوشه Source را Commit کنید؛ فایل‌های `dist/` و `*.exe` عمداً در `.gitignore` هستند و بهتر است Binary داخل Git history قرار نگیرد.
3. روی Windows واقعی یک پروژه کوچک شامل TXT + JSON + CSV تست کنید.
4. وسط دانلود یک فایل بزرگ اینترنت را قطع و وصل کنید و Resume `.part` را بررسی کنید.
5. وسط دانلود Windows/VM را Restart کنید و ادامه خودکار Task Scheduler را بررسی کنید.
6. اتمام کامل را بررسی کنید: `completion.json` باید `COMPLETE` شود و `scan/`, `preflight/`, `partials/` در حالت AutoCleanup حذف شوند؛ `download_state.jsonl` و `storage_map.jsonl` باید باقی بمانند.
7. `all_urls.txt`, `all_urls_inventory.csv`, `attachments_index.csv` و `urls_skipped_as_nonfiles.csv` را بررسی کنید.
8. Tag مثل `v1.4.0` Push کنید. Workflow `Build Windows EXE` فایل `ChatAttachmentManager.exe` را Build و به GitHub Release اضافه می‌کند.
9. EXE Release را روی یک Windows تمیز (بدون سورس Repository کنار آن) اجرا کنید تا Embed/Extraction به LocalAppData تأیید شود.
10. قبل از انتشار عمومی مطمئن شوید هیچ Output واقعی مشتری، URL دارای token، log یا پوشه `_chat_attachment_manager` داخل Commit نیست.
