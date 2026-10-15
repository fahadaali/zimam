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
| App Group (الساعة) | `group.app.zimam.ios.watch` | — |
| App ID (التطبيق) | `app.zimam.ios` | Sign in with Apple، وPush Notifications، وApp Groups مع اختيار `group.app.zimam.ios` |
| App ID (الويدجت) | `app.zimam.ios.widgets` | App Groups مع اختيار `group.app.zimam.ios` |
| App ID (الساعة) | `app.zimam.ios.watchkitapp` | App Groups مع اختيار `group.app.zimam.ios.watch` |
| App ID (تعقيدات الساعة) | `app.zimam.ios.watchkitapp.widgets` | App Groups مع اختيار `group.app.zimam.ios.watch` |

- الويدجت يعمل على الآيفون والآيباد والماك. على الماك يجب أن يكون App ID التطبيق والويدجت مفعّلاً لهما App Groups في ملف التوقيع، وإلا سأل النظام المستخدم عن السماح بالوصول إلى بيانات التطبيقات الأخرى.
- الساعة لا تحتاج مجموعة Keychain: تأخذ الجلسة من الآيفون عبر WatchConnectivity وتحفظها في Keychain الخاص بها. ومجموعة `group.app.zimam.ios.watch` خاصة بها (لا تعبر إلى الآيفون): يكتب فيها تطبيق الساعة ما تعرضه التعقيدات.
- النشاط الحي «المهمة الجارية» لا يحتاج إمكانية في App ID: يكفي `NSSupportsLiveActivities` في Info.plist التطبيق (من `project.yml`)، وواجهته في هدف الويدجت `app.zimam.ios.widgets`.
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

### ٦. الروابط العامة (روابط الدعوة تفتح التطبيق)

رابط الدعوة `https://zimam-web.fahad2ao.workers.dev/join/#<code>` يفتح التطبيق مباشرة إن كان مثبتاً، ويفتح صفحة الدعوة في المتصفح إن لم يكن. يحتاج ذلك ثلاثة أشياء، اثنان منها في المستودع:

1. **في حساب المطوّر (خطوتك):** **Identifiers ← App IDs ← `app.zimam.ios`**، فعّل **Associated Domains** واحفظ. يحدّث Xcode ملفات التوقيع في البناء التالي. دون هذه الخطوة يرفض التوقيع الإمكانية `com.apple.developer.associated-domains`.
2. **في التطبيق:** `apple/project.yml` يضيف `applinks:zimam-web.fahad2ao.workers.dev` إلى إمكانات التطبيق، ثم `xcodegen`. ويفتح `App/InviteLinks.swift` شاشة «الانضمام بدعوة» بالرمز. وزر «فتح في التطبيق» في صفحة الدعوة يستعمل `zimam://join/<code>`، لأن Safari لا يفتح التطبيق من رابط عام إلى الموقع نفسه.
3. **في الموقع:** `web/public/.well-known/apple-app-site-association` يذكر `72V86SZ2XC.app.zimam.ios` والمسارين `/join` و`/join/*`، وينشر مع الموقع بنوع `application/json`.

للتحقق بعد النشر:

```sh
curl -sI https://zimam-web.fahad2ao.workers.dev/.well-known/apple-app-site-association   # 200 وContent-Type: application/json
curl -s https://app-site-association.cdn-apple.com/a/v1/zimam-web.fahad2ao.workers.dev  # ما تراه أبل (يتأخر حتى يوم)
```

ثم من الملاحظات أو الرسائل على آيفون فيه بناء جديد، اضغط رابط دعوة. أبل تقرأ الملف عند تثبيت التطبيق أو تحديثه، فإن تغيّر الملف فاحذف التطبيق وثبّته من جديد للتجربة. وللتطوير يمكن إضافة `?mode=developer` إلى النطاق في `project.yml` مع تفعيل **Associated Domains Development** في إعدادات المطوّر على الجهاز.

**عند الانتقال إلى `zimam.app`:** تتغيّر أربعة أماكن معاً: `applinks:zimam.app` في `apple/project.yml`، و`ZimamWeb.origin` في `apple/ZimamKit/Sources/ZimamKit/ZimamWeb.swift`، و`INVITE_URL` في `api/src/routes/members.ts`، ويُنشر الملف نفسه على `https://zimam.app/.well-known/apple-app-site-association`. أبقِ النطاق القديم في `project.yml` مدة حتى لا تتعطل الدعوات المرسلة قبل الانتقال (صالحة سبعة أيام)، و`InviteCode` يقرأ الرابطين.

### ٧. سياسة الخصوصية وشروط الاستخدام

