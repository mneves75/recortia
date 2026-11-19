import Domain
import Features
import SwiftUI

/// The accessible object list (FR-14, UX-01): every object topmost first, with its security
/// status in text. Selecting a row selects the object; buttons reorder and delete.
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
            } header: {
                Text(String(localized: "Objects", table: "Editor"))
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(String(localized: "Objects", table: "Editor"))
        .overlay {
            if items.isEmpty {
                Text(String(localized: "No objects yet.", table: "Editor"))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        // Stays below the list on the sidebar's own material instead of a bar of its own.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    model.reorderSelection(.forward)
                } label: {
                    Label(String(localized: "Bring Forward", table: "Editor"), systemImage: "chevron.up")
                }
                .help(String(localized: "Bring Forward", table: "Editor"))
                Button {
                    model.reorderSelection(.backward)
                } label: {
                    Label(String(localized: "Send Backward", table: "Editor"), systemImage: "chevron.down")
                }
                .help(String(localized: "Send Backward", table: "Editor"))
                Spacer()
                Button {
                    model.deleteSelection()
                } label: {
                    Label(String(localized: "Delete", table: "Editor"), systemImage: "trash")
                }
                .help(String(localized: "Delete (⌫)", table: "Editor"))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.selection.isEmpty)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func contextMenu(for id: EditorItemID) -> some View {
        Button(String(localized: "Bring to Front", table: "Editor")) {
            model.select(id)
            model.reorderSelection(.front)
        }
        Button(String(localized: "Send to Back", table: "Editor")) {
            model.select(id)
            model.reorderSelection(.back)
        }
        Button(String(localized: "Duplicate", table: "Editor")) {
            model.select(id)
            model.duplicateSelection()
        }
        Divider()
        Button(String(localized: "Delete", table: "Editor")) {
            model.select(id)
            model.deleteSelection()
        }
    }
}

private struct ObjectRow: View {
    let item: EditorListItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EditorStrings.symbol(item.kind))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(EditorStrings.label(item))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let badge = EditorStrings.securityBadge(item.kind) {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: EditorMetrics.chipRadius).stroke(.separator))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
