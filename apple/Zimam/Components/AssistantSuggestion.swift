import SwiftUI

/// The assistant's suggestion card. See design/components/AISuggestion.
/// `brandSoft` background, the label in `brandInk`, the content as one or two sentences in
/// the past tense («قسّمت…»), then accept and dismiss. Nothing is applied before accepting.
/// No sparkles or gradients: the identity stays calm.
struct AssistantSuggestion<Content: View>: View {
    var label = "اقتراح المساعد"
    var acceptLabel = "اعتماد"
    var dismissLabel = "تجاهل"
    /// An optional third action between accept and dismiss, such as «تعديل».
    var secondaryLabel: String?
    var onAccept: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onDismiss: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
            Text(label)
                .font(ZimamType.caption.weight(.semibold))
                .foregroundStyle(ZimamColor.brandInk)
                .accessibilityAddTraits(.isHeader)
            content()
                .font(ZimamType.callout)
                .foregroundStyle(ZimamColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if onAccept != nil || onSecondary != nil || onDismiss != nil {
                HStack(spacing: ZimamSpacing.space2) {
                    if let onAccept {
                        Button(acceptLabel, action: onAccept).buttonStyle(.zimamPrimary)
                    }
                    if let secondaryLabel, let onSecondary {
                        Button(secondaryLabel, action: onSecondary).buttonStyle(.zimamSecondary)
                    }
                    if let onDismiss {
                        Button(dismissLabel, action: onDismiss).buttonStyle(.zimamQuiet)
                    }
                }
                .padding(.top, ZimamSpacing.space1)
            }
        }
        .padding(ZimamSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZimamColor.brandSoft, in: RoundedRectangle(cornerRadius: ZimamRadius.radiusLg))
        .accessibilityElement(children: .contain)
    }
}

/// What an assistant request shows while it runs or after it fails, in the card's place.
/// Failures never block: the screen keeps working without the assistant.
struct AssistantStatus: View {
    enum Phase: Equatable {
        case loading(String)
        case failed(String)
    }

    let phase: Phase
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        switch phase {
        case .loading(let text):
            HStack(spacing: ZimamSpacing.space2) {
                ProgressView()
                Text(text)
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: ZimamSpacing.space11, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: ZimamSpacing.space2) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(ZimamType.callout)
                    .foregroundStyle(ZimamColor.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if onRetry != nil || onClose != nil {
                    HStack(spacing: ZimamSpacing.space2) {
                        if let onRetry {
                            Button("إعادة المحاولة", action: onRetry).buttonStyle(.zimamSecondary)
                        }
                        if let onClose {
                            Button("إغلاق", action: onClose).buttonStyle(.zimamQuiet)
                        }
                    }
                }
            }
        }
    }
}
