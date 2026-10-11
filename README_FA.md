# Chat Attachment Manager UNIVERSAL 1.4.0

ابزار ویندوز برای اسکن آرشیوهای بزرگ گفتگو، استخراج URLها، تشخیص فایل واقعی از روی پاسخ HTTP و دانلود قابل‌ادامه‌ی پیوست‌ها.

## نسخه مناسب برای کاربر نهایی

برای GitHub Release فایل **`ChatAttachmentManager.exe`** را منتشر کنید. این EXE نسخه x64 ویندوز است و `Manager.ps1` و هر سه Engine را داخل خودش Embed دارد. هنگام اجرا، نسخه هماهنگ Engine را در مسیر زیر باز می‌کند و GUI را اجرا می‌کند:

```text
%LOCALAPPDATA%\ChatAttachmentManager\App\1.4.0
```

بنابراین کاربر نهایی لازم نیست فایل‌های `.ps1` یا `.cmd` را کنار EXE نگه دارد. PowerShell 5.1 خود ویندوز همچنان Engine اجرای منطق برنامه است.

## قابلیت‌ها

- ورودی فقط TXT نیست؛ تشخیص فایل متنی بر اساس محتوا انجام می‌شود.
- TXT، JSON/JSONL، CSV/TSV، LOG، HTML، XML، MD/Markdown، YAML/YML، INI/CFG/CONF و فایل متنی بدون پسوند پشتیبانی می‌شوند.
- ساختارهای `CHAT #`، `RECORD #`، مارکرهای `[FILE]/[IMAGE]/...` و `[ATTACHMENT]` JSON پشتیبانی می‌شوند.
- URL عادی، JSON-escaped، Unicode-escaped و HTML-escaped نرمال می‌شود.
- بعد از اسکن، **`all_urls.txt`** ساخته می‌شود؛ هر خط یک URL استخراج‌شده است.
- Downloader تصمیم نهایی فایل/صفحه را با `Content-Type`، `Content-Disposition` و Redirect/URL نهایی می‌گیرد.
- در برابر قطع اینترنت، DNS/TLS، Crash برنامه، Restart ویندوز و دانلود نیمه‌کاره Resume دارد.
- برای هر Host cooldown و Retry جداگانه دارد.
- دو روش ذخیره‌سازی فایل دارد: پوشه جدا برای چت یا حالت Flat با کد چت در نام فایل.

## مقاومت در برابر قطع اینترنت و خاموشی

تا وقتی پروژه تمام نشده است، اطلاعات لازم برای ادامه روی دیسک باقی می‌ماند:

- Scanner نتیجه هر فایل منبع کامل‌شده را جدا checkpoint می‌کند.
- `download_state.jsonl` نتیجه URLها را نگه می‌دارد.
- `storage_map.jsonl` شماره و مسیر نهایی فایل‌ها را ثابت نگه می‌دارد.
- دانلود ناقص داخل `_chat_attachment_manager\partials` با پسوند `.part` می‌ماند.
- برای partial، `ETag` و `Last-Modified` ذخیره می‌شود و در Resume در صورت امکان `If-Range` ارسال می‌شود.
- اگر سرور هنگام Resume محدوده اشتباه (`Content-Range`) برگرداند، partial به فایل جدید چسبانده نمی‌شود و دانلود امن از صفر شروع می‌شود.
- داده‌ی `.part` دوره‌ای Flush پایدار می‌شود تا در قطع برق مقدار کمتری نیاز به دانلود مجدد داشته باشد.
- اگر اینترنت قطع باشد، Supervisor مستقیم Downloader را با فاصله افزایشی تا حداکثر ۱۵ دقیقه Retry می‌کند؛ بین Retryهای شبکه Scanner دوباره بیهوده اجرا نمی‌شود.

Scheduled Task با بالا آمدن ویندوز اجرا می‌شود. اگر سیستم وسط کار Restart شود، همان پروژه از checkpointهای روی دیسک ادامه پیدا می‌کند.

## پاک‌کردن خودکار Cache بعد از اتمام

در GUI گزینه **«پاک کردن Cache بعد از اتمام موفق»** به‌طور پیش‌فرض فعال است و در پروژه به شکل زیر ذخیره می‌شود:

```json
"AutoCleanupCache": true
```

فقط وقتی Scanner هیچ خطای منبع نداشته باشد و Downloader هیچ مورد Pending/Transient نداشته باشد، پروژه `COMPLETE` می‌شود. بعد از آن Cacheهای قابل‌بازسازی پاک می‌شوند:

