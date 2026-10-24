import SwiftUI

/// Sizes of the iPad and Mac layout, built from the spacing tokens the way the web app
/// builds its own (`--sidebar: calc(var(--space-11) * 5)` in web/public/app/app.css).
/// Change the tokens in design/tokens.json, not these multiples.
enum ZimamLayout {
    /// A kanban column: six touch targets wide (264pt), the width the KanbanColumn
    /// preview gives its columns at the least.
    static let kanbanColumnWidth = ZimamSpacing.space11 * 6
    /// The sidebar on the iPad and the Mac: as on the web at the narrowest.
    static let sidebarMinWidth = ZimamSpacing.space11 * 5
    static let sidebarIdealWidth = ZimamSpacing.space11 * 6
    /// The task list column's usual width (also the inspector's ideal width).
    static let listColumnIdealWidth = ZimamSpacing.space11 * 9
    /// The task details column at its narrowest.
    static let detailColumnMinWidth = ZimamSpacing.space11 * 7
    /// The smallest Mac window that still fits the sidebar, the content and the inspector.
    static let windowMinWidth = ZimamSpacing.space11 * 20
    static let windowMinHeight = ZimamSpacing.space11 * 13
    /// The Mac Settings window.
    static let settingsWidth = ZimamSpacing.space11 * 11
    /// The focus ring and the drop target: a solid 2pt line (design/README.md «الحالات والحركة»).
    static let focusRingWidth = ZimamSpacing.space1 / 2
}
