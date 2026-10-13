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
| Project name | `zimam` (يطابق `name` في `api/wrangler.jsonc`) |
| Production branch | `main` |
| Root directory | `api` |
| Build command | فارغ |
| Deploy command | `npx wrangler d1 migrations apply zimam --remote && npx wrangler deploy` |

بعدها كل دمج إلى `main` يطبّق تغييرات قاعدة البيانات ثم ينشر الخادم. وتُكرَّر الخطوة نفسها لاحقاً لـ `mcp/` و`web/`.

### ٣. النطاق

بعد حجز `zimam.app` على كلاودفلير: **Workers & Pages ← zimam ← Settings ← Domains & Routes ← Add ← Custom domain** بالقيمة `api.zimam.app`.

### ٤. (اختياري) تشغيل wrangler من جلسة Claude السحابية

لا يلزم ما دام النشر عبر Workers Builds. إن أردت أن ينشئ Claude الموارد أو يقرأ السجلات بنفسه:

1. أنشئ رمز API من **My Profile ← API Tokens** بصلاحيات Workers Scripts وD1 فقط.
2. في إعدادات بيئة الجلسة السحابية: أضف `api.cloudflare.com` إلى النطاقات المسموحة، وأضف المتغيرين `CLOUDFLARE_API_TOKEN` و`CLOUDFLARE_ACCOUNT_ID`.
3. لا تلصق الرمز في المحادثة أبداً.

### ٥. خادم MCP لكلود وChatGPT

1. **مخزن KV للرموز:** من **Storage & Databases ← KV ← Create**، باسم `zimam-oauth`. أرسل لـ Claude الـ **Namespace ID** ليضعه في `mcp/wrangler.jsonc`.
2. **Workers Builds:** مشروع ثانٍ من نفس المستودع:

| الحقل | القيمة |
| --- | --- |
| Project name | `zimam-mcp` |
| Production branch | `main` |
| Root directory | `mcp` |
| Build command | فارغ |
| Deploy command | `npx wrangler deploy` |

3. **Sign in with Apple للويب:** في حساب المطوّر، افتح Services ID `app.zimam.web`، وفعّل Sign in with Apple، واختر `app.zimam.Zimam` تطبيقاً أساسياً، وأضف:
   - Domain: `zimam-mcp.fahad2ao.workers.dev`
   - Return URL: `https://zimam-mcp.fahad2ao.workers.dev/authorize`
4. **الربط في كلود:** Settings ← Connectors ← Add custom connector، بالرابط `https://zimam-mcp.fahad2ao.workers.dev/mcp`. وفي ChatGPT: فعّل وضع المطوّر (Developer mode) من الإعدادات، ثم أضف موصلاً بنفس الرابط.

بعد حجز النطاق يصير الرابط `https://mcp.zimam.app/mcp`: غيّر `MCP_ORIGIN` في `mcp/wrangler.jsonc`، وأضف النطاق الجديد في Services ID.

### ٦. الموقع وتطبيق الويب

1. **Workers Builds:** مشروع ثالث من نفس المستودع:

| الحقل | القيمة |
| --- | --- |
| Project name | `zimam-web` |
| Production branch | `main` |
| Root directory | `web` |
| Build command | `npm run build` |
| Deploy command | `npx wrangler deploy` |

2. **Sign in with Apple للويب:** في Services ID `app.zimam.web` أضف:
   - Domain: `zimam-web.fahad2ao.workers.dev`
   - Return URL: `https://zimam-web.fahad2ao.workers.dev/app`

التفاصيل في `web/README.md`.

## أبل وXcode

### ١. حساب المطوّر

في [developer.apple.com](https://developer.apple.com/account) (بعد حسم: حساب شخصي أم كيان تجاري):

1. **Identifiers ← App IDs**: المعرّف `app.zimam.Zimam`، مع تفعيل Sign in with Apple وPush Notifications وApp Groups.
2. **Identifiers ← Services IDs**: المعرّف `app.zimam.web` لتسجيل الدخول من الموقع، مع النطاق `zimam.app`.
3. **App Groups**: `group.app.zimam` لمشاركة البيانات بين التطبيق والويدجت.

### المعرّفات الخاصة بالويدجت والساعة

مع التوقيع التلقائي ينشئ Xcode أغلبها عند أول بناء، لكن سجّلها بنفسك إن رفض التوقيع أو بنى Xcode Cloud قبل ذلك:

| النوع | المعرّف | الإمكانات |
| --- | --- | --- |
| App Group | `group.app.zimam` | — |
| App ID (التطبيق) | `app.zimam.Zimam` | Sign in with Apple، وPush Notifications، وApp Groups مع اختيار `group.app.zimam` |
| App ID (الويدجت) | `app.zimam.Zimam.widgets` | App Groups مع اختيار `group.app.zimam` |
| App ID (الساعة) | `app.zimam.Zimam.watchkitapp` | لا شيء إضافي |

- الويدجت يعمل على الآيفون والآيباد والماك. على الماك يجب أن يكون App ID التطبيق والويدجت مفعّلاً لهما App Groups في ملف التوقيع، وإلا سأل النظام المستخدم عن السماح بالوصول إلى بيانات التطبيقات الأخرى.
- الساعة لا تحتاج App Group ولا مجموعة Keychain: تأخذ الجلسة من الآيفون عبر WatchConnectivity وتحفظها في Keychain الخاص بها.
- بعد الترقية يبدأ المخزن المحلي فارغاً في مجموعة التطبيقات، وتعيد أول مزامنة كل البيانات من الخادم.

### ٢. الماك

```sh
brew install xcodegen
git clone https://github.com/fahadaali/zimam.git
cd zimam/apple
xcodegen          # يولّد Zimam.xcodeproj من project.yml
open Zimam.xcodeproj
```

المرجع هو `apple/project.yml`. المشروع المولَّد `Zimam.xcodeproj` يدخل المستودع معه حتى يجده Xcode Cloud، لكنه لا يُعدَّل يدوياً: أي تغيير في الأهداف أو الإعدادات يكون في `project.yml` ثم يُعاد تشغيل `xcodegen`. في Xcode اختر فريقك من **Signing & Capabilities** مرة واحدة.

### ٣. Claude Code على الماك مع Xcode

ليبني Claude التطبيق ويشغّل اختباراته من الماك، أضف خادم Xcode MCP من مجلد المستودع:

```sh
claude mcp add xcode -- xcrun mcpbridge
```

### ٤. Xcode Cloud

في Xcode: **Product ← Xcode Cloud ← Create Workflow**، واربطه بـ `fahadaali/zimam`، وابدأ البناء عند كل دمج إلى `main`، ثم ارفع البناء إلى TestFlight.

## طريقة العمل بعد الربط

- Claude في الجلسة السحابية يكتب الخادم والموقع وخادم MCP ويختبرها، ويكتب كود Swift ويرفعه.
- البناء والتشغيل على المحاكي واختبارات Swift على الماك (Claude Code مع Xcode MCP) أو Xcode Cloud.
- كل ميزة على فرع، ثم طلب دمج إلى `main`.
