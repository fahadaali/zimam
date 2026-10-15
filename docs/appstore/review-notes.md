# ملاحظات المراجعة (App Review Information)

تُلصق في **App Store Connect ← صفحة الإصدار ← App Review Information**، وفي **TestFlight ← Test Information** للمختبرين الخارجيين. فريق المراجعة يقرأ الإنجليزية، فالنص الملصوق بالإنجليزية، وشرحه هنا بالعربية.

## تسجيل الدخول: كيف يدخل المراجع

زمام لا يعمل إلا بحساب، والدخول بحساب أبل أو قوقل فقط، فلا اسم مستخدم وكلمة مرور خاصين بزمام. لذلك:

- **الطريقة الأساسية:** يدخل المراجع بـ Sign in with Apple بحساب أبل الذي على جهاز المراجعة. ينشئ ذلك حساب زمام جديداً فارغاً، ويستطيع حذفه من التطبيق بعد المراجعة. هذا ما يتوقعه المراجعون من تطبيق دخوله بأبل، ولا يحتاج منك شيئاً.
- **حساب تجريبي (احتياط):** إن طلبت المراجعة حساباً جاهزاً (الإرشاد 2.1)، أنشئ حساب Google مخصصاً للمراجعة، وأضف فيه بيانات تجريبية من التطبيق، ثم ضع بريده وكلمة مروره في **Sign-In Information** في App Store Connect فقط، لا في المستودع ولا في المحادثة. أطفئ فيه التحقق بخطوتين، وادخل به مرة من جهاز آخر قبل الإرسال حتى لا تطلب قوقل رمز تحقق من جهاز المراجع.
- اترك **Sign-in required** مفعّلاً، واكتب في خانتي المستخدم وكلمة المرور ما يناسب: بيانات الحساب التجريبي إن أنشأته، وإلا فاكتب في الملاحظات أن الدخول بأبل.

## الاشتراكات في المراجعة

- المراجع يشتري في بيئة sandbox من تطبيق يكلّم خادم الإنتاج، والخادم يقبل معاملات sandbox (`api/DEVELOPMENT.md`، «التحقق من الشراء»)، فلا خصم ولا إعداد منك.
- أرسل المنتجين `app.zimam.ios.pro.monthly` و`app.zimam.ios.pro.yearly` مع الإصدار نفسه، ومع كل منهما لقطة لصفحة «زمام الاحترافية» (`docs/setup.md`).
- اختر قبل الإرسال حال البوابة، واكتب السطر المناسب في الملاحظات أدناه:
  - إن بقي `SUBSCRIPTIONS_ENFORCED = "false"` فكل المزايا مفتوحة، والتطبيق يعرض الباقة ويسمح بالشراء دون أن يمنع شيئاً. اذكر ذلك صراحة حتى لا يُعدّ الشراء بلا فائدة.
  - إن فعّلتها (`"true"`) فالمساعد بعد حصته المجانية وربط كلود وChatGPT والاستيراد من الخادم تطلب الاشتراك.

## النص الملصوق (Notes، ٤٠٠٠ حرف على الأكثر)

احذف من السطرين بين المعقوفين ما لا ينطبق قبل اللصق.

```text
Zimam is an Arabic-first task manager for iPhone, iPad, Mac and Apple Watch, with a web app on the same account. The interface is in Arabic and right-to-left.

SIGN IN
Zimam needs an account to sync tasks. It offers Sign in with Apple and Sign in with Google only. Please use Sign in with Apple with the device's Apple Account: it creates a new, empty Zimam account. [A demo Google account with sample data is in Sign-In Information.]

WHAT TO TRY
Settings: tap the person icon (الحساب والمزامنة) at the top, then الإعدادات.
1. Add a task with the "إضافة مهمة" (+) button in Today or Upcoming. Type a sentence in Arabic such as "ذكرني أراجع العقد بعد المغرب يوم الخميس" (remind me to review the contract after Maghrib on Thursday) and tap the assistant suggestion: the server turns it into a task with a date and a prayer-linked reminder. You confirm before anything is saved.
2. Prayer times: in Settings > أوقات الصلاة, allow location. Prayer times are computed on the device. A task can be due "after Asr by 20 minutes" and moves with the prayer times.
3. Dates show in the Hijri (Umm al-Qura) and Gregorian calendars together. The Calendar tab has month and week views.
4. Sharing: open a project, then مشاركة المشروع, and create an invite link. A second account can join with it, then both see the project's tasks and comments.
5. Widgets, Lock Screen, the Live Activity for the current task, Siri and Shortcuts ("إضافة مهمة", "مهام اليوم"), and the Apple Watch app all read the same tasks.

PERMISSIONS
Location (optional): prayer times and location-based reminders. Microphone and speech recognition (optional): dictating a task. Reminders (optional): a one-time import of the lists the user picks. Notifications: task reminders.

SUBSCRIPTION
"Zimam Pro" (monthly and yearly auto-renewable subscriptions) adds the AI assistant quota, connecting Claude and ChatGPT through Zimam's MCP server, and importing from other apps. It is in Settings > الاشتراك. [During this review all features are open without a subscription; the paywall shows the plans and purchases work in the sandbox.] [Without a subscription, the assistant stops after its free monthly quota and shows the paywall.]

ACCOUNT DELETION
Settings > الحساب > حذف الحساب deletes the account and its data on the server and revokes Sign in with Apple.

SHARED CONTENT
Only people the project owner invites can see a shared project. The owner can remove a member or revoke an invite, and a member can leave the project.

The AI assistant runs on Zimam's server (Anthropic or DeepSeek models through Cloudflare AI Gateway); no API key is in the app.

Privacy policy: https://zimam-web.fahad2ao.workers.dev/privacy/
Terms: https://zimam-web.fahad2ao.workers.dev/terms/
```

الطول: ٢٧٣٠ حرفاً قبل حذف ما لا ينطبق.

- «revokes Sign in with Apple» صحيحة بعد إضافة سرّي `APPLE_KEY_ID` و`APPLE_PRIVATE_KEY` (`docs/setup.md`، «مفتاح Sign in with Apple»). دونهما يتم الحذف ولا يُلغى الربط عند أبل، وهذا شرط في الإرشاد 5.1.1(v)، فأضفهما قبل الإرسال.
- تحقق قبل اللصق من أن الأسماء العربية في النص (الإعدادات، أوقات الصلاة، مشاركة المشروع، الاشتراك، الحساب، حذف الحساب) ما زالت كما تظهر في التطبيق.

## معلومات التواصل

| الحقل | القيمة |
| --- | --- |
| First / Last Name | [اسم المالك] |
| Phone Number | [رقم بصيغة دولية، يتصل عليه المراجع عند الحاجة] |
| Email | [بريد التواصل نفسه في صفحة الخصوصية] |

## مرفق (اختياري)

فيديو قصير من شاشة الآيفون: الدخول، ثم إضافة مهمة بجملة، ثم ربطها بالصلاة، ثم صفحة الاشتراك، ثم حذف الحساب. يوفّر على المراجع البحث في واجهة عربية.
