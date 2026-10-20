import SwiftUI
import ZimamKit

/// One task: its bar (or a diamond for a one-day task) at its days, its title inside the bar when
/// it fits and after it otherwise.
struct GanttRow: View {
    enum Part { case whole, start, end }

    let task: TaskItem
    let span: DaySpan
    let range: TimelineRange
    let dayWidth: CGFloat
    let height: CGFloat
    let todayX: CGFloat?
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCommit: (DaySpan) -> Void
    let onEdit: () -> Void
    let onComplete: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.layoutDirection) private var layoutDirection
    /// The days while a drag is under way. Not private, so the memberwise initializer stays internal.
    @State var preview: DaySpan?

    private var barHeight: CGFloat { max(height - ZimamSpacing.space3, ZimamSpacing.space6) }
    /// The width of a drag handle at either end of a bar.
    private var handleWidth: CGFloat { ZimamSpacing.space3 }
    /// The touch target of a drag handle, wider (and taller) than the handle it holds.
    private var handleTarget: CGFloat { ZimamSpacing.space11 }

    /// On the iPhone and iPad a bar drags once selected, so a swipe across the chart still
    /// scrolls it; with a pointer it drags straight away.
    private var canDrag: Bool {
        #if os(macOS)
        return true
        #else
        return isSelected
        #endif
    }

    var body: some View {
        let shown = preview ?? span
        ZStack(alignment: .leading) {
            if let todayX {
                GanttTodayLine().padding(.leading, max(todayX - ZimamLayout.focusRingWidth / 2, 0))
            }
            if let columns = range.columns(of: shown) {
                let multiDay = shown.isMultiDay
                let barWidth = multiDay ? CGFloat(columns.count) * dayWidth - ZimamLayout.focusRingWidth : max(dayWidth, barHeight)
                let x = multiDay
                    ? CGFloat(columns.first) * dayWidth + ZimamLayout.focusRingWidth / 2
                    : max(CGFloat(columns.first) * dayWidth + dayWidth / 2 - barWidth / 2, 0)
                let titleInside = multiDay && barWidth >= ZimamSpacing.space11 * 3
                HStack(spacing: ZimamSpacing.space2) {
                    marker(multiDay: multiDay, width: barWidth, titleInside: titleInside)
                    if !titleInside {
                        Text(task.title)
                            .font(ZimamType.callout)
                            .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                            .strikethrough(task.isDone)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.leading, x)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(task.title)، \(formatter.spanText(span))")
                .accessibilityValue(task.isDone ? "منجزة" : "")
                .accessibilityHint("اسحب الشريط أو طرفيه لتغيير المدة، أو استعمل «تغيير المدة…».")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, onOpen)
                .accessibilityAdjustableAction(adjust)
                .accessibilityAction(named: "تغيير المدة…", onEdit)
                .accessibilityAction(named: task.isDone ? "إلغاء الإنجاز" : "إنجاز", onComplete)
            }
        }
        .frame(width: CGFloat(range.dayCount) * dayWidth, height: height, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ZimamColor.line).frame(height: 1).accessibilityHidden(true)
        }
    }

    /// The bar, or the diamond of a one-day task, with the drag handles when it can be dragged.
    private func marker(multiDay: Bool, width: CGFloat, titleInside: Bool) -> some View {
        GanttBarFill(title: task.title, isDone: task.isDone, multiDay: multiDay, titleInside: titleInside,
                     titlePadding: handleWidth)
            .frame(width: width, height: barHeight)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                        .strokeBorder(ZimamColor.focusRing, lineWidth: ZimamLayout.focusRingWidth)
                        .padding(-ZimamLayout.focusRingWidth * 2)
                }
            }
            .overlay(alignment: .leading) { handle(.start, visible: showsHandles(width)) }
            .overlay(alignment: .trailing) { handle(.end, visible: showsHandles(width)) }
            .contentShape(Rectangle())
            .gesture(drag(.whole), including: canDrag ? .all : .subviews)
            .onTapGesture(perform: onSelect)
            .contextMenu {
                Button("فتح المهمة", systemImage: "arrow.up.forward.square", action: onOpen)
                Button("تغيير المدة…", systemImage: "calendar", action: onEdit)
                Button(task.isDone ? "إلغاء الإنجاز" : "إنجاز", systemImage: "checkmark.circle", action: onComplete)
            }
    }

    /// VoiceOver's adjust: a day later or earlier.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: onCommit(span.moved(by: 1))
        case .decrement: onCommit(span.moved(by: -1))
        @unknown default: break
        }
    }

    /// Handles on a task that spans days and is wide enough for both; kept while dragging one.
    private func showsHandles(_ width: CGFloat) -> Bool {
        canDrag && (preview != nil || (span.isMultiDay && width >= handleWidth * 3))
    }

    @ViewBuilder
    private func handle(_ part: Part, visible: Bool) -> some View {
        if visible {
            GanttBarHandle(part: part, barHeight: barHeight, handleWidth: handleWidth, handleTarget: handleTarget)
                .gesture(drag(part))
                .accessibilityHidden(true)
        }
    }

    private func drag(_ part: Part) -> some Gesture {
        // Screen coordinates: their x grows to the right whatever the layout direction.
        DragGesture(minimumDistance: ZimamSpacing.space1, coordinateSpace: .global)
            .onChanged { value in preview = changed(part, by: value.translation.width) }
            .onEnded { value in endDrag(part, translation: value.translation.width) }
    }

    private func endDrag(_ part: Part, translation: CGFloat) {
        let result = changed(part, by: translation)
        preview = nil
        if result != span { onCommit(result) }
    }

    private func changed(_ part: Part, by translation: CGFloat) -> DaySpan {
        let days = TimelineDrag.days(translation: Double(translation), dayWidth: Double(dayWidth),
                                     rightToLeft: layoutDirection == .rightToLeft)
        switch part {
        case .whole: return span.moved(by: days)
        case .start: return span.movingStart(by: days)
        case .end: return span.movingEnd(by: days)
        }
    }
}

