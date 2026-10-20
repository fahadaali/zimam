# نشر زمام إلى TestFlight وApp Store

كل دمج إلى `main` يبني التطبيق في Xcode Cloud ويرفعه إلى TestFlight. هذه الوثيقة تشرح ما في المستودع لذلك، وما تعمله أنت مرة واحدة في Xcode وApp Store Connect. ونصوص صفحة المتجر وتفاصيل الخصوصية في `docs/appstore/`.

## ما في المستودع

| الملف | ما يفعله |
| --- | --- |
| `apple/ci_scripts/ci_post_clone.sh` | يعمل بعد أن ينسخ Xcode Cloud المستودع: ينزّل XcodeGen بإصدار مثبّت ويتحقق من بصمته، ثم يولّد `Zimam.xcodeproj` من `project.yml`، ثم يضع ملف `Package.resolved` في المشروع |
| `apple/ci_scripts/ci_pre_xcodebuild.sh` | يعمل قبل كل بناء: يضع رقم بناء Xcode Cloud (`CI_BUILD_NUMBER`) في `CURRENT_PROJECT_VERSION` |
| `apple/project.yml` | الإصدار `MARKETING_VERSION` ورقم البناء `CURRENT_PROJECT_VERSION`، وتقرؤهما ملفات Info.plist للأهداف الأربعة (التطبيق، والويدجت، والساعة، وتعقيداتها)، فلا يرفض App Store Connect إضافةً يختلف إصدارها عن التطبيق. ومعهما `ITSAppUsesNonExemptEncryption` |
| `PrivacyInfo.xcprivacy` في مجلد كل هدف | سبب استعمال `UserDefaults`، وهو شرط لقبول الرفع (الرسالة ITMS-91053)، وما يجمعه التطبيق |

### لماذا `ci_scripts` داخل `apple/`

يبحث Xcode Cloud عن مجلد `ci_scripts` بجانب المشروع، والمشروع `apple/Zimam.xcodeproj`. والمشروع لا يدخل المستودع (`.gitignore`) لأن `project.yml` هو المرجع، فيولّده Xcode Cloud في كل بناء:

1. ينسخ Xcode Cloud المستودع، ثم يشغّل `ci_post_clone.sh`.
2. ينزّل السكربت XcodeGen ‏2.46.0 من صفحة إصداراته في GitHub، ويرفض تشغيله إن لم تطابق بصمته SHA-256 المكتوبة فيه. اخترنا هذا بدل `brew install xcodegen` لأن Homebrew يثبّت أحدث إصدار، فيتغيّر المشروع المولَّد دون أن يتغيّر شيء في المستودع.
3. يولّد `Zimam.xcodeproj` ومعه المخطط المشترك «Zimam» (يتطلب Xcode Cloud أن يكون المخطط مشتركاً، وXcodeGen يضعه في `xcshareddata`).
4. يبني Xcode Cloud وحلّ الحزم معطّل في كل أوامر `xcodebuild`، حتى `-resolvePackageDependencies`، فيلزمه `Package.resolved`. ينسخ السكربت `apple/Package.resolved` إلى المشروع، ويتوقف بخطأ صريح إن لم يجده في المستودع.
5. قبل كل بناء يضع `ci_pre_xcodebuild.sh` رقم البناء في المشروع.

لتحديث XcodeGen: غيّر `XCODEGEN_VERSION` و`XCODEGEN_SHA256` معاً في `ci_post_clone.sh`. البصمة من `shasum -a 256 xcodegen.zip` بعد تنزيل الملف من صفحة الإصدار.

### الإصدار ورقم البناء

- **الإصدار** (`CFBundleShortVersionString`) من `MARKETING_VERSION` في `apple/project.yml`، وهو الآن `1.0.0` للإطلاق. ارفعه في طلب دمج مع كل إصدار جديد تُرسله للمراجعة (مثلاً `1.0.1` لإصلاح، و`1.1.0` لميزة).
- **رقم البناء** (`CFBundleVersion`) يضعه Xcode Cloud ويزيده في كل بناء. ولتبدأ من رقم معيّن: **App Store Connect ← Apps ← زمام ← Xcode Cloud ← Settings ← Build Number**. البناء المحلي في Xcode يبقى رقمه `1`.

## قبل أول بناء (مرة واحدة)

