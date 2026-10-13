# ربط زمام بكلاودفلير وXcode

خطوات تُعمل مرة واحدة. ما يحتاج حسابك أو جهازك تعمله أنت، والباقي في المستودع.

## كلاودفلير

### ١. قاعدة البيانات

1. في لوحة كلاودفلير: **Storage & Databases ← D1 ← Create database**، باسم `zimam`.
2. انسخ **Database ID** وضعه مكان الأصفار في `api/wrangler.jsonc` (حقل `database_id`)، أو أرسله لـ Claude ليضعه. المعرّف ليس سراً.

موقع تخزين البيانات من القرارات المفتوحة في `docs/idea.md` (نظام حماية البيانات الشخصية)؛ اختر موقع القاعدة بعد حسمه، لأنه لا يتغير بعد الإنشاء.

### ٢. النشر التلقائي (Workers Builds)

1. **Workers & Pages ← Create ← Import a repository**، واختر `fahadaali/zimam`.
2. الإعدادات:

| الحقل | القيمة |
| --- | --- |
| Project name | `zimam-api` (يطابق `name` في `api/wrangler.jsonc`) |
| Production branch | `main` |
| Root directory | `api` |
| Build command | فارغ |
| Deploy command | `npx wrangler d1 migrations apply zimam --remote && npx wrangler deploy` |

بعدها كل دمج إلى `main` يطبّق تغييرات قاعدة البيانات ثم ينشر الخادم. وتُكرَّر الخطوة نفسها لاحقاً لـ `mcp/` و`web/`.

### ٣. النطاق

بعد حجز `zimam.app` على كلاودفلير: **Workers & Pages ← zimam-api ← Settings ← Domains & Routes ← Add ← Custom domain** بالقيمة `api.zimam.app`.

### ٤. (اختياري) تشغيل wrangler من جلسة Claude السحابية

لا يلزم ما دام النشر عبر Workers Builds. إن أردت أن ينشئ Claude الموارد أو يقرأ السجلات بنفسه:

1. أنشئ رمز API من **My Profile ← API Tokens** بصلاحيات Workers Scripts وD1 فقط.
2. في إعدادات بيئة الجلسة السحابية: أضف `api.cloudflare.com` إلى النطاقات المسموحة، وأضف المتغيرين `CLOUDFLARE_API_TOKEN` و`CLOUDFLARE_ACCOUNT_ID`.
3. لا تلصق الرمز في المحادثة أبداً.

## أبل وXcode

### ١. حساب المطوّر

في [developer.apple.com](https://developer.apple.com/account) (بعد حسم: حساب شخصي أم كيان تجاري):

1. **Identifiers ← App IDs**: المعرّف `app.zimam.Zimam`، مع تفعيل Sign in with Apple وPush Notifications وApp Groups.
2. **Identifiers ← Services IDs**: المعرّف `app.zimam.web` لتسجيل الدخول من الموقع، مع النطاق `zimam.app`.
3. **App Groups**: `group.app.zimam` لمشاركة البيانات بين التطبيق والويدجت والساعة.

### ٢. الماك

```sh
brew install xcodegen
git clone https://github.com/fahadaali/zimam.git
cd zimam/apple
xcodegen          # يولّد Zimam.xcodeproj من project.yml
open Zimam.xcodeproj
```

ملف المشروع `Zimam.xcodeproj` يُولَّد ولا يدخل المستودع؛ أي تعديل على الأهداف أو الإعدادات يكون في `apple/project.yml` ثم يُعاد تشغيل `xcodegen`. في Xcode اختر فريقك من **Signing & Capabilities** مرة واحدة.

### ٣. Claude Code على الماك مع Xcode

ليبني Claude التطبيق ويشغّل اختباراته من الماك، أضف خادم Xcode MCP من مجلد المستودع:

```sh
claude mcp add xcode -- xcrun mcpbridge
```

### ٤. Xcode Cloud

في Xcode: **Product ← Xcode Cloud ← Create Workflow**، واربطه بـ `fahadaali/zimam`، وابدأ البناء عند كل دمج إلى `main`، ثم ارفع البناء إلى TestFlight. يحتاج سكربت `ci_scripts/ci_post_clone.sh` يثبّت XcodeGen ويولّد المشروع، وسيُضاف مع `project.yml`.

## طريقة العمل بعد الربط

- Claude في الجلسة السحابية يكتب الخادم والموقع وخادم MCP ويختبرها، ويكتب كود Swift ويرفعه.
- البناء والتشغيل على المحاكي واختبارات Swift على الماك (Claude Code مع Xcode MCP) أو Xcode Cloud.
- كل ميزة على فرع، ثم طلب دمج إلى `main`.
