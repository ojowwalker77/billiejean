import SwiftUI
import AppKit
import PlayerBridge

// MARK: - Search overlay (catalog command palette)
//
// A command-palette over the catalog: a centered floating glass card over a
// dimming scrim, summoned by ⌘K or the command-bar magnifyingglass. The card IS
// the chrome (one surface, no nested boxes): a search field on top, up to 8
// result rows below, height animating with the signature spring.

@available(macOS 14.2, *)
struct SearchOverlay: View {
    @Bindable var model: MainViewModel
    @Binding var isPresented: Bool

    /// Card metrics — the overlay's own layout numbers (not chrome-grid pills).
    private let cardWidth: CGFloat = 560
    private let maxRows = 8
    private let rowHeight: CGFloat = 44

    @State private var term = ""
    @State private var results: [CatalogSong] = []
    /// Selected row for keyboard navigation (nil = none highlighted).
    @State private var selection: Int?
    /// A completed search returned zero rows (drives the quiet "No matches" row).
    @State private var searchedEmpty = false
    /// The in-flight debounced search, cancelled on each keystroke.
    @State private var searchTask: Task<Void, Never>?

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Dimming scrim — click anywhere off the card to dismiss.
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            GeometryReader { geo in
                card
                    .frame(width: cardWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, geo.size.height * 0.18)
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: term) { _, new in scheduleSearch(new) }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            field
            if showsResults {
                Rectangle()
                    .fill(Theme.Palette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                resultsList
            }
        }
        .composerPopupSurface(radius: WindowChrome.radius)
        .shadow(color: Theme.Shadow.menu.color,
                radius: Theme.Shadow.menu.radius, y: Theme.Shadow.menu.y)
        .animation(ChromeMotion.spring, value: showsResults)
        .animation(ChromeMotion.spring, value: results)
        // The card owns the keyboard: arrows move, Return plays, Esc dismisses.
        // These fire for keys the focused TextField doesn't consume (the arrows,
        // Return, and Esc all bubble), so typing stays with the field.
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.return) { playSelection(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    /// Below-field content shows only once a non-empty search has run.
    private var showsResults: Bool { !results.isEmpty || searchedEmpty }

    // MARK: Search field (the card IS the chrome — no field surface)

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.printedInk)
            TextField("Search Apple Music", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.body)
                .focused($fieldFocused)
                .onSubmit { playSelection() }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: Results

    private var resultsList: some View {
        VStack(spacing: 0) {
            if results.isEmpty, searchedEmpty {
                noMatchesRow
            } else {
                ForEach(Array(results.prefix(maxRows).enumerated()), id: \.element.id) { pair in
                    SearchResultRow(
                        song: pair.element,
                        selected: selection == pair.offset,
                        artworkData: { await model.standalone.artworkData(urlString: $0) },
                        onPlay: { play(pair.element) }
                    )
                    .frame(height: rowHeight)
                }
            }
        }
        .padding(6)
    }

    private var noMatchesRow: some View {
        Text("No matches")
            .font(WindowChrome.labelFont)
            .foregroundStyle(Theme.Palette.printedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
    }

    // MARK: Debounced search

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Empty / too-short term: the card hugs the field, nothing below it.
        guard trimmed.count >= 2 else {
            results = []
            searchedEmpty = false
            selection = nil
            return
        }

        searchTask = Task {
            // 300ms debounce after the last keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let found = await model.standalone.searchCatalog(term: trimmed, limit: maxRows) ?? []
            if Task.isCancelled { return }
            // Keep previous results in-flight; only replace on completion.
            results = found
            searchedEmpty = found.isEmpty
            selection = found.isEmpty ? nil : 0
        }
    }

    // MARK: Actions

    private func play(_ song: CatalogSong) {
        model.playSearchResult(song)
        dismiss()
    }

    private func playSelection() {
        guard let selection, results.indices.contains(selection) else { return }
        play(results[selection])
    }

    private func moveSelection(_ delta: Int) {
        let shown = min(results.count, maxRows)
        guard shown > 0 else { return }
        let current = selection ?? (delta > 0 ? -1 : 0)
        selection = (current + delta + shown) % shown
    }

    private func dismiss() {
        searchTask?.cancel()
        withAnimation(ChromeMotion.dismiss) { isPresented = false }
    }
}

// MARK: - Result row

@available(macOS 14.2, *)
struct SearchResultRow: View {
    let song: CatalogSong
    let selected: Bool
    let artworkData: (String) async -> Data?
    let onPlay: () -> Void

    @State private var hovering = false
    @State private var artwork: NSImage?

    var body: some View {
        Button(action: { Haptics.tap(); onPlay() }) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(WindowChrome.labelFont)
                        .foregroundStyle(Theme.Palette.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(secondary)
                        .font(WindowChrome.captionFont)
                        .foregroundStyle(Theme.Palette.printedInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(Self.time(song.durationSeconds))
                    .font(WindowChrome.captionFont.monospacedDigit())
                    .foregroundStyle(Theme.Palette.printedInk)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                // The ONE accent element in this cluster: a 2pt leading bar on
                // the keyboard-selected row.
                if selected {
                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: 2, height: 22)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ChromeMotion.hover, value: hovering)
        .animation(ChromeMotion.hover, value: selected)
        .task(id: song.artworkURL) { await loadArtwork() }
    }

    private var secondary: String {
        song.albumTitle.isEmpty ? song.artist : "\(song.artist) — \(song.albumTitle)"
    }

    @ViewBuilder
    private var rowBackground: some View {
        if hovering || selected {
            RoundedRectangle(cornerRadius: WindowChrome.inBarHoverRadius, style: .continuous)
                .fill(Theme.Palette.hoverWash)
        }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.Palette.chromeDivider)
            .frame(width: 32, height: 32)
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
    }

    private func loadArtwork() async {
        guard artwork == nil, let key = song.artworkURL else { return }
        guard let data = await artworkData(key),
              let image = NSImage(data: data) else { return }
        artwork = image
    }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