1. **المعرّفات والإمكانات:** سجّل في حساب المطوّر المعرّفات الأربعة ومجموعتي التطبيقات وإمكاناتها كما في `docs/setup.md` («أبل وXcode»)، ومعها Associated Domains. يوقّع Xcode Cloud تلقائياً، لكنه لا ينجح إن نقصت إمكانية يطلبها التطبيق.
2. **سجل التطبيق في App Store Connect:** **Apps ← + ← New App**:

| الحقل | القيمة |
| --- | --- |
| Platforms | iOS وmacOS (التطبيق نفسه للآيفون والآيباد والماك، فيُشترى مرة واحدة للجميع، والساعة تأتي مع تطبيق الآيفون) |
| Name | من `docs/appstore/listing.md` |
| Primary Language | Arabic |
| Bundle ID | `app.zimam.ios` |
| SKU | `zimam` (معرّف داخلي لا يظهر للناس) |
| User Access | Full Access |

3. **تثبيت إصدارات الحزم (إلزامي):** على الماك:

```sh
cd apple
xcodegen
open Zimam.xcodeproj        # انتظر حتى ينتهي Xcode من تنزيل الحزم، ثم ابنِ مرة
cp Zimam.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved
```

ثم ارفع `apple/Package.resolved` في طلب دمج. بعدها يبني Xcode Cloud بالإصدارات نفسها التي جرّبتها. وأعد الخطوة كلما أضفت حزمة في `project.yml` أو رفعت إصدارها، وإلا فشل البناء برسالة أن الملف قديم.

4. **مجموعة المختبرين الداخليين:** **App Store Connect ← Apps ← زمام ← TestFlight ← Internal Testing ← +**، باسم `الفريق`. التفاصيل في «إضافة المختبرين» أدناه.

## إنشاء سير العمل في Xcode

1. افتح المشروع المولَّد على الماك (`cd apple && xcodegen && open Zimam.xcodeproj`)، وتأكد أن حساب المطوّر مضاف في **Xcode ← Settings ← Accounts**.
2. **Product ← Xcode Cloud ← Create Workflow**، واختر المنتج **Zimam**، ثم **Next**.
3. يطلب Xcode ربط المستودع: **Grant Access** يفتح App Store Connect، فثبّت تطبيق Xcode Cloud على GitHub واسمح له بالمستودع `fahadaali/zimam` وحده. الحزم (GoogleSignIn-iOS ومتطلباتها، وadhan-swift) عامة، وأبل تنص على أن Xcode Cloud يصل إليها دون إذن. لكن المعالج قد يسرد مستودعاتها «Not connected» ويبقي **Next** معطّلاً، و**Connect** عليها يفشل لأنها ليست لك. حينها أنشئ سير العمل من نسخة مؤقتة بلا حزم، ولا تغيّر المستودع:

```sh
git clone https://github.com/fahadaali/zimam.git zimam-cloud-setup
cd zimam-cloud-setup/apple
perl -0pi -e 's/^packages:\n.*?(?=^targets:)//ms; s/^ *- package: GoogleSignIn\n *product: GoogleSignIn\n//mg; s/^ *- package: ZimamKit\n//mg; s/^    dependencies:\n(?=    settings:)//mg' project.yml
xcodegen && open Zimam.xcodeproj
```

المشروع الناتج لا يُبنى، ولا يلزمه، فالمعالج لا يبني شيئاً. وسير العمل يبني `main` بحزمه كلها. لا ترفع شيئاً من هذه النسخة، واحذفها بعد الحفظ.
4. في نافذة **Edit Workflow**:

| القسم | الإعداد |
| --- | --- |
| **General** | الاسم `TestFlight من main`، والمشروع `apple/Zimam.xcodeproj` كما يكتشفه Xcode. فعّل **Restrict Editing** إن أردت ألا يغيّره غيرك |
| **Environment** | **Xcode Version:** Latest Release، و**macOS Version:** Latest Release. وفعّل **Clean** ليبدأ كل بناء من الصفر، فبناء الإصدار لا يتأثر ببقايا بناء سابق |
| **Start Conditions** | احذف الشرط الافتراضي، وأضف **Branch Changes** بالفرع `main` وحده. ومن **Files and Folders** اختر «Start a build if any file changes in» المجلدين `apple/` و`design/`، لأن الدمج الذي يغيّر `api/` أو `web/` فقط لا يحتاج بناء التطبيق. وفعّل **Auto-cancel Builds**. ثم أضف شرطاً ثانياً **On a Schedule** للتجديد الأسبوعي، كما في «تجديد مدة TestFlight كل أسبوع» أدناه |
| **Actions** | **+ ← Archive**: Platform **iOS**، وScheme **Zimam**، وDistribution Preparation **App Store Connect**. ثم **+ ← Archive** ثانية: Platform **macOS**، والإعدادان نفسهما. واحذف إجراءات **Build** التي يضيفها المعالج: الأرشيف يبني التطبيق، والساعة تُبنى داخل أرشيف iOS |
| **Post-Actions** | **+ ← TestFlight Internal Testing**: Artifact من أرشيف iOS، والمجموعة `الفريق`. ثم مثلها لأرشيف macOS. المجموعة تُنشأ أولاً في App Store Connect (الخطوة ٤ في «قبل أول بناء»)، وإلا بقيت القائمة فارغة |

