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

1. **مخزن KV للرموز:** من **Storage & Databases ← KV ← Create**، باسم `zimam-oauth`. معرّفه (`b74ed41be5be43c4aa567d1c010dd4df`) في `mcp/wrangler.jsonc`.
2. **Workers Builds:** مشروع ثانٍ من نفس المستودع:

| الحقل | القيمة |
| --- | --- |
| Project name | `zimam-mcp` |
| Production branch | `main` |
| Root directory | `mcp` |
| Build command | فارغ |
| Deploy command | `npx wrangler deploy` |

3. **Sign in with Apple للويب:** في حساب المطوّر، افتح Services ID `app.zimam.ios.web`، وفعّل Sign in with Apple، واختر `app.zimam.ios` تطبيقاً أساسياً، وأضف:
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

2. **Sign in with Apple للويب:** في Services ID `app.zimam.ios.web` أضف:
   - Domain: `zimam-web.fahad2ao.workers.dev`
   - Return URL: `https://zimam-web.fahad2ao.workers.dev/app`

التفاصيل في `web/README.md`.

### ٧. الاستيراد: طابوران ومخزن R2 (قبل النشر التالي)

> **مهم:** أنشئ الطابورين `zimam-imports` و`zimam-imports-dlq` ومخزن R2 `zimam-imports` **قبل** دمج فرع الاستيراد إلى `main`. الخادم يربطها في `api/wrangler.jsonc`، فإن لم تكن موجودة فشل النشر التالي كله (لا الاستيراد وحده)، وبقي الخادم على نسخته السابقة حتى تُنشأ.

1. فعّل R2 في الحساب مرة واحدة إن لم يكن مفعّلاً: **Storage & Databases ← R2** ثم اتبع خطوات التفعيل (قد تطلب كلاودفلير وسيلة دفع وإن بقي الاستعمال في الحد المجاني).
2. من داخل `api/` (أو من لوحة كلاودفلير: **Storage & Databases ← Queues ← Create** و**R2 ← Create bucket** بالأسماء نفسها):

```sh
cd api
npx wrangler queues create zimam-imports --message-retention-period-secs 86400
npx wrangler queues create zimam-imports-dlq --message-retention-period-secs 86400
npx wrangler r2 bucket create zimam-imports
# شبكة أمان: أي ملف بقي في المخزن أكثر من ٧ أيام يُحذف (الخادم يحذفها عند انتهاء كل استيراد)
npx wrangler r2 bucket lifecycle add zimam-imports expire-leftovers --expire-days 7
```

3. لا شيء آخر: جدول `import_jobs` (`api/migrations/0006_imports.sql`) يطبّقه أمر النشر في Workers Builds تلقائياً، والمستهلك (consumer) معرّف في `wrangler.jsonc` فيُربط بالنشر.

- مدة الاحتفاظ يوم واحد لأن رمز Todoist الذي يلصقه المستخدم يمر في أول رسالة من الطابور فقط، فلا يبقى فيه أطول من ذلك إن تعطّل المستهلك. الرمز لا يُحفظ في قاعدة البيانات ولا في R2 ولا في السجلات.
- إن أردت أن ينشئها Claude من الجلسة السحابية (الخطوة ٤)، فأضف إلى رمز API صلاحيتي **Queues: Edit** و**Workers R2 Storage: Edit**.
- الطوابير متاحة في الخطة المجانية، لكن D1 فيها يسمح بـ ٥٠ استعلاماً فقط لكل تشغيل، والمستهلك يكتب ٥٠ عنصراً في التشغيل الواحد (`CHUNK_SIZE` في `api/src/imports/jobs.ts`) بنحو ١٠٠–٢٥٠ استعلاماً، وهذا يناسب خطة Workers المدفوعة (١٠٠٠ استعلام). على الخطة المجانية خفّض `CHUNK_SIZE` إلى ٥.

## أبل وXcode

### ١. حساب المطوّر

