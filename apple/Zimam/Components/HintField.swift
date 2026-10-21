import SwiftUI

/// A form's text field whose title is only a hint («عنوان المهمة»), not a label. On the Mac a
/// grouped form puts a field's title beside it as a label, which squeezes the text and reads as a
/// second value; with these the title is the field's prompt, and `.labelsHidden()` at the call
/// site hides the label (VoiceOver still reads it), as on the iPhone.
extension TextField where Label == Text {
    init(hint: LocalizedStringKey, text: Binding<String>, axis: Axis = .horizontal) {
        self.init(text: text, prompt: Text(hint), axis: axis) { Text(hint) }
    }
}

extension SecureField where Label == Text {
    init(hint: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text, prompt: Text(hint)) { Text(hint) }
    }
}
