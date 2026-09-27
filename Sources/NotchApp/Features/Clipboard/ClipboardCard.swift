import SwiftUI

/// Home page card listing recently copied text. Click a row to copy it again.
struct ClipboardCard: View {
    @ObservedObject var clipboard: ClipboardService
    let isEnabled: Bool

    @State private var copiedID: UUID?
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardTitle(title: "Clipboard", systemImage: "doc.on.clipboard")
                Spacer()
                if !clipboard.items.isEmpty {
                    Button { clipboard.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear history")
                }
            }

            if !isEnabled {
                placeholder("Clipboard history is off.\nTurn it on from the menu bar icon.")
            } else if clipboard.items.isEmpty {
                placeholder("Text you copy will\nshow up here.")
            } else if isSnapshot {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }
            }
        }
        .cardStyle()
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(clipboard.items) { item in
                ClipboardRow(item: item, isCopied: copiedID == item.id) {
                    clipboard.copy(item)
                    copiedID = item.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        if copiedID == item.id { copiedID = nil }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Show multi-line text on one line.
                Text(item.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isCopied {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isHovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Click to copy")
    }
}