في [developer.apple.com](https://developer.apple.com/account) (بعد حسم: حساب شخصي أم كيان تجاري):

1. **Identifiers ← App IDs**: المعرّف `app.zimam.ios`، مع تفعيل Sign in with Apple وPush Notifications وApp Groups.
2. **Identifiers ← Services IDs**: المعرّف `app.zimam.ios.web` لتسجيل الدخول من الموقع، مع النطاق `zimam.app`.
3. **App Groups**: `group.app.zimam.ios` لمشاركة البيانات بين التطبيق والويدجت.

### المعرّفات الخاصة بالويدجت والساعة

مع التوقيع التلقائي ينشئ Xcode أغلبها عند أول بناء، لكن سجّلها بنفسك إن رفض التوقيع أو بنى Xcode Cloud قبل ذلك:

| النوع | المعرّف | الإمكانات |
| --- | --- | --- |
| App Group | `group.app.zimam.ios` | — |
| App ID (التطبيق) | `app.zimam.ios` | Sign in with Apple، وPush Notifications، وApp Groups مع اختيار `group.app.zimam.ios` |
| App ID (الويدجت) | `app.zimam.ios.widgets` | App Groups مع اختيار `group.app.zimam.ios` |
| App ID (الساعة) | `app.zimam.ios.watchkitapp` | لا شيء إضافي |

- الويدجت يعمل على الآيفون والآيباد والماك. على الماك يجب أن يكون App ID التطبيق والويدجت مفعّلاً لهما App Groups في ملف التوقيع، وإلا سأل النظام المستخدم عن السماح بالوصول إلى بيانات التطبيقات الأخرى.
- الساعة لا تحتاج App Group ولا مجموعة Keychain: تأخذ الجلسة من الآيفون عبر WatchConnectivity وتحفظها في Keychain الخاص بها.
- بعد الترقية يبدأ المخزن المحلي فارغاً في مجموعة التطبيقات، وتعيد أول مزامنة كل البيانات من الخادم.

### إشعارات الخادم (APNs)

التطبيق يجدول إشعارات الأيام الأربعة عشر القادمة على الجهاز، وما بعدها يرسله الخادم عبر APNs (التفاصيل في `api/DEVELOPMENT.md`). يحتاج ذلك مفتاحاً واحداً من حساب المطوّر:

1. **Identifiers ← App IDs ← `app.zimam.ios`**: فعّل **Push Notifications** واحفظ. لا حاجة لشهادات الإشعارات، فالخادم يستعمل المفتاح. يحدّث Xcode ملفات التوقيع في البناء التالي، والتطبيق يطلب الإمكانية بـ `aps-environment` في `apple/project.yml`.
2. **Keys ← +**: اسم مثل `Zimam APNs`، وفعّل **Apple Push Notification service (APNs)**، ومن **Configure** اختر البيئتين (Sandbox & Production) ونطاق الفريق، ثم **Continue ← Register**.
3. نزّل ملف `AuthKey_XXXXXXXXXX.p8` (يُنزَّل مرة واحدة فقط) وانسخ **Key ID** من صفحة المفتاح. احفظ الملف في مدير كلمات المرور، ولا تضعه في المستودع ولا ترسله في المحادثة.
4. من داخل `api/` أضف السرّين:

```sh
npx wrangler secret put APNS_KEY_ID                              # الصق Key ID
npx wrangler secret put APNS_PRIVATE_KEY < ~/Downloads/AuthKey_XXXXXXXXXX.p8
npx wrangler d1 migrations apply zimam --remote
```

أو شغّل `npx wrangler secret put APNS_PRIVATE_KEY` والصق محتوى الملف كاملاً مع سطري `BEGIN` و`END`. ثم احذف الملف من التنزيلات.

- معرّف الفريق `72V86SZ2XC` ليس سراً، وهو في `api/wrangler.jsonc` (`APNS_TEAM_ID`).
- بناء Xcode للتطوير يسجّل الجهاز في بيئة sandbox، وTestFlight وApp Store في production، والتطبيق يرسل البيئة مع الرمز.
- قبل إضافة السرّين يعمل الخادم عادياً ويتخطى الإرسال مع تحذير في السجل.

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

### ٥. مفتاح Sign in with Apple (لحذف الحساب)

تشترط مراجعة App Store (البند 5.1.1(v)) أن يُلغي حذفُ الحساب ربطَه بـ Sign in with Apple. يفعل الخادم ذلك بمفتاح من حسابك، ودونه يتم الدخول والحذف لكن لا يُلغى الربط عند Apple.

1. في [developer.apple.com](https://developer.apple.com/account): **Certificates, Identifiers & Profiles ← Keys ← +**.
2. سمّه `Zimam Sign in with Apple`، وفعّل **Sign in with Apple**، ثم **Configure** واختر `app.zimam.ios` معرّفاً أساسياً، ثم **Save ← Continue ← Register**.
3. نزّل ملف المفتاح `AuthKey_XXXXXXXXXX.p8`. يُنزَّل مرة واحدة فقط، فاحفظه في مكان آمن خارج المستودع. وانسخ **Key ID** (عشرة أحرف).
4. معرّف الفريق `72V86SZ2XC` موجود في `api/wrangler.jsonc` (`APPLE_TEAM_ID`)، وليس سراً. إن تغيّر الفريق فغيّره هناك.
5. من داخل `api/` أضف السرّين (لا يُلصقان في المحادثة ولا يدخلان المستودع):

```sh
cd api
npx wrangler secret put APPLE_KEY_ID          # الصق Key ID
npx wrangler secret put APPLE_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8   # نص الملف كاملاً مع سطري BEGIN وEND
```

المفتاح نفسه يخدم التطبيق (`app.zimam.ios`) والويب (`app.zimam.ios.web`) ما دام Services ID مربوطاً بالتطبيق الأساسي كما في خطوة خادم MCP. وللتطوير المحلي ضعهما في `api/.dev.vars` (لا يُرفع إلى المستودع)، والمفتاح في سطر واحد مع `\n` مكان فواصل الأسطر.

## طريقة العمل بعد الربط

- Claude في الجلسة السحابية يكتب الخادم والموقع وخادم MCP ويختبرها، ويكتب كود Swift ويرفعه.
- البناء والتشغيل على المحاكي واختبارات Swift على الماك (Claude Code مع Xcode MCP) أو Xcode Cloud.
- كل ميزة على فرع، ثم طلب دمج إلى `main`.
