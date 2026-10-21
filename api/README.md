# الواجهة البرمجية لزمام

Cloudflare Worker يخدم التطبيق والموقع: الحسابات، والمزامنة، والمهام المشتركة، والاستيراد، وطلبات المساعد الذكي، وإشعارات APNs.

- قاعدة البيانات: D1، والمزامنة اللحظية للمهام المشتركة: Durable Objects.
- الاستيراد من Todoist وGoogle Tasks وGoogle Calendar وTickTick وMicrosoft To Do وNotion وTrello وAsana: Queues، بمحوّل منفصل لكل مصدر.
- المساعد الذكي: عبر Cloudflare AI Gateway إلى كلود أو DeepSeek.
- مرفقات المهام: R2 (المخزن `zimam-attachments`، ويُنشأ قبل النشر).
- الأسرار عبر `wrangler secret put` فقط، ونسخة محلية في `.dev.vars` (مستثناة من المستودع).
- النطاق: `api.zimam.work` (`docs/setup.md`، «النطاق»).

التشغيل والاختبار والمسارات والمزامنة: [`DEVELOPMENT.md`](DEVELOPMENT.md).
