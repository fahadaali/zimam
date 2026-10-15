# موقع زمام

صفحة التعريف بزمام وواجهة إدارة المهام من المتصفح، أصولاً ثابتة على Cloudflare Workers (`zimam-web`) بلا سكربت Worker وبلا إطار عمل ولا حزم تعمل في المتصفح.

- الموقع: `https://zimam-web.fahad2ao.workers.dev` (لاحقاً `https://zimam.app`).
- الواجهة البرمجية: `https://zimam.fahad2ao.workers.dev` (لاحقاً `https://api.zimam.app`)، ويختارها `public/app/lib/api.js` بحسب النطاق.

## الهيكل

| الملف | ما فيه |
| --- | --- |
| `public/index.html` | صفحة التعريف: الشعار، «خذ زمام يومك»، ما يميّز زمام، المنصات، وربط كلود وChatGPT |
| `public/app/` | تطبيق الويب على `/app/`: صفحة واحدة تتبدّل عروضها برابط `#` (`#/today`، `#/upcoming`، `#/projects`، `#/projects/<id>`، `#/inbox`، `#/search?q=`) |
| `public/app/main.js` | تسجيل الدخول، والعروض، وإضافة المهمة وإنجازها وحذفها |
| `public/app/lib/` | وحدات ES: التواريخ (`dates.js`)، والصلاة (`prayer.js`)، والأرقام، والمهام، والـ nonce، والواجهة البرمجية، والمكوّنات |
| `public/styles/` | أنماط مشتركة (`base.css`) وأنماط صفحة التعريف (`site.css`) |
| `public/_headers` | ترويسات الأمان وسياسة المحتوى (CSP) |
| `public/design/` | **مولَّد** من `../design` بالأمر `npm run build`، ولا يدخل git |
| `scripts/copy-design.mjs` | ينسخ `tokens.css` والخطوط والشعارات والأيقونات و`bundle.{js,css}` إلى `public/design/` بنفس مساراتها النسبية |
| `test/` | اختبارات Node للتواريخ والصلاة والمهام، دون شبكة |

### نظام التصميم

- الألوان والمسافات والزوايا والخط من `design/generated/tokens.css` فقط، والخصائص المنطقية فقط (لا left/right). الثيم الداكن من الرموز نفسها.
- المكوّنات المرجعية في `design/components/bundle.js` تحتاج React، فبُنيت مكافئاتها بـ DOM عادي في `public/app/lib/components.js` بنفس أسماء الأصناف، وتنسّقها `bundle.css` كما هي.
- المدّ والأحرف المرسلة في عنوان `hero` بصفحة التعريف فقط («خذ زمام يومـك»، بالصنف `zm-hero`)، ولا شيء منها في التطبيق.
- التواريخ بالهجري (أم القرى) والميلادي معاً، والتقويم الأساسي للمستخدم أولاً من `settings.calendar`، بفاصلة عربية «،» وأرقام هندية عربية، والقريب بكلمة: «اليوم»، «غداً»، «الخميس».

## الأوامر

كل الأوامر من داخل `web/`، وتحتاج Node 22 أو أحدث.

```sh
npx -y npm@11 install   # wrangler فقط، للتطوير والنشر
npm run build           # ينسخ ملفات التصميم إلى public/design/
npm test                # node --test
npx wrangler dev        # معاينة محلية على http://localhost:8787 (بعد npm run build)
npx wrangler deploy --dry-run
```

المعاينة المحلية تعرض الصفحات كاملة، لكن تسجيل الدخول والطلبات إلى الواجهة البرمجية لا تعمل من `localhost`: أبل لا تقبل إلا رابط العودة المسجّل، والواجهة البرمجية لا تقبل إلا الأصول في `ALLOWED_ORIGINS`.

## النشر (Workers Builds)

اربط المستودع بـ Worker اسمه `zimam-web`:

| الإعداد | القيمة |
| --- | --- |
| Root directory | `web` |
| Build command | `npm run build` |
| Deploy command | `npx wrangler deploy` |

بعدها كل دمج إلى `main` ينشر الموقع.

## تسجيل الدخول بحساب أبل

