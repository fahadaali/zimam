#!/usr/bin/env python3
"""Generate Zimam's platform tokens from design/tokens.json.

Outputs:
  design/generated/tokens.css        — CSS custom properties, @font-face, type classes (web)
  design/generated/ZimamTokens.swift — colors, spacing, radii and type for SwiftUI (Apple)

Run from the repository root:  python3 design/scripts/generate.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKENS = json.loads((ROOT / "tokens.json").read_text(encoding="utf-8"))
OUT = ROOT / "generated"
OUT.mkdir(exist_ok=True)

THEMES = [t["id"] for t in TOKENS["color"]["themes"]]
COLORS = {c["name"]: c for c in TOKENS["color"]["tokens"]}
ALIAS = re.compile(r"\{(.+)\}")


def value(v, theme):
    if isinstance(v, str):
        return v
    return v.get(theme, v.get(THEMES[0]))


def css_value(v):
    m = ALIAS.fullmatch(v)
    return f"var(--{m.group(1)})" if m else v


def resolve(name, theme):
    v = value(COLORS[name]["value"], theme)
    m = ALIAS.fullmatch(v)
    return resolve(m.group(1), theme) if m else v


def camel(name):
    parts = name.split("-")
    return parts[0] + "".join(p.title() for p in parts[1:])


def rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


# ---------------------------------------------------------------- CSS
def css():
    out = ["/* Zimam — generated from design/tokens.json. Do not edit by hand; run design/scripts/generate.py. */"]
    for f in TOKENS["type"]["fonts"]:
        file = f["file"].split("/")[-1]
        out.append(
            f"@font-face {{ font-family: '{f['family']}'; src: url('../fonts/web/{file}') format('woff2'); "
            f"font-weight: {f['weight']}; font-style: {f.get('style', 'normal')}; font-display: swap; }}"
        )

    def block(theme, selector):
        lines = [f"  --{c['name']}: {css_value(value(c['value'], theme))};" for c in TOKENS["color"]["tokens"]]
        lines += [f"  --{s['name']}: {value(s['value'], theme)};" for s in TOKENS["shadow"]["tokens"]]
        return selector + " {\n" + "\n".join(lines) + "\n}"

    out.append(block("light", ':root, [data-theme="light"]'))
    out.append(block("dark", '[data-theme="dark"]'))
    out.append("@media (prefers-color-scheme: dark) {\n  "
               + block("dark", ':root:not([data-theme="light"])').replace("\n", "\n  ") + "\n}")
    root = [f"  --{t['name']}: {t['value']};" for fam in ("spacing", "radius") for t in TOKENS[fam]["tokens"]]
    root += [f"  --font-{k}: {v};" for k, v in TOKENS["type"]["families"].items()]
    out.append(":root {\n" + "\n".join(root) + "\n}")
    for group in TOKENS["type"]["groups"]:
        for s in group["styles"]:
            fam = s.get("family", group["family"])
            out.append(f".{s['name']} {{ font-family: var(--font-{fam}); font-size: {s['fontSize']}; "
                       f"line-height: {s['lineHeight']}; font-weight: {s['fontWeight']}; }}")
    (OUT / "tokens.css").write_text("\n\n".join(out) + "\n", encoding="utf-8")


# ---------------------------------------------------------------- Swift
TEXT_STYLE = {"display": ".largeTitle", "title": ".title2", "headline": ".headline", "body": ".body",
              "callout": ".callout", "caption": ".caption", "hero": ".largeTitle"}
WEIGHT = {300: ".light", 400: ".regular", 500: ".medium", 600: ".semibold", 700: ".bold", 900: ".black"}

SWIFT_FONTS = '''/// PostScript names of the fonts in design/fonts/apple. Add the .otf files to every app target
/// (iPhone, iPad, Mac, Watch, widgets) and list them under UIAppFonts / ATSApplicationFontsPath.
public enum ZimamFontName {
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
'''

SWIFT_DYNAMIC = '''
extension Color {
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
'''


SHADOW = re.compile(r"(-?\d+)(?:px)? (-?\d+)(?:px)? (\d+)(?:px)? rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)")


def shadow(css_value):
    """'0 8px 24px rgba(23,27,47,0.14)' -> (x, y, blur, (r, g, b), alpha)."""
    m = SHADOW.fullmatch(css_value.strip())
    if not m:
        raise ValueError(f"unsupported shadow: {css_value}")
    x, y, blur, r, g, b, a = m.groups()
    return int(x), int(y), int(blur), (int(r) / 255, int(g) / 255, int(b) / 255), float(a)


def swift_shadows():
    s = ["public enum ZimamShadow {"]
    for t in TOKENS["shadow"]["tokens"]:
        lx, ly, lblur, lc, la = shadow(value(t["value"], "light"))
        dx, dy, dblur, dc, da = shadow(value(t["value"], "dark"))
        if (lx, ly, lblur) != (dx, dy, dblur):
            raise ValueError(f"{t['name']}: light and dark must share offset and blur")
        name = camel(t["name"].removeprefix("shadow-"))
        s.append(f"    /// {t['usage']}")
        s.append(f"    public static let {name}Color = Color.zimamDynamic("
                 f"light: ({lc[0]:.4f}, {lc[1]:.4f}, {lc[2]:.4f}), dark: ({dc[0]:.4f}, {dc[1]:.4f}, {dc[2]:.4f}), "
                 f"lightAlpha: {la:g}, darkAlpha: {da:g})")
        s.append(f"    /// SwiftUI's shadow radius is about half the CSS blur ({lblur:g}px).")
        s.append(f"    public static let {name}Radius: CGFloat = {lblur / 2:g}")
        s.append(f"    public static let {name}X: CGFloat = {lx:g}")
        s.append(f"    public static let {name}Y: CGFloat = {ly:g}")
    s.append("}")
    return s


def swift():
    s = ["// Zimam design tokens — generated from design/tokens.json. Do not edit by hand.",
         "import SwiftUI", "#if canImport(UIKit)", "import UIKit", "#elseif canImport(AppKit)", "import AppKit", "#endif",
         "", "public enum ZimamColor {"]
    for c in TOKENS["color"]["tokens"]:
        l, d = rgb(resolve(c["name"], "light")), rgb(resolve(c["name"], "dark"))
        s.append(f"    /// {c['usage']}")
        s.append(f"    public static let {camel(c['name'])} = Color.zimamDynamic("
                 f"light: ({l[0]:.4f}, {l[1]:.4f}, {l[2]:.4f}), dark: ({d[0]:.4f}, {d[1]:.4f}, {d[2]:.4f}))")
    s += ["}", "", "public enum ZimamSpacing {"]
    s += [f"    public static let {camel(t['name'])}: CGFloat = {t['value'].replace('px', '')}" for t in TOKENS["spacing"]["tokens"]]
    s += ["}", "", "public enum ZimamRadius {"]
    s += [f"    public static let {camel(t['name'])}: CGFloat = {t['value'].replace('px', '')}" for t in TOKENS["radius"]["tokens"]]
    s += ["}", ""] + swift_shadows()
    s += ["", SWIFT_FONTS, "public enum ZimamType {"]
    for group in TOKENS["type"]["groups"]:
        for st in group["styles"]:
            fam = st.get("family", group["family"])
            fn = "sans" if fam == "sans" else "display"
            size = float(st["fontSize"].replace("px", ""))
            line = float(st["lineHeight"].replace("px", ""))
            s.append(f"    /// {st['usage']}")
            s.append(f"    public static let {st['name']} = Font.custom(ZimamFontName.{fn}({WEIGHT[st['fontWeight']]}), "
                     f"size: {size:g}, relativeTo: {TEXT_STYLE[st['name']]})")
            s.append(f"    /// Extra line spacing so lines match the {line:g}px line height (the font's own line is 1.25em).")
            s.append(f"    public static let {st['name']}LineSpacing: CGFloat = {max(line - size * 1.25, 0):g}")
    s.append("}")
    s.append(SWIFT_DYNAMIC)
    (OUT / "ZimamTokens.swift").write_text("\n".join(s), encoding="utf-8")


if __name__ == "__main__":
    css()
    swift()
    print("Generated", OUT / "tokens.css", "and", OUT / "ZimamTokens.swift")
