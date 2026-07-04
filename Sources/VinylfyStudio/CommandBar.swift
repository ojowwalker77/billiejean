import SwiftUI
import AppKit

/// THE one bottom command bar, always visible in both states. Clusters
/// separated by dividers, wrapped in a single `.chromePill()`.
@available(macOS 14.2, *)
struct CommandBar: View {
    @Bindable var model: MainViewModel
    @Binding var showSettings: Bool
    @Binding var showSearch: Bool
    var showWidgetOnMinimize: Binding<Bool>
    /// Canvas glass: 0 = solid (and free — the desktop blur only mounts above 0).
    @AppStorage("billiejean.canvasTransparency") private var canvasTransparency = 0.0

    private var studio: StudioViewModel { model.studio }

    var body: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            transportCluster
            BarDivider()
            progressCluster
            BarDivider()
            vinylCluster
            BarDivider()
            settingsCluster
        }
        .chromePill()
        .shadow(color: Theme.Shadow.bar.color, radius: Theme.Shadow.bar.radius, y: Theme.Shadow.bar.y)
    }

    // MARK: - Transport

    private var transportCluster: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            ChromeIconButton(symbol: "backward.fill", help: "Previous  ⌘←") {
                model.previousTrack()
            }
            ChromeIconButton(symbol: isPlaying ? "pause.fill" : "play.fill",
                             help: "Play / Pause  Space") {
                model.playPause()
            }
            ChromeIconButton(symbol: "forward.fill", help: "Next  ⌘→") {
                model.nextTrack()
            }
        }
    }

    private var isPlaying: Bool { studio.snapshot?.isPlaying ?? false }

    // MARK: - Progress

    private var progressCluster: some View {
        HStack(spacing: 8) {
            Text(Self.time(studio.positionSeconds))
                .font(WindowChrome.labelFont.monospacedDigit())
                .foregroundStyle(Theme.Palette.chromeText)
                .frame(width: 40, alignment: .trailing)

            SeekSlider(
                position: studio.positionSeconds,
                duration: studio.durationSeconds,
                onSeek: { model.seek(toSeconds: $0) }
            )

            Text(Self.time(studio.durationSeconds))
                .font(WindowChrome.labelFont.monospacedDigit())
                .foregroundStyle(Theme.Palette.chromeText)
                .frame(width: 40, alignment: .leading)
        }
    }

    // MARK: - Vinyl (A/B + three mini-knobs)

    private var vinylCluster: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            // A/B toggle: accent GLYPH when VINYL active (no fill, §9 rule 4).
            ChromeIconButton(symbol: "waveform",
                             help: studio.bypass ? "Original — tap for Vinyl" : "Vinyl — tap for Original",
                             active: !studio.bypass) {
                studio.toggleBypass()
            }

            PhysicalKnob(help: "Noise — scroll to adjust, double-click to reset",
                         value: Binding(get: { studio.noise }, set: { studio.noise = $0 }),
                         onReset: studio.resetNoise, size: 34)
            PhysicalKnob(help: "Main — scroll to adjust, double-click to reset",
                         value: Binding(get: { studio.main }, set: { studio.main = $0 }),
                         onReset: studio.resetMain, size: 34)
            PhysicalKnob(help: "Volume — scroll to adjust, double-click to reset",
                         value: Binding(get: { studio.volume }, set: { studio.volume = $0 }),
                         onReset: studio.resetVolume, size: 34)
        }
    }

    // MARK: - Settings

    private var settingsCluster: some View {
        HStack(spacing: WindowChrome.itemSpacing) {
            // Catalog search — available only while the standalone bridge is up.
            if model.standalone.isConnected {
                ChromeIconButton(symbol: "magnifyingglass", help: "Search  ⌘K",
                                 active: showSearch) {
                    showSearch.toggle()
                }
            }
            settingsButton
        }
    }

    private var settingsButton: some View {
        ChromeIconButton(symbol: "gearshape", help: "Settings  ⌘,", active: showSettings) {
            showSettings.toggle()
        }
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            GlassMenu {
                GlassMenuRow(title: "Vinyl", checked: studio.effectMode == .vinyl) {
                    studio.effectMode = .vinyl
                }
                GlassMenuRow(title: "Slowed + Reverb", checked: studio.effectMode == .slowed) {
                    studio.effectMode = .slowed
                }
                Rectangle()
                    .fill(Theme.Palette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                GlassMenuToggleRow(title: "Show Widget on Minimize",
                                   isOn: showWidgetOnMinimize)
                Rectangle()
                    .fill(Theme.Palette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                GlassMenuSliderRow(title: "Background Glass",
                                   value: $canvasTransparency)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