- `scan\`
- `preflight\`
- `partials\`

اما دو فایل **عمداً پاک نمی‌شوند**:

- `download_state.jsonl`
- `storage_map.jsonl`

این دو Cache اضافی نیستند؛ state کوچک و حیاتی Resume/Idempotence هستند. حذفشان می‌تواند باعث بررسی/دانلود دوباره یا به‌هم خوردن شماره فایل‌ها در اجرای بعدی شود. `download_state.jsonl` در پایان هر دور Compact می‌شود تا فقط آخرین وضعیت هر URL بماند.

فایل‌های نهایی، `all_urls.txt`، CSVهای گزارش و پوشه `files` هیچ‌وقت توسط Cleanup خودکار پاک نمی‌شوند.

پس از اتمام، `completion.json` ثبت می‌شود. بنابراین صرفاً به‌خاطر Restart ویندوز پروژه کامل‌شده دوباره شروع نمی‌شود. اگر داخل Manager دکمه **«شروع / ادامه»** را بزنید، این کار درخواست صریح برای اجرای دوباره محسوب می‌شود و completion marker برداشته می‌شود.

## بهبود سرعت در 1.4

- Scanner اطلاعات URL را Streaming می‌نویسد و لازم نیست تمام URLهای یک فایل بزرگ را در RAM نگه دارد.
- `all_urls.txt` هم‌زمان با Merge inventory تولید می‌شود و CSV نهایی دوباره Parse نمی‌شود.
- Regex اصلی URL compiled است و بررسی زمان وضعیت GUI در Hot Loop کمتر انجام می‌شود.
- برای پسوندهای متنی شناخته‌شده فقط ۸ KiB نمونه برای sanity check باینری خوانده می‌شود؛ فایل ناشناخته/بدون پسوند همچنان بررسی ۶۴ KiB دارد.
- نوشتن `download_status.json` throttle شده است.
- checkpoint دانلود در طول pass با StreamWriter باز می‌ماند و در pass نهایی (یا اگر از ۱۲۸ MiB بزرگ‌تر شود) Compact می‌شود.
- بافر دانلود ۱۲۸ KiB است.
- فاصله پیش‌فرض درخواست‌ها ۵۰ms است و قابل تنظیم است.

## اجرا برای کاربر نهایی

1. از GitHub Releases فایل `ChatAttachmentManager.exe` را دانلود کنید.
2. EXE را اجرا کنید و UAC را تأیید کنید.
3. «پروژه جدید» یا «باز کردن پروژه موجود» را بزنید.
4. گزینه زیرپوشه‌ها و روش ذخیره‌سازی را انتخاب کنید.
5. «شروع / ادامه» را بزنید.

`OPEN_MANAGER.cmd` فقط به‌عنوان روش توسعه/جایگزین در سورس باقی مانده است.

## خروجی‌های مهم

- `all_urls_inventory.csv` — Inventory کامل URLها با context و classification
- `all_urls.txt` — فقط URLها، هر لینک در یک خط
- `source_files_detected.csv` — فایل‌های منبع متنی شناسایی‌شده همراه Extension
- `files\` — فایل‌های دانلودشده
- `attachments_index.csv` — فایل‌های موفق/ازقبل‌موجود
- `attachments_failed.csv` — خطاهای نهایی یا موقت
- `urls_skipped_as_nonfiles.csv` — URLهایی که پاسخ HTTP آن‌ها فایل نبود
- `_chat_attachment_manager\download_state.jsonl` — state فشرده Resume برای URLها
- `_chat_attachment_manager\storage_map.jsonl` — نگاشت ثابت شماره/مسیر فایل‌ها
- `_chat_attachment_manager\completion.json` — علامت پایان کامل پروژه

## تنظیم سرعت

داخل `project.json`:

```json
"RequestDelayMs": 50
```

Downloader مقدار ۰ تا ۵۰۰۰ میلی‌ثانیه را قبول می‌کند. عدد کمتر سریع‌تر است ولی ممکن است 429 بیشتری ایجاد کند. `Retry-After` و cooldown هر Host همچنان رعایت می‌شود.

## ساخت EXE برای GitHub

سورس PowerShell داخل Repository خوانا باقی می‌ماند. EXE از همان سورس ساخته می‌شود و یک نسخه جداگانه‌ی دستی از منطق برنامه نیست.

روی سیستم توسعه با Go 1.22 یا جدیدتر:

```powershell
.\build\build-exe.ps1
```

خروجی:

```text
dist\ChatAttachmentManager.exe
```

Workflow با نام **Build Windows EXE** نیز همین کار را روی GitHub Actions انجام می‌دهد. اگر Tag با الگوی `v*` Push شود، Release ساخته می‌شود و علاوه بر EXE، فایل `SHA256SUMS.txt` هم برای بررسی صحت دانلود ضمیمه می‌شود.

## امنیت و حریم خصوصی

برنامه URLهای موجود در Export را درخواست می‌کند و Redirect را دنبال می‌کند. فایل ورودی ناشناس می‌تواند URL شبکه داخلی یا سرویس خصوصی داشته باشد؛ برای Exportهای قابل‌اعتماد استفاده شود.

URLها ممکن است token امضاشده یا داده حساس در QueryString داشته باشند. فایل‌های runtime، لاگ، inventory، `all_urls.txt` و پوشه `_chat_attachment_manager` را در Repository عمومی Commit نکنید. `.gitignore` پروژه این موارد را پوشش می‌دهد.

## تست

`tests\StaticChecks.ps1` موارد زیر را بررسی می‌کند:

- Syntax فایل‌های PowerShell
- یکسان بودن EngineVersion
- نبودن محدودیت `*.txt`
- نبودن مسیر شخصی `C:\Users\...` داخل سورس
- وجود `all_urls.txt`
- سیم‌کشی Resume امن (`If-Range` / `Content-Range`)
- Cleanup و completion marker

CI ویندوزی این تست‌ها را اجرا می‌کند و Workflow جداگانه EXE را Build می‌کند. قبل از Stable Release بهتر است یک Smoke Test واقعی روی نسخه Windows/Windows Server هدف انجام شود.

## License

هنوز License انتخاب نشده است. قبل از Public کردن Repo، متناسب با نوع استفاده‌ای که اجازه می‌دهید MIT / Apache-2.0 / GPL-3.0 یا گزینه مناسب دیگری اضافه کنید.
