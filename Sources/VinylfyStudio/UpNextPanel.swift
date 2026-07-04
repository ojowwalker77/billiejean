import SwiftUI
import AppKit
import PlayerBridge

// MARK: - Up Next panel (the queue slide-over)
//
// A right-edge slide-over glass card — ONE surface, no nested boxes — listing
// the standalone player's queue. An engraved "UP NEXT" header with a live count,
// then a scroll of 40pt rows: artwork thumb · title over artist. The CURRENT
// entry carries the one accent element in the cluster: a 4pt leading dot. A row
// click flushes any banked effect audio and jumps the helper's queue.
//
// Data: the queue is fetched on appear and re-fetched whenever the played track
// moves — keyed off `studio.trackLine` via `.task(id:)`, no polling loop.

@available(macOS 14.2, *)
struct UpNextPanel: View {
    @Bindable var model: MainViewModel

    /// Panel width — the overlay's own layout number (not a chrome-grid pill).
    private let panelWidth: CGFloat = 300
    private let rowHeight: CGFloat = 40

    @State private var entries: [PlayerQueueEntry] = []

    private var studio: StudioViewModel { model.studio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Theme.Palette.separator)
                .frame(height: 1)
                .padding(.horizontal, 12)
            list
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .composerPopupSurface(radius: WindowChrome.radius)
        .shadow(color: Theme.Shadow.menu.color,
                radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, WindowChrome.edgeInset)
        .padding(.bottom, WindowChrome.edgeInset)
        .padding(.trailing, WindowChrome.edgeInset)
        // Re-fetch whenever the played track moves (the current entry advanced).
        .task(id: studio.trackLine) { await refresh() }
    }

    // MARK: Header — engraved caption + queue count

    private var header: some View {
        HStack(spacing: 6) {
            Text("UP NEXT")
                .font(WindowChrome.captionFont)
                .tracking(1.4)
                .foregroundStyle(Theme.Palette.body)
            Spacer(minLength: 8)
            if !entries.isEmpty {
                Text("\(entries.count)")
                    .font(WindowChrome.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.Palette.printedInk)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    emptyRow
                } else {
                    ForEach(entries) { entry in
                        UpNextRow(
                            entry: entry,
                            artworkData: { await model.standalone.artworkData(urlString: $0) },
                            onTap: { model.jumpToQueueEntry(entry) }
                        )
                        .frame(height: rowHeight)
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
    }

    private var emptyRow: some View {
        Text("Queue is empty")
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.printedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
    }

    private func refresh() async {
        entries = await model.standalone.queueEntries() ?? []
    }
}

// MARK: - Queue row

@available(macOS 14.2, *)
struct UpNextRow: View {
    let entry: PlayerQueueEntry
    let artworkData: (String) async -> Data?
    let onTap: () -> Void

    @State private var hovering = false
    @State private var artwork: NSImage?

    var body: some View {
        Button(action: { Haptics.tap(); onTap() }) {
            HStack(spacing: 10) {
                // The ONE accent element in this cluster: a 4pt dot leading the
                // current entry (no wash, no fill — just the mark).
                Circle()
                    .fill(entry.isCurrent ? Theme.Palette.accent : .clear)
                    .frame(width: 4, height: 4)
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(WindowChrome.labelFont)
                        .foregroundStyle(Theme.Palette.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.artist)
                        .font(WindowChrome.captionFont)
                        .foregroundStyle(Theme.Palette.printedInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        .task(id: entry.artworkURL) { await loadArtwork() }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if hovering {
            RoundedRectangle(cornerRadius: WindowChrome.inBarHoverRadius, style: .continuous)
                .fill(Theme.Palette.hoverWash)
        }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.Palette.chromeDivider)
            .frame(width: 28, height: 28)
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
    }

    private func loadArtwork() async {
        guard artwork == nil, let key = entry.artworkURL else { return }
        guard let data = await artworkData(key),
              let image = NSImage(data: data) else { return }
        artwork = image
    }
}
