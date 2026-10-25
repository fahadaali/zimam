#if os(iOS)
import SwiftUI
import ZimamKit

/// «التركيز»: «عدم الإزعاج» with «المهمة الجارية» (`FocusDoNotDisturb`), how to make its two
/// shortcuts, and the actions for the user's own shortcut (Intents/FocusIntents.swift).
struct FocusSettingsView: View {
    @Bindable private var focus = FocusDoNotDisturb.shared

    var body: some View {
        Form {
            Section {
                Toggle("تشغيل «عدم الإزعاج» مع التركيز", isOn: $focus.isOn)
                    .frame(minHeight: ZimamSpacing.space11)
            } footer: {
                Text("لا تسمح أبل لتطبيق بتشغيل «عدم الإزعاج» بنفسه، فيشغّل زمام اختصارين تنشئهما مرة واحدة: الأول حين تبدأ التركيز على مهمة، والثاني حين تنهيه أو تنجزها. يفتح «الاختصارات» لحظة ثم يعود إلى زمام. وإن أنهيته من شاشة القفل توقّف «عدم الإزعاج» حين تفتح زمام بعدها.")
            }

            Section {
                step("أنشئ اختصاراً باسم «\(FocusDoNotDisturb.startShortcut)»", "وأضف إليه إجراء «تعيين التركيز»، واختر «عدم الإزعاج» و«تشغيل».")
                step("أنشئ اختصاراً باسم «\(FocusDoNotDisturb.endShortcut)»", "وأضف إليه «تعيين التركيز» نفسه، واختر «إيقاف».")
                Link(destination: FocusDoNotDisturb.shortcutsURL) {
                    Label("فتح الاختصارات", systemImage: "square.2.layers.3d")
                }
                .frame(minHeight: ZimamSpacing.space11)
            } header: {
                Text("الاختصاران")
            } footer: {
                Text("اكتب الاسمين كما هما. ولك أن تختار وضع تركيز غير «عدم الإزعاج».")
            }

            Section {
                step("بدء التركيز على مهمة", "يبدأ مؤقت المهمة على شاشة القفل.")
                step("إنهاء التركيز الجاري", "ينهي المؤقت دون إنجاز المهمة.")
            } header: {
                Text("من اختصارك أو زر الإجراء")
            } footer: {
                Text("إجراءان من زمام في «الاختصارات». ضع «تعيين التركيز» قبل «بدء التركيز على مهمة» في اختصار واحد، وشغّله من سيري أو زر الإجراء أو مركز التحكم.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZimamColor.surface)
        .navigationTitle("التركيز")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text(title)
                .font(ZimamType.body)
                .foregroundStyle(ZimamColor.ink)
            Text(detail)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
        }
        .frame(minHeight: ZimamSpacing.space11)
        .accessibilityElement(children: .combine)
    }
}
#endif
