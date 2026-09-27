import SwiftUI

/// Everything shown when the notch is open: a status header beside the
/// camera, the current page, and page dots.
struct OpenNotchView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(vm: vm)
                .frame(height: vm.notchSize.height)

            ZStack {
                switch vm.visiblePage {
                case .home:
                    HomeView(vm: vm)
                        .transition(.opacity.combined(with: .offset(x: -24)))
                case .nowPlaying:
                    if let info = vm.nowPlaying.info {
                        NowPlayingView(nowPlaying: vm.nowPlaying, info: info)
                            .transition(.opacity.combined(with: .offset(x: 24)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.visiblePage)

            PageDots(vm: vm)
                .frame(height: 20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

/// Date on the left of the camera; status icons on the right.
private struct HeaderView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: vm.notchSize.width + 20) // camera

            HStack(spacing: 10) {
                if let focus = vm.focus.current {
                    Image(systemName: focus.symbol)
                        .foregroundStyle(.indigo)
                        .help(focus.name)
                }
                if vm.privacy.isActive {
                    HStack(spacing: 4) {
                        if vm.privacy.cameraInUse {
                            Image(systemName: "video.fill").foregroundStyle(.green)
                        }
                        if vm.privacy.micInUse {
                            Image(systemName: "mic.fill").foregroundStyle(.orange)
                        }
                    }
                    .help(vm.privacy.micApps.isEmpty ? "In use" : "Mic: " + vm.privacy.micApps.joined(separator: ", "))
                }
                if let battery = vm.battery.status {
                    HStack(spacing: 4) {
                        Text("\(battery.percent)%")
                        Image(systemName: battery.symbolName)
                            .foregroundStyle(battery.isCharging ? .green : battery.isLow ? .red : .white)
                    }
                }
                Button { vm.showAppMenu?() } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings & Quit")
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Two dots (Home / Now Playing). Only shown when there's more than one page.
private struct PageDots: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 2) {
            if vm.availablePages.count > 1 {
                ForEach(vm.availablePages, id: \.self) { page in
                    Button {
                        vm.select(page)
                    } label: {
                        Capsule()
                            .fill(.white.opacity(page == vm.visiblePage ? 0.9 : 0.3))
                            .frame(width: page == vm.visiblePage ? 14 : 6, height: 6)
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(page == .home ? "Home" : "Now Playing")
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.visiblePage)
    }
}
