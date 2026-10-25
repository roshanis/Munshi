import SwiftData
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, added

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recently Read"
        case .title: "Title"
        case .author: "Author"
        case .added: "Recently Added"
        }
    }

    func sorted(_ books: [Book]) -> [Book] {
        switch self {
        case .recent:
            books.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .title:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            books.sorted { ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending }
        case .added:
            books.sorted { $0.addedAt > $1.addedAt }
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query private var books: [Book]

    @AppStorage("library.sort") private var sort: LibrarySort = .recent
    @State private var path: [Book] = []
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var importing = 0
    @State private var importErrors: [String] = []
    @State private var bookToDelete: Book?

    private var visibleBooks: [Book] {
        let filtered = searchText.isEmpty ? books : books.filter {
            $0.title.localizedStandardContains(searchText)
                || ($0.author?.localizedStandardContains(searchText) ?? false)
        }
        return sort.sorted(filtered)
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 24, alignment: .top)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Book.self) { ReaderView(book: $0) }
            .toolbar { toolbar }
            .searchable(text: $searchText, prompt: "Search titles and authors")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: BookFormat.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): importErrors = [error.localizedDescription]
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            importFiles(fileURLs)
            return !fileURLs.isEmpty
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            importFiles([url], openWhenDone: true)
        }
        .alert(
            "Couldn't import",
            isPresented: Binding(get: { !importErrors.isEmpty }, set: { if !$0 { importErrors = [] } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrors.joined(separator: "\n"))
        }
        .confirmationDialog(
            "Remove \"\(bookToDelete?.title ?? "")\" from your library?",
            isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let bookToDelete { delete(bookToDelete) }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(visibleBooks) { book in
                    NavigationLink(value: book) {
                        BookCardView(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            bookToDelete = book
                        } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if !searchText.isEmpty, visibleBooks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "books.vertical")
        } description: {
            Text("Add EPUB books, PDFs, or text files to start reading.")
        } actions: {
            Button("Add Books") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if importing > 0 {
                ProgressView().controlSize(.small)
            }
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button {
                showingImporter = true
            } label: {
                Label("Add Books", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }

    private func importFiles(_ urls: [URL], openWhenDone: Bool = false) {
        for url in urls {
            importing += 1
            Task {
                defer { importing -= 1 }
                do {
                    let book = try await BookImporter.importBook(from: url, into: context)
                    if openWhenDone { path = [book] }
                } catch {
                    importErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private func delete(_ book: Book) {
        path.removeAll { $0.id == book.id }
        CoverCache.shared.remove(book.id)
        BookStorage.removeFiles(for: book.id)
        context.delete(book)
        try? context.save()
    }
}
