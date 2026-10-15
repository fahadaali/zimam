# خادم MCP لزمام

Cloudflare Worker يفتح زمام لكلود وChatGPT بإذن المستخدم. الرابط الذي يُضاف في كلود أو ChatGPT:

```
https://zimam-mcp.fahad2ao.workers.dev/mcp
```

## كيف يعمل الربط

1. يضيف المستخدم الرابط موصلاً مخصصاً، فيسجّل كلود أو ChatGPT نفسه تلقائياً (Dynamic Client Registration، أو Client ID Metadata Document).
2. تفتح صفحة `/authorize` بالعربية: اسم التطبيق الطالب، والجهة التي سيُرسل إليها الإذن، والصلاحيات (الاطلاع، والإضافة والتعديل).
3. يضغط «السماح وتسجيل الدخول بحساب أبل»، فتفتح نافذة أبل، أو زر Google تحت «أو السماح بالمتابعة بحساب قوقل» (Google Identity Services)، ويرجع رمز هوية يتحقق منه خادم زمام (`signInWithApple` أو `signInWithGoogle`). يُربط الرمز بهذه الصفحة وحدها: الـ nonce الذي يوقّعه المزوّدان هو تجزيء رمز الصفحة. خيار Google يظهر فقط إن ضُبط `GOOGLE_WEB_CLIENT_ID` في `wrangler.jsonc` (معرّف عميل الويب، ليس سراً)، ويجب أن يكون أصل الخادم ضمن **Authorized JavaScript origins** لهذا العميل في Google Cloud.
4. يُصدر `workers-oauth-provider` رمز وصول لهذا المستخدم، وتُحفظ الرموز في KV مجزّأة.

الصفحة لا تُضمَّن في إطار، ولا يُقبل النموذج من متصفح آخر (ملف تعريف مربوط بالمتصفح).

## الأدوات

| الأداة | ما تفعله | الصلاحية |
| --- | --- | --- |
| `get_agenda` | جدول يوم أو أكثر بالهجري والميلادي، مع أوقات الصلاة والمهام والمتأخرة | `tasks:read` |
| `list_tasks` | المهام حسب المشروع أو الحالة أو مدى التاريخ | `tasks:read` |
| `search_tasks` | البحث في العناوين والملاحظات والوسوم، بقواعد البحث العربي | `tasks:read` |
| `list_projects` | المشاريع ودور المستخدم وعدد المنجز | `tasks:read` |
| `create_task` | إضافة مهمة بتاريخها، أو مرتبطة بصلاة | `tasks:write` |
| `update_task` | التعديل والنقل والتأجيل وإعادة الفتح | `tasks:write` |
| `complete_task` | إنجاز مهمة | `tasks:write` |

أدوات الكتابة لا تظهر أصلاً لمنحة بلا `tasks:write`. كل عملية تمر عبر الواجهة البرمجية (`api/`) بنفس صلاحيات التطبيق، فتظهر تعديلات كلود في التطبيق مع المزامنة التالية.

## التطوير

```sh
cd mcp
npx -y npm@11 install
npm test           # مسار الربط كاملاً والأدوات، مع واجهة برمجية وهمية
npm run typecheck
```

| الملف | ما فيه |
| --- | --- |
| `src/index.ts` | `OAuthProvider`، وصفحة الموافقة، ونقطة `/mcp` بلا حالة (Streamable HTTP) |
| `src/consent.ts` | صفحات HTML بالعربية بمتغيرات `tokens.css` |
| `src/tools.ts` | تعريف الأدوات السبع وتعليمات الخادم للنموذج |
| `src/backend.ts` | شكل `ZimamService` في `api/src/service.ts`؛ يُحدَّث معه |

صفحات الموافقة تأخذ الشعار وخط ثمانية و`tokens.css` من مجلد `design/` مباشرة (`assets` في `wrangler.jsonc`)، والملف `design/.assetsignore` يستثني ما لا يحتاجه المتصفح.
