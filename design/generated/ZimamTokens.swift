// Zimam design tokens — generated from design/tokens.json. Do not edit by hand.
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated public enum ZimamColor {
    /// خلفية الصفحة والقوائم الرئيسية.
    public static let surface = Color.zimamDynamic(light: (0.9647, 0.9686, 0.9843), dark: (0.0549, 0.0667, 0.1255))
    /// البطاقات وأسطر المهام والنوافذ المنبثقة فوق surface.
    public static let surfaceRaised = Color.zimamDynamic(light: (1.0000, 1.0000, 1.0000), dark: (0.0902, 0.1059, 0.1804))
    /// أعمدة الكانبان والشريط الجانبي وحقول الإدخال.
    public static let surfaceSunken = Color.zimamDynamic(light: (0.9255, 0.9333, 0.9647), dark: (0.0392, 0.0471, 0.0902))
    /// فواصل زخرفية رفيعة بين الأسطر فقط؛ لا تُستعمل حدّاً لعنصر تفاعلي.
    public static let line = Color.zimamDynamic(light: (0.8667, 0.8824, 0.9255), dark: (0.1686, 0.1882, 0.2824))
    /// حدود العناصر التفاعلية: دائرة الإنجاز وحقول الإدخال والأزرار الثانوية. لا يقل عن 3:1 على كل الأسطح.
    public static let lineStrong = Color.zimamDynamic(light: (0.4980, 0.5216, 0.6196), dark: (0.4078, 0.4314, 0.5412))
    /// النص الأساسي وعناوين المهام على surface وsurface-raised وsurface-sunken وbrand-soft.
    public static let ink = Color.zimamDynamic(light: (0.0902, 0.1059, 0.1843), dark: (0.9255, 0.9333, 0.9686))
    /// النص الثانوي والتواريخ والنص التوضيحي داخل الحقول، على كل الأسطح وbrand-soft.
    public static let inkMuted = Color.zimamDynamic(light: (0.3373, 0.3647, 0.4706), dark: (0.6353, 0.6588, 0.7608))
    /// نص العناصر المعطّلة والمهام المنجزة فقط؛ لا يُستعمل لنص يحتاج المستخدم قراءته.
    public static let inkFaint = Color.zimamDynamic(light: (0.5020, 0.5255, 0.6235), dark: (0.4627, 0.4863, 0.5922))
    /// لون زمام النيلي: الزر الأساسي، ودائرة الإنجاز عند التحديد، والروابط، وحلقة التركيز. يُستعمل باقتصاد.
    public static let brand = Color.zimamDynamic(light: (0.2275, 0.2745, 0.6902), dark: (0.5608, 0.6000, 0.9490))
    /// النص والأيقونات فوق brand.
    public static let onBrand = Color.zimamDynamic(light: (1.0000, 1.0000, 1.0000), dark: (0.0549, 0.0667, 0.1255))
    /// خلفية السطر المحدد، وبطاقة اقتراح المساعد، وشريحة المشروع النشط.
    public static let brandSoft = Color.zimamDynamic(light: (0.9059, 0.9137, 0.9843), dark: (0.1373, 0.1647, 0.3686))
    /// النص النيلي فوق brand-soft.
    public static let brandInk = Color.zimamDynamic(light: (0.1804, 0.2196, 0.5608), dark: (0.7255, 0.7529, 0.9725))
    /// لون أوقات الصلاة: نص وأيقونة شريحة الصلاة على sand-soft وsurface-raised.
    public static let sand = Color.zimamDynamic(light: (0.5294, 0.3529, 0.0549), dark: (0.9020, 0.7373, 0.4235))
    /// خلفية شريحة وقت الصلاة وتمييز فترة الصلاة في التقويم.
    public static let sandSoft = Color.zimamDynamic(light: (0.9686, 0.9333, 0.8588), dark: (0.2157, 0.1647, 0.0706))
    /// الأولوية العالية والتأخر والحذف؛ يرافقه دائماً رمز أو كلمة. نص على surface وsurface-raised.
    public static let priorityHigh = Color.zimamDynamic(light: (0.7255, 0.2431, 0.0471), dark: (0.9490, 0.5725, 0.3725))
    /// الأولوية المتوسطة؛ يرافقه رمز العلم. نص على surface وsurface-raised.
    public static let priorityMedium = Color.zimamDynamic(light: (0.5412, 0.3804, 0.0000), dark: (0.8902, 0.7098, 0.3059))
    /// الأولوية المنخفضة.
    public static let priorityLow = Color.zimamDynamic(light: (0.2275, 0.2745, 0.6902), dark: (0.5608, 0.6000, 0.9490))
    /// تأكيد الحفظ والمزامنة الناجحة؛ يرافقه رمز صح، لأن تمييزه عن priority-high بالدرجة لا يكفي لمن لديه عمى ألوان.
    public static let success = Color.zimamDynamic(light: (0.1216, 0.4353, 0.2627), dark: (0.3843, 0.7882, 0.5608))
    /// حلقة التركيز للوحة المفاتيح: خط صلب بسماكة 2px وإزاحة 2px. 6.5:1 أو أكثر على كل الأسطح في الثيمين.
    public static let focusRing = Color.zimamDynamic(light: (0.2275, 0.2745, 0.6902), dark: (0.5608, 0.6000, 0.9490))
    /// ربع «مهم وعاجل» في المصفوفة: أيقونته وعنوانه وخلفية عدّاده. يرافقه دائماً اسم الربع. نص على surface وsurface-raised.
    public static let quadrantUrgentImportant = Color.zimamDynamic(light: (0.7255, 0.2431, 0.0471), dark: (0.9490, 0.5725, 0.3725))
    /// ربع «مهم» في المصفوفة: أيقونته وعنوانه وخلفية عدّاده. أزرق يختلف عن brand لأنه ليس إجراءً. نص على surface وsurface-raised.
    public static let quadrantImportant = Color.zimamDynamic(light: (0.0667, 0.3804, 0.5412), dark: (0.4235, 0.7647, 0.9098))
    /// ربع «عاجل» في المصفوفة: أيقونته وعنوانه وخلفية عدّاده. نص على surface وsurface-raised.
    public static let quadrantUrgent = Color.zimamDynamic(light: (0.5412, 0.3804, 0.0000), dark: (0.8902, 0.7098, 0.3059))
    /// ربع «يوماً ما» في المصفوفة: أيقونته وعنوانه وخلفية عدّاده.
    public static let quadrantSomeday = Color.zimamDynamic(light: (0.3373, 0.3647, 0.4706), dark: (0.6353, 0.6588, 0.7608))
    /// العدد فوق خلفية لون الربع في المصفوفة. 4.5:1 أو أكثر على ألوان الأرباع الأربعة في الثيمين.
    public static let onQuadrant = Color.zimamDynamic(light: (1.0000, 1.0000, 1.0000), dark: (0.0549, 0.0667, 0.1255))
    /// شريط المهمة الممتدة أياماً في التقويم والمخطط الزمني. حدّه 3:1 أو أكثر على كل الأسطح فلا يحتاج إطاراً، ونصه on-timeline-bar.
    public static let timelineBar = Color.zimamDynamic(light: (0.1059, 0.4314, 0.4157), dark: (0.3725, 0.7686, 0.7333))
    /// عنوان المهمة فوق timeline-bar. 4.5:1 أو أكثر في الثيمين.
    public static let onTimelineBar = Color.zimamDynamic(light: (1.0000, 1.0000, 1.0000), dark: (0.0549, 0.0667, 0.1255))
    /// خط اليوم في المخطط الزمني: خط صلب بسماكة 2px يرافقه اسم «اليوم» في رأس العمود.
    public static let timelineToday = Color.zimamDynamic(light: (0.7255, 0.2431, 0.0471), dark: (0.9490, 0.5725, 0.3725))
}

