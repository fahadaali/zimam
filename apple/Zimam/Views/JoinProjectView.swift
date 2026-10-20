import SwiftUI
import ZimamKit

// MARK: Joining

/// «الانضمام بدعوة»: takes the link or code from the owner, shows what it offers, then joins
/// and syncs so the project and its tasks arrive.
struct JoinProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncEngine.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text: String
    @State private var preview: InvitePreview?
    @State private var previewCode: String?
    @State private var working = false
    @State private var problem: String?
    @FocusState private var fieldFocused: Bool

    private var code: String? { InviteCode.extract(from: text) }

    init(code: String = "") {
        _text = State(initialValue: code)
    }

    var body: some View {
        let online = NetworkMonitor.shared.isOnline
        NavigationStack {
            Form {
                Section {
                    TextField("رمز الدعوة أو رابطها", text: $text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($fieldFocused)
                        .onSubmit(check)
                        .onChange(of: text) {
                            textChanged()
                        }
                    Button("عرض الدعوة", action: check)
                        .buttonStyle(.zimamSecondary)
                        .disabled(code == nil || working || !online)
                } footer: {
                    Text(online
                         ? "الصق الرابط أو الرمز الذي وصلك من مالك المشروع."
                         : "الانضمام يحتاج اتصالاً بالإنترنت.")
                }

                if working && preview == nil {
                    Section { AssistantStatus(phase: .loading("تُفحص الدعوة…")) }
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(ZimamType.callout)
                            .foregroundStyle(ZimamColor.inkMuted)
                    }
                }

                if let preview {
                    JoinInvitePreviewSection(preview: preview, canJoin: !working && online, onJoin: { join() })
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            .navigationTitle("الانضمام بدعوة")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
            .onAppear(perform: appeared)
        }
    }

    // MARK: Actions

    private func appeared() {
        if code != nil { check() } else { fieldFocused = true }
    }

    private func textChanged() {
        preview = nil
        problem = nil
    }

    private func check() {
        guard let code, !working else { return }
        working = true
        problem = nil
        Task {
            do {
                let found = try await session.api.previewInvite(code: code)
                previewCode = code
                withAnimation(.zimam(reduceMotion: reduceMotion)) { preview = found }
            } catch {
                problem = SharingProblem.message(for: error)
            }
            working = false
        }
    }

    private func join() {
        guard let code = previewCode, !working else { return }
        working = true
        Task {
            do {
                _ = try await session.api.acceptInvite(code: code)
                // Brings the project, its sections, tasks and comments to this device.
                await sync.sync()
                dismiss()
            } catch {
                problem = SharingProblem.message(for: error)
            }
            working = false
        }
    }
}

/// «الدعوة»: what the invite offers, and «انضمام».
struct JoinInvitePreviewSection: View {
    let preview: InvitePreview
    let canJoin: Bool
    let onJoin: () -> Void

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        Section("الدعوة") {
            LabeledContent("المشروع", value: preview.projectName)
            LabeledContent("الدور", value: preview.role.arabicName)
            if let inviter = preview.invitedBy, !inviter.isEmpty {
                LabeledContent("من", value: inviter)
            }
            LabeledContent("تنتهي في", value: formatter.dual(preview.expiresDate))
            Text(preview.role.arabicDescription)
                .font(ZimamType.caption)
                .foregroundStyle(ZimamColor.inkMuted)
            Button("انضمام", action: onJoin)
                .buttonStyle(.zimamPrimary)
                .disabled(!canJoin)
        }
    }
}
