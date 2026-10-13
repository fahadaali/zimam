# تطبيق زمام لأجهزة أبل

تطبيق SwiftUI واحد للآيفون والآيباد والماك. هدفا ساعة أبل والويدجت يُضافان في خطوة لاحقة.

## التشغيل على الماك

```sh
brew install xcodegen
cd apple
xcodegen            # يولّد Zimam.xcodeproj من project.yml
open Zimam.xcodeproj
```

- المرجع هو `project.yml`. يُعاد تشغيل `xcodegen` بعد أي تعديل عليه، ويُرفع `Zimam.xcodeproj` المولَّد معه حتى يجده Xcode Cloud. لا يُعدَّل المشروع من Xcode مباشرة لأن التوليد التالي يمسح التعديل.
- ضع معرّف فريقك (Team ID) في `DEVELOPMENT_TEAM` داخل `project.yml`، لا في Xcode.
- عنوان الخادم في `ZIMAM_API_URL` داخل `project.yml`.

## الهيكل

| المجلد | ما فيه |
| --- | --- |
| `ZimamKit/` | حزمة Swift مستقلة عن الواجهة: التاريخ الهجري (أم القرى) مع الميلادي، وأوقات الصلاة (مكتبة Adhan)، والبحث العربي، وعميل الواجهة البرمجية وأشكال بيانات المزامنة. اختباراتها: `cd apple/ZimamKit && swift test` |
| `Zimam/App/` | نقطة البداية، وتسجيل الدخول بحساب أبل، وحفظ الجلسة في Keychain |
| `Zimam/Model/` | نماذج SwiftData المحلية للعمل دون اتصال، و`Store` الذي تمر منه كل تعديلات المستخدم |
| `Zimam/Sync/` | محرك المزامنة: يرسل التعديلات المحلية ثم يستقبل تغييرات الخادم |
| `Zimam/Components/` | مكافئات مكوّنات `design/components/`: سطر المهمة، وشريحتا التاريخ والصلاة، وبطاقة المشروع، والزر |
| `Zimam/Views/` | الشاشات: اليوم، والقادم، والمشاريع، والبحث، وإضافة مهمة، وتسجيل الدخول |

يُضاف للهدف تلقائياً `../design/generated/ZimamTokens.swift` وخطوط ثمانية من `../design/fonts/apple/`، وأيقونة التطبيق وشعاره منسوخان في `Zimam/Resources/Assets.xcassets`.

## تذكير بالقواعد

- الألوان والمسافات والزوايا والخطوط من `ZimamColor` و`ZimamSpacing` و`ZimamRadius` و`ZimamType` فقط.
- `leading` و`trailing` دائماً، لا `left` و`right`.
- كل تاريخ بالهجري والميلادي عبر `DualDateFormatter`، والفاصل بينهما «،».