الصفحتان `web/public/privacy/` و`web/public/terms/` **مسودتان** كُتبتا من الكود، وفي أعلى كل منهما تنبيه بذلك. قبل الإطلاق:

1. راجعهما مع مستشار قانوني، واملأ ما بين المعقوفين: البريد الإلكتروني للتواصل، واسم المشغّل (شخص أم كيان تجاري)، وموقع تخزين البيانات، ومدة سجلات بوابة الذكاء الاصطناعي، وبنود السن والمسؤولية والنظام الواجب التطبيق. ثم احذف التنبيه وصنف `placeholder`.
2. في App Store Connect: **App Privacy ← Privacy Policy URL** بالقيمة `https://zimam-web.fahad2ao.workers.dev/privacy/` (لاحقاً `https://zimam.app/privacy/`)، واملأ «تفاصيل الخصوصية» بما تذكره السياسة. وإن اعتمدت شروطاً خاصة بدل اتفاقية أبل القياسية فضع رابط `/terms/` في **License Agreement**.
3. أي تغيير فيما يجمعه الخادم أو يرسله (حقل جديد، مزوّد جديد) يُحدَّث معه نص السياسة في الطلب نفسه.

### ٨. اشتراكات «زمام الاحترافية»

الاشتراك عبر StoreKit 2 في مجموعة واحدة بمنتجين، شهري وسنوي. التطبيق يشتري، والخادم يتحقق من كل معاملة بسؤال Apple بمفتاح In-App Purchase، ويستقبل إشعارات التجديد والانتهاء والاسترداد. التفاصيل في `api/DEVELOPMENT.md` («الاشتراكات»).

> **في التجربة الشخصية:** المزايا مفتوحة للجميع (`SUBSCRIPTIONS_ENFORCED = "false"` في `api/wrangler.jsonc`)، والتطبيق يعرض الباقة ولا يمنع شيئاً، والمشتريات من TestFlight تجريبية (sandbox) بلا خصم.

#### ١. الاتفاقية