nonisolated public enum ZimamSpacing {
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space6: CGFloat = 24
    public static let space8: CGFloat = 32
    public static let space11: CGFloat = 44
}

nonisolated public enum ZimamRadius {
    public static let radiusSm: CGFloat = 6
    public static let radiusMd: CGFloat = 10
    public static let radiusLg: CGFloat = 16
    public static let radiusPill: CGFloat = 999
}

nonisolated public enum ZimamShadow {
    /// المهمة أثناء السحب والإفلات، والقوائم المنبثقة. لا يُستعمل للبطاقات الثابتة.
    public static let liftColor = Color.zimamDynamic(light: (0.0902, 0.1059, 0.1843), dark: (0.0000, 0.0000, 0.0000), lightAlpha: 0.14, darkAlpha: 0.5)
    /// SwiftUI's shadow radius is about half the CSS blur (24px).
    public static let liftRadius: CGFloat = 12
    public static let liftX: CGFloat = 0
    public static let liftY: CGFloat = 8
}

/// PostScript names of the fonts in design/fonts/apple. Add the .otf files to every app target
/// (iPhone, iPad, Mac, Watch, widgets) and list them under UIAppFonts / ATSApplicationFontsPath.
nonisolated public enum ZimamFontName {
    public static func sans(_ weight: Font.Weight) -> String {
        switch weight {
        case .light: return "thmanyahsans-Light"
        case .medium: return "thmanyahsans-Medium"
        case .bold, .semibold: return "thmanyahsans-Bold"
        case .black, .heavy: return "thmanyahsans-Black"
        default: return "thmanyahsans-Regular"
        }
    }

    public static func display(_ weight: Font.Weight) -> String {
        switch weight {
        case .light: return "thmanyahserifdisplay-Light"
        case .medium: return "thmanyahserifdisplay-Medium"
        case .bold, .semibold: return "thmanyahserifdisplay-Bold"
        case .black, .heavy: return "thmanyahserifdisplay-Black"
        default: return "thmanyahserifdisplay-Regular"
        }
    }
}

