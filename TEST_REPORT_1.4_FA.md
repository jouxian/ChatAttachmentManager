# گزارش تست ایستا UNIVERSAL 1.4.0

## انجام‌شده در محیط ساخت

- EngineVersion هر سه Engine برابر `UNIVERSAL-1.4.0-GITHUB` است.
- محدودیت `Get-ChildItem -Filter *.txt` وجود ندارد.
- تولید `all_urls.txt` در Scanner وجود دارد.
- مسیر شخصی `C:\Users\...` در PowerShellهای اصلی وجود ندارد.
- Resume validation شامل `If-Range` و بررسی `Content-Range` است.
- `.part` دارای durable flush دوره‌ای است.
- storage reservation قبل از دانلود durable flush می‌شود.
- checkpoint compaction وجود دارد.
- completion marker و پاک‌سازی cache در Supervisor وجود دارد.
- `AutoCleanupCache` در Manager/GUI وجود دارد.
- Launcher Go با `go test` و `go vet` بررسی شد.
- Windows x64 GUI PE با موفقیت cross-compile شد.
- اندازه EXE ساخته‌شده: 1,969,152 bytes.
- SHA-256 نسخه ساخته‌شده: `de37e138be999fc44bba97db07fd7d82a00d1c3459ffbc35620ff86c1124000c`
- Engine نسخه 1.4، AutoCleanup و Content-Range guard در payload خود EXE قابل مشاهده/تأیید هستند.

## محدودیت محیط ساخت

در این محیط Windows PowerShell 5.1، Windows Task Scheduler و اجرای واقعی WinForms در دسترس نبود. بنابراین تست end-to-end روی Windows واقعی هنوز باید قبل از Stable Release انجام شود. Repository دارای GitHub Actions روی `windows-latest` است که PowerShell parser را روی فایل‌ها اجرا می‌کند و Workflow جداگانه EXE را Build می‌کند.
