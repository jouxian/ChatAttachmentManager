# بررسی فنی UNIVERSAL 1.4.0

این فایل جمع‌بندی بازبینی نسخه 1.2.2 FASTSCAN و تغییرات کم‌ریسکی است که برای نسخه GitHub/Release اعمال شده‌اند.

## مواردی که اصلاح شدند

### 1) خروجی TXT لینک‌ها
`all_urls.txt` در پایان Full Scan ساخته می‌شود و هر URL استخراج‌شده را در یک خط می‌نویسد. فایل هم‌زمان با Merge شدن cacheهای per-source ساخته می‌شود و برای تولیدش نیازی به Parse دوباره CSV نهایی نیست.

### 2) مصرف RAM Scanner
در نسخه قدیمی نگه‌داشتن تعداد زیادی row در حافظه می‌توانست روی Exportهای بسیار بزرگ فشار ایجاد کند. Scanner اکنون CSV و URL text را streaming می‌نویسد.

### 3) Hot loop Scanner
URL decoding/regex فقط روی خط دارای `http` اجرا می‌شود، Regex اصلی compiled است و clock/status check به‌جای هر خط با فاصله انجام می‌شود. برای پسوندهای متنی شناخته‌شده sanity sample نیز از 64 KiB به 8 KiB کاهش یافته است.

### 4) قطع اینترنت و Retry
بعد از ساخته‌شدن Inventory، خطاهای شبکه باعث اجرای دوباره Scanner نمی‌شوند. Supervisor مستقیماً Downloader را با exponential backoff (حداکثر 15 دقیقه) Retry می‌کند. Retry برای DNS/TLS/socket/HTTP transient و Crash child process ادامه پیدا می‌کند.

### 5) قطع برق / Restart ویندوز
- Scheduled Task در startup فعال است.
- checkpoint فایل‌های منبع کامل‌شده حفظ می‌شود.
- state هر URL روی دیسک است.
- partial download حفظ می‌شود.
- reservation شماره/مسیر فایل قبل از دانلود با Flush پایدار ثبت می‌شود.
- `.part` در حین دانلود دوره‌ای durable Flush می‌شود.

### 6) Resume امن‌تر فایل نیمه‌کاره
برای partial، ETag/Last-Modified نگه داشته می‌شود و در صورت امکان `If-Range` استفاده می‌شود. پاسخ 206 باید `Content-Range` مورد انتظار داشته باشد. اگر validator یا range ناسازگار باشد، partial به داده جدید چسبانده نمی‌شود و دانلود از صفر شروع می‌شود.

### 7) رشد checkpoint
`download_state.jsonl` append-only است تا Crash-safe باشد، اما در پایان pass نهایی یا وقتی از 128 MiB بزرگ‌تر شود Compact می‌شود و فقط آخرین state هر key نگه داشته می‌شود.

### 8) Cleanup پایان پروژه
فقط در پایان واقعاً موفق (بدون scan error و بدون transient/pending download) cacheهای قابل بازسازی حذف می‌شوند. state کوچک لازم برای idempotence و شماره‌گذاری باقی می‌ماند.

### 9) اجرای EXE
یک launcher واقعی Windows x64 با Go اضافه شده است. EXE Engineهای PowerShell همان Release را Embed می‌کند و کاربر نهایی فقط `ChatAttachmentManager.exe` را اجرا می‌کند. سورس PowerShell همچنان در GitHub قابل بررسی است.

### 10) آماده‌سازی GitHub
- مسیر شخصی `manager_recent.json` به LocalAppData منتقل شده است.
- `.gitignore` runtime state و URLهای حساس را exclude می‌کند.
- CI برای syntax/static checks وجود دارد.
- Workflow جداگانه EXE را می‌سازد و روی tagهای `v*` Release ایجاد می‌کند.

## مواردی که هنوز برای نسخه‌های بعدی ارزش بهبود دارند

### A) امنیت URL / SSRF — اولویت بالا برای ورودی غیرقابل‌اعتماد
Downloader هر HTTP(S) URL موجود در Export را درخواست می‌کند و Redirect را دنبال می‌کند. اگر فایل ورودی از منبع ناشناس باشد، URL می‌تواند به localhost، شبکه خصوصی یا cloud metadata اشاره کند. فعلاً این رفتار در `SECURITY.md` شفاف مستند شده است چون بعضی کاربران ممکن است واقعاً attachment خصوصی/داخلی داشته باشند. نسخه آینده بهتر است policy قابل تنظیم `BlockPrivateNetworks` داشته باشد و Redirect/DNS را قبل از هر hop بررسی کند.

### B) اجرای Scheduled Task با SYSTEM
این روش Resume بعد از reboot را ساده می‌کند ولی سطح دسترسی زیادی دارد. معماری آینده بهتر است Manager معمولی اجرا شود و فقط عملیات ثبت Task حداقل privilege لازم را بگیرد، یا Task تحت حساب کاربر اجرا شود.

### C) تعداد URL بسیار بزرگ
Downloader فعلاً Inventory و آخرین checkpointها را به ساختارهای حافظه وارد می‌کند. برای چند صد هزار URL معمولاً قابل مدیریت است، ولی برای چند میلیون URL بهتر است queue/state به SQLite یا storage disk-backed منتقل شود.

### D) دانلود موازی کنترل‌شده
Downloader عمداً ترتیبی است تا احتمال 429 و فشار به host کم شود. برای throughput بالاتر می‌توان در آینده concurrency کم و محدود به host (مثلاً 2 دانلود هم‌زمان، با rate limiter مشترک) اضافه کرد. این تغییر نیاز به بازطراحی thread-safe checkpoint/storage reservation دارد و برای 1.4 عمداً انجام نشده است.

### E) Resume وسط یک Source File
Scanner checkpoint را در سطح «فایل منبع کامل‌شده» نگه می‌دارد. اگر یک فایل منبع بسیار بزرگ وسط اسکن قطع شود، همان فایل از ابتدا اسکن می‌شود؛ فایل‌های قبلی دوباره اسکن نمی‌شوند. Resume line-level ممکن است، ولی باید context گفتگو، pending attachment marker و temp inventory نیز atomically checkpoint شوند.

### F) محدودیت حجم/فضای دیسک
فعلاً سقف دانلود یا minimum free-space guard وجود ندارد. برای استفاده عمومی‌تر گزینه‌های `MaxDownloadBytes` و `MinimumFreeDiskBytes` مفید خواهند بود.

### G) Long path ویندوز
نام فایل sanitize و کوتاه می‌شود، اما اگر خود Output path بسیار طولانی باشد هنوز امکان برخورد با محدودیت path در سیستم‌هایی که Long Paths فعال نیست وجود دارد.

## نتیجه

نسخه 1.4 برای همان معماری PowerShell 5.1 نسبت به 1.2.2 در سه بخش اصلی بهتر شده است: سرعت Scanner، Resume/Recovery، و تجربه Release با EXE. بزرگ‌ترین بهبود معماری بعدی، اگر پروژه بخواهد از آرشیوهای چندمیلیون URL یا ورودی غیرقابل‌اعتماد پشتیبانی کند، انتقال state/queue به SQLite و اضافه‌کردن policy شبکه/SSRF خواهد بود.
