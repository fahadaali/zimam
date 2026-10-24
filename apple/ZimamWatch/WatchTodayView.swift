import SwiftUI
import ZimamKit

/// The watch shows today only: the next prayer with its countdown (from the place the iPhone
/// sent), the dual date, today's open tasks (tap to complete), and a field to add a task by
/// dictation or typing, read by the assistant when online.
struct WatchTodayView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newTitle = ""

    init() {}

    var body: some View {
        NavigationStack {
            List {
                if let place = WatchPrayerStore.read() {
                    Section {
                        WatchPrayerRow(schedule: place.schedule)
                    }
                }
                Section {
                    if !model.isSignedIn {
                        WatchNote(text: "افتح زمام على الآيفون وسجّل الدخول، ثم عُد إلى هنا.")
                    } else if model.tasks.isEmpty && !model.isLoading {
                        WatchNote(text: "لا مهام اليوم. يومك لك.")
                    }
                    ForEach(model.tasks, id: \.id) { task in
                        WatchTaskRow(title: task.title, isDone: model.finishing.contains(task.id)) {
                            model.toggle(task)
                        }
                    }
                } header: {
                    Text(model.formatter.dual(Date()))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .textCase(nil)
                }

                if model.isSignedIn {
                    Section {
                        TextField("إضافة مهمة", text: $newTitle)
                            .font(ZimamType.body)
                            .onSubmit(add)
                    }
                }

                if let notice = model.notice {
                    Section {
                        WatchNote(text: notice)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        WatchNote(text: error)
                    }
                }
            }
            // A completed task leaves the list a second after the tap.
            .animation(.zimam(reduceMotion: reduceMotion), value: model.tasks.map(\.id))
            .navigationTitle("اليوم")
        }
        // One trigger for launch and each return, so a launch does not fetch twice. Leaving for
        // the background asks for the next wake that keeps the complications current.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                WatchRefresh.schedule()
                Task { await model.refresh() }
            case .background:
                WatchRefresh.schedule()
            default:
                break
            }
        }
    }

    private func add() {
        let title = newTitle
        newTitle = ""
        Task { await model.add(title: title) }
    }
}

/// «المتبقي على العصر ١:١٢:٠٥», or for half an hour after the adhan the time since it, in the
/// sand colour of prayer times.
private struct WatchPrayerRow: View {
    let schedule: PrayerSchedule

    @Environment(WatchModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let state = PrayerClock(schedule: schedule).state(at: context.date) {
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    Text(state.title)
                    Text(state.time, style: .timer)
                        .font(ZimamType.title)
                        .monospacedDigit()
                    Text(model.formatter.time(state.time))
                        .font(ZimamType.caption)
                }
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.sand)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The simplified task row: the completion circle and the title, no notes or chips.
/// The whole row is the button, so the target is large on a small screen.
private struct WatchTaskRow: View {
    let title: String
    let isDone: Bool
    let onComplete: () -> Void

    var body: some View {
        Button(action: onComplete) {
            HStack(spacing: ZimamSpacing.space2) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(ZimamType.title)
                    .foregroundStyle(isDone ? ZimamColor.brand : ZimamColor.lineStrong)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(title)
                    .font(ZimamType.body)
                    .foregroundStyle(isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(isDone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: ZimamSpacing.space11)
            .animation(.zimamComplete, value: isDone)
        }
        // The tap turns isDone on; a second tap within the linger, or a failed push, turns it back
        // off. The haptic plays only when it turns on, on the same frame as the circle fills.
        .sensoryFeedback(trigger: isDone) { _, done in done ? .success : nil }
        .accessibilityLabel(label)
    }

    private var label: String {
        isDone ? "\(title)، منجزة" : "إنجاز \(title)"
    }
}

/// One quiet sentence in the list.
private struct WatchNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(ZimamColor.inkMuted)
    }
}
