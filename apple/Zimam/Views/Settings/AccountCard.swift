import PhotosUI
import SwiftUI
import ZimamKit

/// The top of settings: the account's photo and name, which the user can change here, and the
/// email it signed in with. The photo is kept on the server (`AvatarStore`), so every device and
/// the account menu show it.
struct AccountCard: View {
    @Environment(SessionStore.self) private var session

    @State private var photoItem: PhotosPickerItem?
    @State private var nameDraft = ""
    @State private var failure: String?
    @FocusState private var editingName: Bool

    private var hasPhoto: Bool { AvatarStore.shared.data != nil }

    var body: some View {
        Section {
            HStack(spacing: ZimamSpacing.space4) {
                AvatarView(name: session.user?.name, size: ZimamSpacing.space11 * 1.5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                    TextField("اسمك", text: $nameDraft)
                        .font(ZimamType.headline)
                        .focused($editingName)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                        .accessibilityLabel("الاسم")
                    if let email = session.user?.email {
                        Text(email)
                            .font(ZimamType.caption)
                            .foregroundStyle(ZimamColor.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, ZimamSpacing.space2)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(hasPhoto ? "تغيير الصورة" : "إضافة صورة", systemImage: "photo")
            }
            .disabled(AvatarStore.shared.isSaving)
            .frame(minHeight: ZimamSpacing.space11)
            if hasPhoto {
                Button("إزالة الصورة", systemImage: "trash", role: .destructive) {
                    Task {
                        let removed = await AvatarStore.shared.remove(session: session)
                        failure = removed ? nil : "تعذّر حذف الصورة. تحقّق من الاتصال وحاول مرة أخرى."
                    }
                }
                .disabled(AvatarStore.shared.isSaving)
                .frame(minHeight: ZimamSpacing.space11)
            }
            if AvatarStore.shared.isSaving {
                ProgressView("جارٍ حفظ الصورة…")
                    .font(ZimamType.callout)
                    .frame(minHeight: ZimamSpacing.space11)
            }
        } footer: {
            if let failure {
                Text(failure)
                    .foregroundStyle(ZimamColor.priorityHigh)
            }
        }
        .onAppear { nameDraft = session.user?.name ?? "" }
        // Leaving the field saves the name, as pressing «تم» does.
        .onChange(of: editingName) { _, editing in
            if !editing { saveName() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    failure = "تعذّر فتح الصورة. اختر صورة أخرى."
                    return
                }
                let saved = await AvatarStore.shared.upload(data, session: session)
                failure = saved ? nil : "تعذّر حفظ الصورة. تحقّق من الاتصال وحاول مرة أخرى."
            }
        }
    }

    private func saveName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != (session.user?.name ?? "") else { return }
        Task {
            let saved = await session.updateName(name)
            failure = saved ? nil : "تعذّر حفظ الاسم. تحقّق من الاتصال وحاول مرة أخرى."
            if !saved { nameDraft = session.user?.name ?? "" }
        }
    }
}