- **App Store Connect** (اسمه في Xcode القديم **TestFlight and App Store**) يتيح البناء نفسه للمختبرين الداخليين وللخارجيين وللمراجعة. أما **TestFlight (Internal Testing Only)** فلا يُرسل بناؤه للمراجعة ولا للمختبرين الخارجيين، فلا تختره إلا لسير عمل تجريبي منفصل.
- المخطط فيه هدف الاختبار `ZimamTests`، لكن سير العمل هذا للأرشيف فقط. إجراء **Test** يحتاج سير عمل منفصلاً لطلبات الدمج، ولم يُعدّ بعد.
- يرسل Xcode Cloud بريداً عند فشل البناء. ومن **Post-Actions ← Notify** تضيف بريداً آخر أو Slack.

5. **Save**، ثم **Start Build**. أول بناء أطول من غيره لأنه ينزّل الحزم. وتتابعه في Xcode من **Report Navigator ← Cloud**، أو في App Store Connect من **Xcode Cloud**.
6. بعد نجاح البناء يعالج App Store Connect الملف دقائق، ثم يظهر في **TestFlight** ويصل لمجموعة `الفريق`.

## تجديد مدة TestFlight كل أسبوع

كل بناء في TestFlight ينتهي بعد ٩٠ يوماً من رفعه، فيتوقف التطبيق عند المختبرين إن مرّت المدة دون دمج يغيّر `apple/` أو `design/`. لذلك يبني سير العمل نفسه `main` كل أسبوع ولو لم يتغيّر شيء، فيصل بناء جديد بمدة ٩٠ يوماً جديدة.

المؤقت في إعداد سير العمل على Xcode Cloud لا في المستودع، ولا يحتاج سراً ولا مفتاحاً. أضفه مرة واحدة:

1. في Xcode: **Report Navigator ← Cloud**، ثم انقر بالزر الأيمن على سير العمل `TestFlight من main` ← **Edit Workflow**. أو من App Store Connect: **Apps ← زمام ← Xcode Cloud ← Manage Workflows**.
2. في **Start Conditions** أبقِ شرط **Branch Changes**، واضغط **+ ← On a Schedule**:

| الحقل | القيمة |
| --- | --- |
| Source Branch | `main` |
| Frequency | **Weekly** |
| Day / Time | يوم ووقت هادئان، مثلاً الأحد الساعة ٣ فجراً بتوقيتك |

3. **Save**.

- البناء المجدول يمر بالخطوات نفسها: `ci_post_clone.sh`، ثم `ci_pre_xcodebuild.sh` يضع رقم بناء أكبر، ثم الأرشيفان والرفع لمجموعة `الفريق`. فلا يرفضه App Store Connect مع أن الإصدار `MARKETING_VERSION` لم يتغيّر.
- مع **Automatically distribute builds** في المجموعة (انظر «إضافة المختبرين») يصل البناء الأسبوعي للمختبرين الداخليين دون خطوة منك، ويحدّثه تطبيق TestFlight عندهم إن فعّلوا التحديث التلقائي.
- المختبرون الخارجيون لا يأخذون البناء تلقائياً: أضفه لمجموعتهم من **External Testing**، أو فعّل فيها **Automatically distribute builds** إن ظهر الخيار.
- ساعات Xcode Cloud محدودة في الاشتراك (٢٥ ساعة شهرياً في الباقة المجانية). بناء أسبوعي للأرشيفين يستهلك جزءاً صغيراً منها، وتتابع الاستهلاك في **App Store Connect ← Xcode Cloud ← Usage**.
- لإيقاف التجديد عند الإطلاق أو بعده: احذف شرط **On a Schedule** من سير العمل.

## إضافة المختبرين

### الداخليون (حتى ١٠٠، دون مراجعة)

