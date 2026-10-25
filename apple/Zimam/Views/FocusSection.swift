#if os(iOS)
import SwiftUI
import UIKit
import ZimamKit

/// «بدء التركيز» / «إنهاء» in a task's details: starts the «المهمة الجارية» Live Activity
/// (a timer on the Lock Screen and in the Dynamic Island, with «إنجاز») or ends it.
/// Completing the task anywhere ends it too. iPhone only: the iPad has no Live Activities.
struct FocusSection: View {
    let task: TaskItem
    let projectName: String?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isRunning = false
    @State private var isEnabled = true
    @State private var failed = false

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .phone && (!task.isDone || isRunning) {
            Section {
                if isRunning {
                    Button("إنهاء التركيز", systemImage: "stop.circle") {
                        Task {
                            await FocusActivity.end(taskId: task.id)
                            refresh()
                        }
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                } else {
                    Button("بدء التركيز", systemImage: "scope") {
                        Task {
                            let started = await FocusActivity.start(taskId: task.id, title: task.title, projectName: projectName)
                            failed = !started
                            refresh()
                            if started { FocusDoNotDisturb.shared.focusStarted() }
                        }
                    }
                    .frame(minHeight: ZimamSpacing.space11)
                    .disabled(!isEnabled)
                }
                if !isEnabled {
                    note("الأنشطة الحية متوقفة لزمام. فعّلها من إعدادات النظام ← زمام.")
                } else if failed {
                    note("تعذّر بدء التركيز. حاول مرة أخرى.")
                }
            } footer: {
                Text(FocusDoNotDisturb.shared.isOn
                     ? "يظهر مؤقت المهمة على شاشة القفل وفي الجزيرة التفاعلية، وتُنجزها منه. ويعمل «عدم الإزعاج» معه."
                     : "يظهر مؤقت المهمة على شاشة القفل وفي الجزيرة التفاعلية، وتُنجزها منه.")
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .onChange(of: task.isDone) { _, done in
                guard done else { return }
                Task {
                    await FocusActivity.end(taskId: task.id)
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        isEnabled = FocusActivity.isEnabled
        isRunning = FocusActivity.isRunning(task.id)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ZimamType.caption)
            .foregroundStyle(ZimamColor.inkMuted)
    }
}
#endif
