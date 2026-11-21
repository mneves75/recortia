import Domain
import Features
import SwiftUI

/// The accessible object list (FR-14, UX-01): every object topmost first, with its type symbol
/// and its security status in text. Selecting a row selects the object; dragging a row reorders
/// it within its own stack; the context menu mirrors the Arrange menu.
struct EditorSidebarView: View {
    let model: EditorModel

    var body: some View {
        let items = model.listItems
        List(selection: Binding(get: { model.selection }, set: { model.setSelection($0) })) {
            Section {
                ForEach(items) { item in
                    ObjectRow(item: item)
                        .tag(item.id)
                        .contextMenu { contextMenu(for: item.id) }
                }
                .onMove { source, destination in move(items, source, destination) }
            } header: {
                Text(String(localized: "Objects", table: "Editor"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(String(localized: "Objects", table: "Editor"))
        .overlay {
            if items.isEmpty {
                Text(String(localized: "No objects yet.", table: "Editor"))
                    .foregroundStyle(.secondary)
                    .padding(DesignTokens.Space.l)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(String(localized: "\(items.count) objects", table: "Editor"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Space.m)
                .padding(.vertical, DesignTokens.Space.s)
                .accessibilityIdentifier("sidebar.count")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func contextMenu(for id: EditorItemID) -> some View {
        EditorArrangeMenuItems(isAvailable: model.textEditing == nil, showsShortcuts: false) { command in
            if !model.selection.contains(id) { model.select(id) }
            command.perform(on: model)
        }
        Divider()
        Button(String(localized: "Delete", table: "Editor")) {
            if !model.selection.contains(id) { model.select(id) }
            model.deleteSelection()
        }
        .disabled(model.textEditing != nil)
    }

    /// A drop between rows moves the object past the rows of its own stack it crosses: the list
    /// is topmost first, so moving up brings it forward.
    private func move(_ items: [EditorListItem], _ source: IndexSet, _ destination: Int) {
        guard source.count == 1, let from = source.first, items.indices.contains(from) else { return }
        let moved = items[from].id
        let crossed: ArraySlice<EditorListItem> =
            destination < from
            ? items[destination..<from] : items[(from + 1)..<min(max(destination, from + 1), items.count)]
        let steps = crossed.filter { Self.sameStack($0.id, moved) }.count
        model.moveItem(moved, by: destination < from ? steps : -steps)
    }

    private static func sameStack(_ a: EditorItemID, _ b: EditorItemID) -> Bool {
        switch (a, b) {
        case (.layer, .layer), (.obfuscation, .obfuscation), (.annotation, .annotation), (.mask, .mask),
            (.callout, .callout):
            true
        default: false
        }
    }
}

private struct ObjectRow: View {
    let item: EditorListItem

    var body: some View {
        HStack(spacing: DesignTokens.Space.s) {
            Image(systemName: EditorStrings.symbol(item.kind))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(EditorStrings.label(item))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: DesignTokens.Space.xs)
            if let badge = EditorStrings.securityBadge(item.kind) {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Space.xs)
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control).stroke(.separator))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