1. يجب أن يكون المختبر مستخدماً في حسابك على App Store Connect: **Users and Access ← +**، ببريده ودور مثل **Marketing** أو **Developer**، ثم يقبل الدعوة من بريده.
2. **Apps ← زمام ← TestFlight ← Internal Testing ← الفريق ← Testers ← +**، واختره.
3. فعّل في المجموعة **Automatically distribute builds**؛ فكل بناء يرفعه Xcode Cloud يصل إليها دون خطوة منك.
4. يثبّت المختبر تطبيق **TestFlight** من App Store على الآيفون أو الآيباد أو الماك، ويفتح الدعوة من بريده بحساب أبل نفسه. تطبيق الساعة يُثبَّت مع تطبيق الآيفون من تطبيق Watch.

### الخارجيون (حتى ١٠٬٠٠٠، بعد مراجعة البيتا)

1. **TestFlight ← External Testing ← +**، باسم مثل `المختبرون`.
2. املأ **Test Information**: وصف البيتا، وبريد الملاحظات، وملاحظات المراجعة من `docs/appstore/review-notes.md`، وسياسة الخصوصية.
3. أضف بناءً إلى المجموعة. أول بناء لكل إصدار يمر بمراجعة البيتا (يوماً في الغالب)، وما بعده من الإصدار نفسه يصل مباشرة في أغلب الأحوال.
4. أضف المختبرين ببريدهم، أو فعّل **Public Link** وشاركه، مع حد لعدد من ينضم.

المشتريات في TestFlight تجريبية (sandbox) بلا خصم، كما في `docs/setup.md` («اشتراكات زمام الاحترافية»).

## عند الفشل

| ما تراه في السجل | السبب والحل |
| --- | --- |
| `ci_post_clone.sh: Permission denied` | السكربت فقد صلاحية التنفيذ: `chmod +x apple/ci_scripts/*.sh` ثم ارفعه |
| `xcodegen.zip does not match the pinned SHA-256` | الملف المنزّل غير المتوقع. لا تتجاوز الفحص: نزّل الملف بنفسك وقارن البصمة بصفحة الإصدار، ثم حدّث الإصدار والبصمة معاً |
| `a resolved file is required when automatic dependency resolution is disabled` أو أن `Package.resolved` قديم | ارفع `apple/Package.resolved` الحالي (الخطوة ٣ في «قبل أول بناء») |
| `Scheme "Zimam" is not shared` أو لا يجد المخطط | تأكد أن مفتاح `scheme` باقٍ تحت هدف `Zimam` في `project.yml` |
| أخطاء التوقيع (Provisioning profile, capability) | إمكانية في `project.yml` غير مفعّلة على App ID في حساب المطوّر (`docs/setup.md`) |
| `ITMS-90473` أو أن إصدار الإضافة لا يطابق التطبيق | هدف جديد في `project.yml` بلا `CFBundleShortVersionString` و`CFBundleVersion` المقروءين من الإعدادين |
| `ITMS-91053: Missing API declaration` | هدف جديد بلا `PrivacyInfo.xcprivacy`، أو واجهة جديدة تحتاج سبباً (انظر وثيقة أبل «Describing use of required reason API») |
| «Missing Compliance» في TestFlight | `ITSAppUsesNonExemptEncryption` غاب من Info.plist التطبيق؛ وهو في `project.yml` (`docs/appstore/listing.md`) |

## قبل إرسال إصدار للمراجعة

1. ارفع `MARKETING_VERSION` في `apple/project.yml` وادمجه، فيبني Xcode Cloud الإصدار الجديد.
2. أنشئ الإصدار في **App Store Connect ← Apps ← زمام ← (+) iOS App / macOS App**، والصق النصوص من `docs/appstore/listing.md`، وارفع لقطات `docs/appstore/screenshots.md`.
3. **App Privacy:** من `docs/appstore/privacy-label.md`. وراجع معه تقرير الخصوصية من Xcode: **Window ← Organizer ← Archives**، اختر الأرشيف ثم **Generate Privacy Report**، فهو يجمع ما تعلنه حزمة GoogleSignIn وغيرها.
4. **App Review Information:** من `docs/appstore/review-notes.md`.
5. أرفق منتجي الاشتراك بالإصدار من قسم **In-App Purchases and Subscriptions** في صفحة الإصدار، إن كان أول إصدار يعرضهما.
6. اختر البناء من TestFlight في قسم **Build**، ثم **Add for Review**.