/// A bar's look: filled for an open task, outlined for a completed one, with its title when it
/// fits; a one-day task is a diamond.
struct GanttBarFill: View {
    let title: String
    let isDone: Bool
    let multiDay: Bool
    let titleInside: Bool
    /// The room at either end of the title, the width of a drag handle.
    let titlePadding: CGFloat

    var body: some View {
        ZStack {
            // A completed task, kept a moment so it can be undone, looks done as in the lists.
            if multiDay {
                if isDone {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                        .fill(ZimamColor.surfaceSunken)
                        .overlay {
                            RoundedRectangle(cornerRadius: ZimamRadius.radiusSm).strokeBorder(ZimamColor.lineStrong)
                        }
                } else {
                    RoundedRectangle(cornerRadius: ZimamRadius.radiusSm)
                        .fill(ZimamColor.timelineBar)
                }
                if titleInside {
                    Text(title)
                        .font(ZimamType.caption)
                        .foregroundStyle(isDone ? ZimamColor.inkFaint : ZimamColor.onTimelineBar)
                        .strikethrough(isDone)
                        .lineLimit(1)
                        .padding(.horizontal, titlePadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Rectangle()
                    .fill(isDone ? ZimamColor.lineStrong : ZimamColor.timelineBar)
                    .frame(width: ZimamSpacing.space3, height: ZimamSpacing.space3)
                    .rotationEffect(.degrees(45))
            }
        }
    }
}

/// A drag handle at one end of a bar: a thin capsule with a 44pt touch target.
struct GanttBarHandle: View {
    let part: GanttRow.Part
    let barHeight: CGFloat
    let handleWidth: CGFloat
    let handleTarget: CGFloat

    var body: some View {
        Capsule()
            .fill(ZimamColor.onTimelineBar)
            .frame(width: ZimamLayout.focusRingWidth, height: barHeight / 2)
            .frame(width: handleWidth, height: barHeight)
            // The handle stays thin; its touch target is 44pt. The target grows past the bar's
            // end (outward), so the middle of a short bar still moves the whole bar, and evenly
            // above and below. The negative padding keeps the overlay's own size, as the
            // selection ring does, and follows the layout direction.
            .frame(width: handleTarget, height: max(barHeight, handleTarget),
                   alignment: part == .start ? .trailing : .leading)
            .contentShape(Rectangle())
            .padding(part == .start ? .leading : .trailing, handleWidth - handleTarget)
    }
}
