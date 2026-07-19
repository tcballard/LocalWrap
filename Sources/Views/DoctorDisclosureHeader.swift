import SwiftUI

struct DoctorDisclosureHeader: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    let summary: String
    let accessibilityIdentifier: String
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.headline)

                Spacer(minLength: 12)

                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityLabel(title)
        .accessibilityValue("\(summary). \(isExpanded ? "Expanded" : "Collapsed")")
        .accessibilityHint(isExpanded ? "Collapses the diagnostic details." : "Expands the diagnostic details.")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func toggle() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        }
    }
}
