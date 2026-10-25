import SwiftUI

/// Reader for EPUB, text and HTML books.
struct WebReaderView: View {
    let book: Book

    @State private var model: WebReaderModel?
    @State private var loadError: String?
    @State private var showingContents = false
    @State private var showingAppearance = false

    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.font") private var font: ReaderFont = .publisher
    @AppStorage("reader.fontScale") private var fontScale = 1.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.5
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var appearance: ReaderAppearance {
        ReaderAppearance(
            theme: theme.resolved(for: colorScheme),
            font: font,
            fontScale: fontScale,
            lineHeight: lineHeight
        )
    }

    var body: some View {
        Group {
            if let model {
                reader(model)
            } else if let loadError {
                ContentUnavailableView("Can't open this book", systemImage: "book.closed", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task(id: book.id) {
            do {
                let publication = try BookStorage.loadPublication(for: book.id)
                model = WebReaderModel(book: book, publication: publication)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func reader(_ model: WebReaderModel) -> some View {
        VStack(spacing: 0) {
            ChapterWebView(
                model: model,
                request: model.request,
                appearance: appearance,
                openExternal: { openURL($0) }
            )
            .id(model.contentURL)
            bottomBar(model)
        }
        .background(appearance.theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingContents = true
                } label: {
                    Label("Contents", systemImage: "list.bullet")
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button {
                    showingAppearance.toggle()
                } label: {
                    Label("Appearance", systemImage: "textformat.size")
                }
                .popover(isPresented: $showingAppearance) {
                    AppearanceControls()
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .sheet(isPresented: $showingContents) {
            ContentsList(
                entries: model.publication.toc,
                title: \.title,
                level: \.level,
                isCurrent: { $0 == model.currentTOCEntry },
                select: { model.go(to: $0) }
            )
        }
    }

    private func bottomBar(_ model: WebReaderModel) -> some View {
        HStack(spacing: 12) {
            Button {
                model.previousChapter()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: [.command])
            .accessibilityLabel("Previous chapter")

            VStack(spacing: 4) {
                Text(model.currentTOCEntry?.title ?? "Chapter \(model.chapter + 1)")
                    .font(.caption)
                    .lineLimit(1)
                ProgressView(value: model.overallProgress)
                    .progressViewStyle(.linear)
                    .tint(appearance.theme.foreground.opacity(0.6))
                Text("\(Int((model.overallProgress * 100).rounded()))% · \(model.chapter + 1) of \(model.chapterCount)")
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity)

            Button {
                model.nextChapter()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut("]", modifiers: [.command])
            .accessibilityLabel("Next chapter")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appearance.theme.foreground)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(appearance.theme.background)
    }
}
