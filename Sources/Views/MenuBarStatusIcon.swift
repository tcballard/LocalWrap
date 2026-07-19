import SwiftUI

struct MenuBarStatusIcon: View {
    let snapshot: MenuCommandCenterSnapshot

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .overlay(alignment: .bottomTrailing) { statusMark }
            .accessibilityLabel(snapshot.statusItemState.accessibilityLabel)
            .accessibilityValue(snapshot.statusLabel)
    }

    @ViewBuilder
    private var statusMark: some View {
        switch snapshot.statusItemState {
        case .idle:
            EmptyView()
        case .running:
            Circle()
                .frame(width: 4, height: 4)
                .offset(x: 1, y: 1)
        case .ready:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .offset(x: 2, y: 2)
        case .attention:
            Image(systemName: "exclamationmark")
                .font(.system(size: 7, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .offset(x: 2, y: 2)
        }
    }
}
