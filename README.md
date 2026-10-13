# زِمام · Zimam

خذ زمام يومك. مدير مهام عربي أولاً لأجهزة أبل، بتقويم هجري وميلادي، وتذكيرات مرتبطة بأوقات الصلاة، ومساعد ذكي، وخادم MCP يتيح لكلود وChatGPT الوصول للمهام.

| المجلد | ما فيه |
| --- | --- |
| [`apple/`](apple/) | تطبيق SwiftUI لآيفون وآيباد وماك وساعة أبل |
| [`api/`](api/) | الواجهة البرمجية على Cloudflare Workers |
| [`mcp/`](mcp/) | خادم MCP على Cloudflare Workers |
| [`web/`](web/) | موقع زمام وواجهة الويب |
| [`design/`](design/) | نظام التصميم: الرموز، خط ثمانية، الشعارات، أيقونات التطبيق |
| [`docs/`](docs/) | وثيقة الفكرة والقرارات |

- قواعد المشروع لـ Claude Code: [`CLAUDE.md`](CLAUDE.md)
- ربط المستودع بكلاودفلير وXcode: [`docs/setup.md`](docs/setup.md)
- تطوير الواجهة البرمجية واختبارها: [`api/DEVELOPMENT.md`](api/DEVELOPMENT.md)
- توليد رموز التصميم: `python3 design/scripts/generate.py`
