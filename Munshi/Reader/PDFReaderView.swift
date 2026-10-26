import PDFKit
import SwiftUI

/// Reader for PDF documents, built on PDFKit.
struct PDFReaderView: View {
    let book: Book

    @State private var document: PDFDocument?
    @State private var pageIndex = 0
    @State private var jumpRequest: Int?
    @State private var showingContents = false
    @State private var showingAppearance = false
    @State private var failed = false
    @State private var readAloud = ReadAloudController()
    @State private var speechSource: PDFSpeechSource?

    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTheme: ReaderTheme { theme.resolved(for: colorScheme) }

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    PDFKitView(
                        document: document,
                        initialPage: pageIndex,
                        jumpRequest: $jumpRequest,
                        backgroundColor: resolvedTheme.background,
                        onPageChange: pageChanged
                    )
                    if readAloud.isActive {
                        ReadAloudBar(
                            controller: readAloud,
                            foreground: resolvedTheme.foreground,
                            background: resolvedTheme.background
                        )
                    }
                    footer(pageCount: document.pageCount)
                }
                .background(resolvedTheme.background.ignoresSafeArea())
                .toolbar { toolbar(document) }
                .sheet(isPresented: $showingContents) {
                    ContentsList(
                        entries: PDFOutlineItem.flatten(document),
                        title: \.title,
                        level: \.level,
                        isCurrent: { $0.pageIndex == currentOutlinePage(in: document) },
                        select: { jumpRequest = $0.pageIndex }
                    )
                }
            } else if failed {
                ContentUnavailableView("Can't open this PDF", systemImage: "doc.richtext")
            } else {
                ProgressView()
            }
        }
        .task(id: book.id) {
            pageIndex = Int(book.location ?? "") ?? 0
            document = PDFDocument(url: book.originalFileURL)
            failed = document == nil
            if let document {
                let source = PDFSpeechSource(document: document)
                source.visiblePage = pageIndex
                let jump = $jumpRequest
                source.turnToPage = { jump.wrappedValue = $0 }
                speechSource = source
                readAloud.source = source
                readAloud.nowPlayingTitle = book.title
                readAloud.nowPlayingArtist = book.author
            }
        }
        .onDisappear { readAloud.stop() }
    }

    @ToolbarContentBuilder
    private func toolbar(_ document: PDFDocument) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ReadAloudButton(controller: readAloud)

            Button {
                showingContents = true
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .disabled(document.outlineRoot == nil)
            .keyboardShortcut("t", modifiers: [.command])

            Button {
                showingAppearance.toggle()
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .popover(isPresented: $showingAppearance) {
                AppearanceControls(showsTextOptions: false)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func footer(pageCount: Int) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(pageIndex + 1), total: Double(max(pageCount, 1)))
                .tint(resolvedTheme.foreground.opacity(0.6))
            Text("Page \(pageIndex + 1) of \(pageCount)")
                .font(.caption2)
                .monospacedDigit()
                .opacity(0.7)
        }
        .foregroundStyle(resolvedTheme.foreground)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func pageChanged(_ index: Int, _ count: Int) {
        pageIndex = index
        speechSource?.visiblePage = index
        book.location = String(index)
        book.progress = count > 0 ? Double(index + 1) / Double(count) : 0
        book.lastOpenedAt = .now
    }

    private func currentOutlinePage(in document: PDFDocument) -> Int? {
        PDFOutlineItem.flatten(document).last { $0.pageIndex <= pageIndex }?.pageIndex
    }
}

struct PDFOutlineItem: Identifiable {
    let id: Int
    let title: String
    let level: Int
    let pageIndex: Int

    static func flatten(_ document: PDFDocument) -> [PDFOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var items: [PDFOutlineItem] = []
        func walk(_ outline: PDFOutline, level: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                if let page = child.destination?.page {
                    items.append(PDFOutlineItem(
                        id: items.count,
                        title: child.label ?? "Untitled",
                        level: level,
                        pageIndex: document.index(for: page)
                    ))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return items
    }
}

/// Wraps `PDFView` for SwiftUI on both platforms.
struct PDFKitView {
    let document: PDFDocument
    let initialPage: Int
    @Binding var jumpRequest: Int?
    let backgroundColor: Color
    let onPageChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makePDFView(coordinator: Coordinator) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        if initialPage > 0, let page = document.page(at: initialPage) {
            // Wait for the first layout pass, otherwise PDFView ignores the jump.
            DispatchQueue.main.async { view.go(to: page) }
        }
        coordinator.observe(view) { index in
            onPageChange(index, document.pageCount)
        }
        return view
    }

    private func update(_ view: PDFView, coordinator: Coordinator) {
        coordinator.onPageChange = { onPageChange($0, document.pageCount) }
        #if os(iOS)
        view.backgroundColor = UIColor(backgroundColor)
        #else
        view.backgroundColor = NSColor(backgroundColor)
        #endif
        if let target = jumpRequest {
            if let page = document.page(at: target) {
                view.go(to: page)
            }
            DispatchQueue.main.async { jumpRequest = nil }
        }
    }

    final class Coordinator: NSObject {
        var onPageChange: ((Int) -> Void)?
        private var observer: NSObjectProtocol?

        func observe(_ view: PDFView, onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let view, let page = view.currentPage, let document = view.document else { return }
                self?.onPageChange?(document.index(for: page))
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

#if os(iOS)
extension PDFKitView: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
}
#else
extension PDFKitView: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
}
#endif
