import SwiftUI
import ZimamKit

/// «سياسة الخصوصية» and «شروط الاستخدام» at the end of Settings, opened on the website
/// (web/public/privacy/ and web/public/terms/).
struct LegalLinksSection: View {
    var body: some View {
        Section("عن زمام") {
            Link(destination: ZimamWeb.privacyPolicy) {
                Label("سياسة الخصوصية", systemImage: "hand.raised")
            }
            .frame(minHeight: ZimamSpacing.space11)
            Link(destination: ZimamWeb.terms) {
                Label("شروط الاستخدام", systemImage: "doc.text")
            }
            .frame(minHeight: ZimamSpacing.space11)
        }
    }
}