nonisolated public enum ZimamType {
    /// عنوان الشاشة الكبير: اليوم، القادم، اسم المشروع. مرة واحدة في الشاشة، مع الأحرف المرسلة (zm-display) ومدّ واحد اختياري قبل الحرف الأخير.
    public static let display = Font.custom(ZimamFontName.sans(.bold), size: 34, relativeTo: .largeTitle)
    /// Extra line spacing so lines match the 50px line height (the font's own line is 1.25em).
    public static let displayLineSpacing: CGFloat = 7.5
    /// عناوين الأقسام وأعمدة الكانبان وعنوان تفاصيل المهمة.
    public static let title = Font.custom(ZimamFontName.sans(.bold), size: 22, relativeTo: .title2)
    /// Extra line spacing so lines match the 34px line height (the font's own line is 1.25em).
    public static let titleLineSpacing: CGFloat = 6.5
    /// عنوان المهمة المهمة أو المثبتة، وعنوان البطاقة.
    public static let headline = Font.custom(ZimamFontName.sans(.semibold), size: 17, relativeTo: .headline)
    /// Extra line spacing so lines match the 26px line height (the font's own line is 1.25em).
    public static let headlineLineSpacing: CGFloat = 4.75
    /// عنوان المهمة في السطر، والملاحظات، ونص الحوار.
    public static let body = Font.custom(ZimamFontName.sans(.regular), size: 17, relativeTo: .body)
    /// Extra line spacing so lines match the 28px line height (the font's own line is 1.25em).
    public static let bodyLineSpacing: CGFloat = 6.75
    /// وصف ثانوي تحت العنوان، ونص اقتراح المساعد.
    public static let callout = Font.custom(ZimamFontName.sans(.regular), size: 15, relativeTo: .callout)
    /// Extra line spacing so lines match the 24px line height (the font's own line is 1.25em).
    public static let calloutLineSpacing: CGFloat = 5.25
    /// التواريخ والشرائح والعدّادات. أصغر حجم مسموح لنص يُقرأ.
    public static let caption = Font.custom(ZimamFontName.sans(.medium), size: 13, relativeTo: .caption)
    /// Extra line spacing so lines match the 20px line height (the font's own line is 1.25em).
    public static let captionLineSpacing: CGFloat = 3.75
    /// عناوين الموقع والمتجر وشاشات الترحيب فقط، بخط ثمانية للعناوين مع الأحرف المرسلة (zm-hero). مدّ واحد في السطر على الأكثر.
    public static let hero = Font.custom(ZimamFontName.display(.bold), size: 48, relativeTo: .largeTitle)
    /// Extra line spacing so lines match the 70px line height (the font's own line is 1.25em).
    public static let heroLineSpacing: CGFloat = 10
}

nonisolated extension Color {
    /// A color that follows the system light/dark appearance.
    static func zimamDynamic(
        light: (Double, Double, Double), dark: (Double, Double, Double), lightAlpha: Double = 1, darkAlpha: Double = 1
    ) -> Color {
        #if os(watchOS)
        return Color(red: dark.0, green: dark.1, blue: dark.2, opacity: darkAlpha) // watchOS is always dark
        #elseif canImport(UIKit)
        return Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let c = isDark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: isDark ? darkAlpha : lightAlpha)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2, opacity: lightAlpha)
        #endif
    }
}