في [App Store Connect](https://appstoreconnect.apple.com): **Business ← Agreements**، وفعّل **Paid Applications** مع بيانات البنك والضريبة. دونها لا تظهر المنتجات في التطبيق ولو في sandbox.

#### ٢. مجموعة الاشتراك والمنتجان

**Apps ← زمام ← Monetization ← Subscriptions**:

1. **Subscription Groups ← +**: الاسم المرجعي `Zimam Pro`، ثم من **Localization** أضف العربية باسم العرض `زمام الاحترافية`.
2. داخل المجموعة **Create** مرتين، بالمستوى نفسه (Level 1) فيكون التبديل بينهما عند التجديد:

| Reference Name | Product ID | Duration | الاسم بالعربية | الوصف (٤٥ حرفاً على الأكثر) |
| --- | --- | --- | --- | --- |
| `Zimam Pro Monthly` | `app.zimam.ios.pro.monthly` | 1 Month | `زمام الاحترافية الشهري` | `المساعد الذكي وMCP والاستيراد الكامل` |
| `Zimam Pro Yearly` | `app.zimam.ios.pro.yearly` | 1 Year | `زمام الاحترافية السنوي` | `المساعد الذكي وMCP والاستيراد الكامل` |

3. **Subscription Prices**: الأسعار تُحدَّد هنا وحدها (السعودية أساساً، ويحسب App Store بقية الدول). التطبيق يعرض السعر كما يعطيه App Store (`displayPrice`) بعملة حساب المستخدم وأرقامه، فلا سعر مكتوب في الكود. والأسعار في `Zimam.storekit` للتجربة المحلية فقط.
4. **Family Sharing**: اتركه مطفأً؛ الخادم يربط الاشتراك بحساب زمام من اشتراه.
5. **Review Information**: لقطة شاشة لصفحة «زمام الاحترافية» في التطبيق، وملاحظة للمراجع. يُرسل المنتجان للمراجعة مع أول إصدار يعرضهما.
6. تشترط المراجعة رابطي الشروط والخصوصية للاشتراكات المتجددة: **App Privacy ← Privacy Policy URL** هو `https://zimam-web.fahad2ao.workers.dev/privacy`، والشروط `https://zimam-web.fahad2ao.workers.dev/terms` في وصف التطبيق أو في **App Information ← License Agreement**. وهما الرابطان في صفحة الاشتراك في التطبيق.

#### ٣. مفتاح In-App Purchase والأسرار الثلاثة

1. **Users and Access ← Integrations ← In-App Purchase ← Generate In-App Purchase Key** (أو **+**)، باسم مثل `Zimam Server`.
2. نزّل الملف `SubscriptionKey_XXXXXXXXXX.p8` (يُنزَّل مرة واحدة فقط) واحفظه خارج المستودع، وانسخ **Key ID** من السطر و**Issuer ID** من أعلى الصفحة.
3. من داخل `api/` (لا تُلصق في المحادثة ولا تدخل المستودع):

```sh
cd api
npx wrangler secret put APPSTORE_KEY_ID                 # الصق Key ID
npx wrangler secret put APPSTORE_ISSUER_ID              # الصق Issuer ID
npx wrangler secret put APPSTORE_PRIVATE_KEY < SubscriptionKey_XXXXXXXXXX.p8
```

جدول `entitlements` (`api/migrations/0009_subscriptions.sql`) يطبّقه النشر في Workers Builds. وقبل إضافة الأسرار يرد الخادم على التحقق من الشراء بـ 503، ويبقى الاشتراك محفوظاً عند Apple فيرسله التطبيق مرة أخرى عند فتح الإعدادات أو صفحة الاشتراك.

#### ٤. إشعارات الخادم (App Store Server Notifications V2)

**Apps ← زمام ← App Information ← App Store Server Notifications**: في **Production Server URL** و**Sandbox Server URL** كليهما:

```
https://zimam.fahad2ao.workers.dev/v1/subscriptions/apple/notifications
```

واختر **Version 2**. الخادم لا يصدّق محتوى الإشعار، بل يسأل Apple عن المعاملة نفسها. وعند الانتقال إلى `api.zimam.app` غيّر الرابطين.

#### ٥. التجربة

- **في Xcode:** مخطط `Zimam` يشغّل التطبيق بملف `apple/Zimam/Resources/Zimam.storekit` (`storeKitConfiguration` في `apple/project.yml`)، فيشتري محلياً دون حساب ولا خادم، ويدار من **Debug ← StoreKit ← Manage Transactions**. هذه المعاملات لا يعرفها App Store، فيرد الخادم عليها 404 ويعتمد التطبيق على استحقاق الجهاز. لتجربة الخادم: **Product ← Scheme ← Edit Scheme ← Run ← Options ← StoreKit Configuration: None**، ثم حساب sandbox.
- **حساب sandbox:** **Users and Access ← Sandbox ← Test Accounts ← +**، ثم على الجهاز **الإعدادات ← App Store ← Sandbox Account**. وفي TestFlight يشتري المختبر بحسابه دون خصم، وتتجدد الاشتراكات بسرعة.
- **التحقق:** `GET /v1/subscriptions` بعد الشراء يرجع `plan: "pro"` و`environment: "sandbox"`.

#### ٦. تفعيل البوابة بعد التجربة

1. ضع معرّفك في `PRO_USERS` في `api/wrangler.jsonc` (من `GET /v1/me`، أو بريدك) لتبقى مزاياك مفتوحة دون اشتراك.
2. غيّر `SUBSCRIPTIONS_ENFORCED` إلى `"true"` وادمج إلى `main`. بعدها يحتاج المساعد وخادم MCP والاستيراد من الخادم إلى الاشتراك، ويعرض التطبيق صفحة الاشتراك لمن يحتاجها. تذكيرات أبل والمهام وبقية التطبيق تبقى مجانية.

## الدخول بحساب قوقل

يدخل المستخدم بحساب أبل أو قوقل في التطبيق والويب وصفحة ربط كلود وChatGPT. أبل يبقى موجوداً دائماً (البند 4.8 من إرشادات App Store)، ومن دخل بأبل ثم بقوقل ببريد متحقَّق منه نفسه وجد حسابه نفسه (القاعدة وحدودها في `api/DEVELOPMENT.md`، «تسجيل الدخول»).

> **الحالة:** أُنجزت الخطوات أدناه، والمعرّفان مضبوطان في المستودع. تبقى هنا مرجعاً إن أُعيد إنشاء المشروع أو تغيّر نطاق.

### ١. مشروع Google Cloud

1. أنشئ مشروعاً من [console.cloud.google.com/projectcreate](https://console.cloud.google.com/projectcreate) باسم `zimam`.
2. **Google Auth Platform ← Branding:** اسم التطبيق `زمام`، وبريد الدعم، وشعار زمام إن أردت (الشعار يتطلب مراجعة Google، فاتركه إن لم يلزم).
3. **Audience:** اختر **External**، ثم **Publish app** لينتقل إلى **In production**. ما دام في وضع الاختبار لا يدخل إلا المستخدمون المضافون يدوياً.
4. **Data Access:** لا تضف أي نطاق. زمام يطلب `openid` و`email` و`profile` فقط، وهي لا تحتاج تحققاً من Google.

### ٢. عملاء OAuth

من [console.cloud.google.com/auth/clients](https://console.cloud.google.com/auth/clients) ← **Create client**:

| النوع | الإعداد | المعرّف |
| --- | --- | --- |
| iOS | Bundle ID: `app.zimam.ios` (يخدم الآيفون والآيباد والماك) | `404741015373-r3p4od9ko0qd99hocpg3r7gv1arju4ge.apps.googleusercontent.com` |
| Web application | Authorized JavaScript origins: `https://zimam-web.fahad2ao.workers.dev` و`https://zimam-mcp.fahad2ao.workers.dev`، وAuthorized redirect URIs كما في الجدول التالي | `404741015373-ukucah8482ofiuvd9lb4cn4pgqvnfm75.apps.googleusercontent.com` |

#### روابط العودة (Authorized redirect URIs) لعميل الويب

> **خطوة جديدة لم تُنجز بعد:** بدونها يتوقف زر قوقل في الموقع وفي صفحة الربط.

زر قوقل في الموقع وفي صفحة ربط كلود وChatGPT زرّنا نحن، يفتح صفحة الدخول من Google (`https://accounts.google.com/o/oauth2/v2/auth`، برمز هوية فقط) في نافذة منبثقة، أو في الصفحة نفسها إن مُنعت النوافذ المنبثقة، ثم يرجع Google إلى صفحة صغيرة في نطاقنا تسلّم الرمز. أضف هذين الرابطين حرفياً في **Clients ← عميل الويب ← Authorized redirect URIs**، وإلا رفض Google الدخول بالخطأ `redirect_uri_mismatch`:

| الموضع | الرابط |
| --- | --- |
| الموقع (`web/public/app/google-callback.html`) | `https://zimam-web.fahad2ao.workers.dev/app/google-callback` |
| صفحة ربط كلود وChatGPT (`mcp/src/consent.ts`، المسار `GET /google-callback`) | `https://zimam-mcp.fahad2ao.workers.dev/google-callback` |

- الرابط بلا `.html` ولا شرطة في آخره، كما يبنيه الكود من أصل الصفحة.
- قد يأخذ Google دقائق قليلة قبل أن يقبل الرابط الجديد.

معرّف العميل ليس سراً، ولا يوجد سر عميل لهذين النوعين في هذا الاستعمال (الخادم يتحقق من رمز الهوية بمفاتيح Google العامة). إن أنشأ Google سراً لعميل الويب فلا ترسله ولا تضعه في أي مكان.

### ٣. أين وُضع المعرّفان

| المكان | القيمة |
| --- | --- |
| `api/wrangler.jsonc` ← `GOOGLE_CLIENT_IDS` | معرّف iOS ثم معرّف الويب، بفاصلة |
| `mcp/wrangler.jsonc` ← `GOOGLE_WEB_CLIENT_ID` | معرّف الويب |
| `web/public/app/main.js` ← `GOOGLE_CLIENT_ID` | معرّف الويب |
| `apple/project.yml` ← `GOOGLE_IOS_CLIENT_ID` و`GOOGLE_REVERSED_CLIENT_ID` | معرّف iOS، وصيغته المعكوسة `com.googleusercontent.apps.404741015373-r3p4od9ko0qd99hocpg3r7gv1arju4ge` (نوع الرابط الذي يرجع إليه Google) |

- تفريغ أي قيمة يخفي زر قوقل في مكانها، وتفريغ `GOOGLE_CLIENT_IDS` يوقف `POST /v1/auth/google` (503).
- جدول `identities` (`api/migrations/0008_identities.sql`) يطبّقه أمر النشر في Workers Builds تلقائياً، وينقل إليه كل حسابات أبل الحالية.
- عند الانتقال إلى `zimam.app`: أضف `https://zimam.app` و`https://mcp.zimam.app` إلى Authorized JavaScript origins لعميل الويب، و`https://zimam.app/app/google-callback` و`https://mcp.zimam.app/google-callback` إلى Authorized redirect URIs.
- بعد تعديل `project.yml` شغّل `xcodegen`. أول بناء ينزّل حزمة GoogleSignIn-iOS (الإصدار 9.2.0 فما فوق ضمن 9.x).

## طريقة العمل بعد الربط

- Claude في الجلسة السحابية يكتب الخادم والموقع وخادم MCP ويختبرها، ويكتب كود Swift ويرفعه.
- البناء والتشغيل على المحاكي واختبارات Swift على الماك (Claude Code مع Xcode MCP) أو Xcode Cloud.
- كل ميزة على فرع، ثم طلب دمج إلى `main`.
