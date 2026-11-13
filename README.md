# Doki Standalone 2.9.0

ابزار مستقل بررسی سلامت لپ‌تاپ برای Windows 10/11.

[دانلود EXE نهایی](https://github.com/rezadadsetan/Doki/raw/refs/heads/main/releases/Doki-2.9.0.exe)

فقط همین EXE را اجرا کنید و UAC را تأیید کنید. فایل‌ها در Program Files\doki-standalone نصب می‌شوند؛ کنار دانلود فایلی ساخته نمی‌شود. گزارش‌ها محلی‌اند. ورود سازمانی، Jira، ارسال گزارش، آماده‌سازی سازمانی و آپدیت خودکار برنامه وجود ندارند.

قابلیت‌ها: سلامت و سیکل باتری، سلامت دیسک، درایورهای مشکل‌دار، Windows Update، تست فشار CPU/RAM/SSD/GPU، چک‌لیست دستی، گزارش HTML و JSON و سابقهٔ محلی. تست کیبورد گزینهٔ تأیید نبود بعضی کلیدها را دارد تا چیدمان‌های مختلف مانع انتخاب سالم نشوند.

این نسخه درجه‌های S/A+/A/B دارد؛ امکانات اختصاصی شرکت مثل گارانتی سازمانی و پنجرهٔ پایان سازمانی فعال نیستند. بررسی Windows Update ممکن است با مایکروسافت ارتباط بگیرد. GPU به Edge نیاز دارد. استفادهٔ آفلاین و گزارش محلی ممکن است. گزارش مهمان پیش‌فرض در Desktop\Doki Reports ذخیره می‌شود؛ مسیر واقعی در برنامه نمایش داده می‌شود.

## Development

Source scripts are under app/, standalone configuration under config/. Run Start.bat to use the source. Windows PowerShell 5.1 and .NET Framework are required. Native helper DLL is included with its C# sources. Run tools/Build-Exe.ps1 to produce dist/Doki-2.9.0.exe. The download under releases/ is the verified delivery; build output is separate.

Validation: organization wording/module/feature checks and installed payload hashes passed for the delivered EXE. Real UAC and physical keyboard/hardware checks remain manual. EXE is unsigned. No online account or API key is required.

Created by Reza Dadsetan.