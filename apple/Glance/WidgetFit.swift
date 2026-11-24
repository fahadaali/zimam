import SwiftUI

// Sizing a widget's content to the space the system gives it, so it fills the widget on every
// device (each iPhone, iPad and Mac size, each watch size, round or rectangular) rather than
// sitting small in one part of it or running past its edge and being cut short.
//
// A widget is drawn once, without a second layout pass, so the layout is worked out from the
// sizes alone: the lines a layout stacks (`ZimamTextStyle.line`, times the Dynamic Type factor)
// are compared with the height it has, and its text is scaled by the ratio, within a range. Each
// text also shrinks a little more on its own (`widgetFont`) before it is cut short.
//
// Shared by the home-screen widgets (ZimamWidgets, iPhone, iPad and Mac) and the accessory
// widgets of the Lock Screen and the watch (Glance).

/// The scale range and the arithmetic of fitting lines into a height.
nonisolated enum WidgetFit {
    /// Below this the text is too small to read at a glance, so a layout drops a line instead.
    static let smallest: CGFloat = 0.85
    /// Text grows up to this much over its size to fill a larger widget.
    static let largest: CGFloat = 1.3
    /// How far one text shrinks on its own to fit its width before it is cut short.
    static let shrink: CGFloat = 0.7
    /// Room kept free, as a share of the height, for the estimate's error (the font's actual
    /// line can differ from 1.25em by a little), so a filled widget is never cut at the bottom.
    static let margin: CGFloat = 0.94

    /// The height of `lines` stacked at scale 1 under the Dynamic Type factor `dynamicType`.
    static func textHeight(_ lines: [ZimamTextStyle], dynamicType: CGFloat) -> CGFloat {
        lines.reduce(0) { $0 + $1.line } * dynamicType
    }

    /// The scale at which content whose height is `natural` at scale 1 fills `available`, within
    /// `range`. `fixed` is the part that does not scale (spacing between the lines).
    static func scale(natural: CGFloat, fixed: CGFloat = 0, available: CGFloat,
                      range: ClosedRange<CGFloat> = 1...largest) -> CGFloat {
        let scalable = natural - fixed
        guard scalable > 0 else { return range.lowerBound }
        let raw = (available * margin - fixed) / scalable
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}

/// Rows of one height in a list: as many as fit at `minimum` each, then stretched to share what is
/// left, up to `WidgetFit.largest` times `minimum`. When there are more items than fit, the last
/// `moreLine` of the height is kept for «+n أخرى».
nonisolated struct WidgetRows: Equatable {
    /// How many rows are shown.
    let shown: Int
    /// The height of each row.
    let height: CGFloat
    /// Whether some items are left out, for «+n أخرى».
    let hasMore: Bool

    /// How much larger than `minimum` each row is: the scale its text and circle take.
    let scale: CGFloat

    init(items: Int, available: CGFloat, minimum: CGFloat, moreLine: CGFloat) {
        let fitting = minimum > 0 ? max(0, Int(available / minimum)) : 0
        let hasMore = items > fitting
        let shown = hasMore ? max(0, Int((available - moreLine) / minimum)) : items
        let room = available - (hasMore ? moreLine : 0)
        let height = shown > 0 ? min(max(room / CGFloat(shown), minimum), minimum * WidgetFit.largest) : minimum
        self.shown = shown
        self.height = height
        self.hasMore = hasMore
        self.scale = minimum > 0 ? height / minimum : 1
    }
}

/// The lanes of task chips in a calendar row (the week and month widgets): as many as fit at `lane`
/// each, stretched to share the room so no strip is left empty under them, up to
/// `WidgetFit.largest` times `lane`.
nonisolated struct WidgetLanes: Equatable {
    let count: Int
    let height: CGFloat
    /// How much larger than `lane` each lane is: the scale its chips' text takes.
    let scale: CGFloat

    init(room: CGFloat, lane: CGFloat) {
        let count = lane > 0 ? max(0, Int(room / lane)) : 0
        let height = count > 0 ? min(room / CGFloat(count), lane * WidgetFit.largest) : lane
        self.count = count
        self.height = height
        self.scale = lane > 0 ? max(height / lane, 1) : 1
    }
}

/// Which lines a rectangular accessory shows (the Lock Screen and the watch), and at what scale:
/// a header over a main text of one or two lines over a detail line. The fullest layout that is
/// still readable in the height wins; the line `drops` gives way first, then the other, and the
/// main text stays. On the larger Lock Screen the text grows a little instead.
nonisolated struct AccessoryPlan: Equatable {
    nonisolated enum Droppable { case header, detail }

    let showsHeader: Bool
    let showsDetail: Bool
    let mainLines: Int
    let scale: CGFloat

    static let range: ClosedRange<CGFloat> = WidgetFit.smallest...1.2

    static func fitting(height: CGFloat, dynamicType: CGFloat, header: ZimamTextStyle?, main: ZimamTextStyle,
                        mainLines: Int = 1, detail: ZimamTextStyle?, drops: Droppable) -> AccessoryPlan {
        let hasHeader = header != nil
        let hasDetail = detail != nil
        // From the fullest down: both, without the first to go, the main text alone.
        let options: [(Bool, Bool)] = drops == .header
            ? [(hasHeader, hasDetail), (false, hasDetail), (false, false)]
            : [(hasHeader, hasDetail), (hasHeader, false), (false, false)]
        var last = AccessoryPlan(showsHeader: false, showsDetail: false, mainLines: mainLines, scale: range.lowerBound)
        for (showsHeader, showsDetail) in options {
            var lines = Array(repeating: main, count: max(mainLines, 1))
            if showsHeader, let header { lines.insert(header, at: 0) }
            if showsDetail, let detail { lines.append(detail) }
            let natural = WidgetFit.textHeight(lines, dynamicType: dynamicType)
            let raw = natural > 0 ? height * WidgetFit.margin / natural : 1
            last = AccessoryPlan(showsHeader: showsHeader, showsDetail: showsDetail, mainLines: mainLines,
                                 scale: min(max(raw, range.lowerBound), range.upperBound))
            if raw >= range.lowerBound { return last }
        }
        return last
    }
}

/// Text inside a round accessory (the circular Lock Screen and watch widgets), sized to the circle
/// rather than to a fixed point size, so it fills the circle on every watch size and is never cut.
nonisolated enum AccessoryRound {
    /// The share of the side a capacity ring leaves for the number at its centre.
    static let insideRing: CGFloat = 0.5
    /// The share of the side two lines of text take in the open circle (the square inside a
    /// circle is 0.7 of its side; a little is kept for the rounded corners of the glyphs).
    static let twoLines: CGFloat = 0.62
    /// The share of the side a symbol takes.
    static let symbol: CGFloat = 0.45
    /// The share of the side a line may be wide before it shrinks: the circle's chord near its middle.
    static let width: CGFloat = 0.8
    /// How far a long text in the circle shrinks (a countdown with hours) before it is cut.
    static let shrink: CGFloat = 0.5
    /// The largest scale in a circle: the Lock Screen's circle is larger than the watch's.
    static let largest: CGFloat = 1.5

    /// The scale at which `lines` take `share` of a circle's side.
    static func scale(side: CGFloat, lines: [ZimamTextStyle], share: CGFloat, dynamicType: CGFloat) -> CGFloat {
        let natural = WidgetFit.textHeight(lines, dynamicType: dynamicType)
        guard natural > 0 else { return 1 }
        return min(max(side * share / natural, WidgetFit.smallest), largest)
    }
}

// MARK: Text at the layout's scale

nonisolated struct WidgetTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The scale `widgetFont(_:)` draws text at, which a widget's layout sets from its size.
    nonisolated var widgetTextScale: CGFloat {
        get { self[WidgetTextScaleKey.self] }
        set { self[WidgetTextScaleKey.self] = newValue }
    }
}

extension View {
    /// A Zimam text style at the scale the widget's layout chose (`widgetTextScale`), which shrinks
    /// a little more on its own (`WidgetFit.shrink`) to fit its width before it is cut short.
    func widgetFont(_ style: ZimamTextStyle) -> some View {
        modifier(WidgetFontModifier(style: style))
    }

    /// The text scale for this part of a widget.
    func widgetTextScale(_ scale: CGFloat) -> some View {
        environment(\.widgetTextScale, scale)
    }
}

private struct WidgetFontModifier: ViewModifier {
    let style: ZimamTextStyle
    @Environment(\.widgetTextScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(style.font(scale: scale))
            .minimumScaleFactor(WidgetFit.shrink)
    }
}
