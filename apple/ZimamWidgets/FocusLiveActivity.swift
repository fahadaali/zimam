#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// «المهمة الجارية» on the Lock Screen and in the Dynamic Island: the task, its project,
/// a timer counting up from the start, and «إنجاز» (CompleteFocusTaskIntent) and «إنهاء»
/// (EndFocusIntent). Arabic and right to left; the Dynamic Island is always dark.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreenView(context: context)
                .zimamActivityEnvironment()
                .activityBackgroundTint(ZimamColor.surfaceRaised)
                .activitySystemActionForegroundColor(ZimamColor.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FocusMark()
                        .zimamActivityEnvironment(dark: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FocusTimer(startedAt: context.state.startedAt)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                        .zimamActivityEnvironment(dark: true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                        .lineLimit(1)
                        .zimamActivityEnvironment(dark: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                        if let project = context.attributes.projectName {
                            Text(project)
                                .font(ZimamType.caption)
                                .foregroundStyle(ZimamColor.inkMuted)
                                .lineLimit(1)
                        }
                        FocusActions(taskId: context.attributes.taskId, title: context.attributes.title)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zimamActivityEnvironment(dark: true)
                }
            } compactLeading: {
                FocusMark()
                    .zimamActivityEnvironment(dark: true)
            } compactTrailing: {
                FocusTimer(startedAt: context.state.startedAt)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.ink)
                    // A running timer takes all the width it is offered; the island keeps it short.
                    .frame(maxWidth: ZimamSpacing.space11 + ZimamSpacing.space4)
                    .zimamActivityEnvironment(dark: true)
            } minimal: {
                FocusMark()
                    .zimamActivityEnvironment(dark: true)
            }
            .keylineTint(ZimamColor.lineStrong)
        }
    }
}

/// The Lock Screen banner: what is running, the timer, the task and its project, then the actions.
private struct FocusLockScreenView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Label("المهمة الجارية", systemImage: "scope")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
                Spacer(minLength: ZimamSpacing.space2)
                FocusTimer(startedAt: context.state.startedAt)
                    .font(ZimamType.title)
                    .foregroundStyle(ZimamColor.ink)
                    .frame(maxWidth: ZimamSpacing.space11 * 3, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(context.attributes.title)
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
                    .lineLimit(2)
                if let project = context.attributes.projectName {
                    Text(project)
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .lineLimit(1)
                }
            }
            FocusActions(taskId: context.attributes.taskId, title: context.attributes.title)
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// «إنجاز» (the action, in brand) and «إنهاء» (secondary, bordered in line-strong), each 44pt tall.
private struct FocusActions: View {
    let taskId: UUID
    let title: String

    var body: some View {
        HStack(spacing: ZimamSpacing.space2) {
            Button(intent: CompleteFocusTaskIntent(taskId: taskId)) {
                Label("إنجاز", systemImage: "checkmark")
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.onBrand)
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                    .background(ZimamColor.brand, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusMd))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إنجاز \(title)")

            Button(intent: EndFocusIntent(taskId: taskId)) {
                Text("إنهاء")
                    .font(ZimamType.headline)
                    .foregroundStyle(ZimamColor.ink)
                    .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11)
                    .overlay(RoundedRectangle(cornerRadius: ZimamRadius.radiusMd).stroke(ZimamColor.lineStrong))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إنهاء التركيز على \(title)")
        }
    }
}

/// The time since the focus started, counting up, in the user's digits.
private struct FocusTimer: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...startedAt.addingTimeInterval(FocusActivity.maxDuration), countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
    }
}

/// The focus symbol for the compact and minimal island. Not an action, so not in brand.
private struct FocusMark: View {
    var body: some View {
        Image(systemName: "scope")
            .font(ZimamType.headline)
            .foregroundStyle(ZimamColor.ink)
            .accessibilityLabel("المهمة الجارية")
    }
}

private extension View {
    /// Arabic, right to left, with the user's digits. The Dynamic Island is black whatever the
    /// appearance, so its views take the dark tokens.
    func zimamActivityEnvironment(dark: Bool = false) -> some View {
        self
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, ZimamLocale.current)
            .modifier(DarkIsland(isOn: dark))
    }
}

private struct DarkIsland: ViewModifier {
    let isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}
#endif
