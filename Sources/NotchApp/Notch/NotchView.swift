import SwiftUI

struct NotchView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let isOpen = vm.state == .open
        let layout = vm.closedLayout
        let closedSize = vm.closedSize
        let size = isOpen ? vm.openSize : closedSize
        let topRadius = isOpen ? NotchShape.openTopRadius : NotchShape.closedTopRadius
        let bottomRadius = isOpen ? NotchShape.openBottomRadius : NotchShape.closedBottomRadius

        ZStack(alignment: .top) {
            // Each state's content is laid out at its full size and revealed by
            // the animating clip shape, so it never re-flows mid-animation.
            if isOpen {
                OpenNotchView(vm: vm)
                    .frame(width: vm.openSize.width, height: vm.openSize.height, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else if layout.wingWidth > 0 {
                ClosedActivityView(vm: vm, layout: layout)
                    .frame(width: closedSize.width, height: closedSize.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.horizontal, topRadius) // room for the ears
        .background(.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            isOpen
                ? .spring(response: 0.42, dampingFraction: 0.78)
                : .spring(response: 0.35, dampingFraction: 1.0),
            value: vm.state
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: layout)
    }
}

/// The closed notch's "live activity": content on either side of the camera.
struct ClosedActivityView: View {
    @ObservedObject var vm: NotchViewModel
    let layout: ClosedLayout

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(width: layout.wingWidth)
            Color.clear
                .frame(width: vm.notchSize.width) // the camera is here
            HStack(spacing: 5) {
                right
                if let dot = layout.privacyDot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
            }
            .frame(width: layout.wingWidth)
        }
    }

    @ViewBuilder private var left: some View {
        switch layout.left {
        case .none:
            Color.clear
        case .artwork:
            ArtworkView(image: vm.nowPlaying.artwork, appIcon: nil, size: vm.notchSize.height - 8, cornerRadius: 5)
        case .icon(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder private var right: some View {
        switch layout.right {
        case .none:
            EmptyView()
        case .bars:
            AudioBarsView(color: vm.nowPlaying.accentColor)
                .frame(width: 18, height: 14)
        case .timer:
            TimerCountdownText(timer: vm.timer)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.orange)
        case .text(let text, let tint):
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
        case .level(let level):
            LevelBar(level: level)
                .frame(width: layout.wingWidth - 24, height: 5)
        }
    }
}

/// A thin horizontal bar for volume/brightness levels.
struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white)
                    .frame(width: geo.size.width * min(max(level, 0), 1))
            }
        }
    }
}