- Sign in with Apple JS بوضع النافذة المنبثقة، بمعرّف الخدمة `app.zimam.ios.web`، ورابط العودة `<الموقع>/app`.
- في حساب مطوّر أبل: **Identifiers ← Services IDs ← `app.zimam.ios.web` ← Configure**، أضف النطاق `zimam-web.fahad2ao.workers.dev` ورابط العودة:

  `https://zimam-web.fahad2ao.workers.dev/app`

  وعند الانتقال إلى النطاق: `zimam.app` و`https://zimam.app/app`.
- يولّد المتصفح nonce عشوائياً، ويرسل لأبل تجزئته SHA-256، ثم يرسل الـ nonce الخام مع رمز الهوية إلى `POST /v1/auth/apple` مع `device: "web"`، فيتحقق الخادم أن الرمز صدر لهذا الدخول نفسه. ويُتحقق كذلك من قيمة `state`.
- أصل الموقع مضاف إلى `ALLOWED_ORIGINS` في `api/wrangler.jsonc`، فإن تغيّر النطاق فأضفه هناك.

## تسجيل الدخول بحساب قوقل

- زرّنا «المتابعة بحساب قوقل» تحت «المتابعة بحساب أبل» بالمقاس والزوايا والخط نفسها، بحرف G الملوّن على خلفية بيضاء (رمادية داكنة في الثيم الداكن) كما تطلب Google، وبلا أي سكربت من Google. الضغط يفتح `https://accounts.google.com/o/oauth2/v2/auth` (`response_type=id_token`، `scope=openid email profile`، `prompt=select_account`) في نافذة منبثقة، ويرجع Google إلى `/app/google-callback` بالرمز في جزء الرابط بعد `#`. صفحة العودة (`public/app/google-callback.html` وسكربتها `google-callback.js`) تسلّم الرمز للصفحة التي فتحتها عبر `BroadcastChannel` من الأصل نفسه وعبر `postMessage` إن بقي الرابط بالنافذة الأم، ثم تُغلق. إن مُنعت النوافذ المنبثقة ذهبت الصفحة كلها إلى Google ورجعت إلى `/app/` فيكمل الدخول من `sessionStorage`. `state` عشوائي لكل ضغطة ويُتحقق منه عند العودة. المنطق الخالص في `public/app/lib/google.js` واختباره في `test/google.test.mjs`.
- معرّف عميل الويب في الثابت `GOOGLE_CLIENT_ID` أعلى `public/app/main.js` (ليس سراً)، وهو أيضاً في `GOOGLE_CLIENT_IDS` في `api/wrangler.jsonc`. إن فرغ الثابت اختفى الزر. وفي Google Cloud يجب أن يكون `https://zimam-web.fahad2ao.workers.dev/app/google-callback` ضمن **Authorized redirect URIs** لهذا العميل (`docs/setup.md`).
- كما في أبل: nonce عشوائي جديد لكل شاشة دخول ولكل محاولة، يُعطى Google تجزئته SHA-256، ويُرسل الخام مع رمز الهوية إلى `POST /v1/auth/google` مع `device: "web"`.
- إن طابق بريدُ Google المتحقَّق منه حساباً دخل بأبل دخل المستخدم الحساب نفسه (القاعدة في `api/DEVELOPMENT.md`).

### رمز الجلسة

يُحفظ رمز الجلسة في `localStorage` ويُرسل `Authorization: Bearer`. اختير على `sessionStorage` لأن كليهما يقرؤه أي سكربت يعمل في الأصل نفسه، فلا يزيد `sessionStorage` الأمان، بل يفرض تسجيل الدخول في كل تبويب. الحماية الفعلية:

- سياسة محتوى صارمة في `_headers`: لا سكربت مضمَّن ولا من طرف ثالث إلا سكربت أبل، ولا أنماط مضمَّنة، و`frame-ancestors 'none'`، و`connect-src` للواجهة البرمجية ولأبل فقط؛ لا شيء من Google في الصفحة. Trusted Types في وضع الإبلاغ فقط حتى يُتأكد من عمل سكربت أبل معها. صفحة العودة من Google لها سياسة أضيق: سكربتها فقط، بلا طلبات وبلا مُحيل (`Referrer-Policy: no-referrer`)، ومع Trusted Types مفروضة.
- الواجهة تُبنى بـ `textContent` و`createElement` فقط، ولا `innerHTML` في الكود.
- الرمز معتم ويُلغى من الخادم: «تسجيل الخروج» يحذفه من الخادم ومن المتصفح، وأي رد 401 يمسحه ويعيد إلى شاشة الدخول.
