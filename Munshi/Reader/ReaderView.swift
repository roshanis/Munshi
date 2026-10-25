import SwiftUI

/// Opens a book in the reader that fits its format.
struct ReaderView: View {
    let book: Book

    var body: some View {
        Group {
            switch book.format {
            case .pdf:
                PDFReaderView(book: book)
            case .epub, .text, .html:
                WebReaderView(book: book)
            }
        }
        .navigationTitle(book.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { book.lastOpenedAt = .now }
    }
}

/// Theme, font and size controls shared by every reader.
struct AppearanceControls: View {
    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.font") private var font: ReaderFont = .publisher
    @AppStorage("reader.fontScale") private var fontScale = 1.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.5

    var showsTextOptions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Theme", selection: $theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if showsTextOptions {
                HStack {
                    Button {
                        fontScale = max(ReaderAppearance.fontScaleRange.lowerBound, fontScale - 0.1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .accessibilityLabel("Smaller text")
                    Text("\(Int((fontScale * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 52)
                    Button {
                        fontScale = min(ReaderAppearance.fontScaleRange.upperBound, fontScale + 0.1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .accessibilityLabel("Larger text")
                }
                .buttonStyle(.bordered)

                Picker("Font", selection: $font) {
                    ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Line spacing").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $lineHeight, in: 1.2...2.0, step: 0.1)
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}

/// A list of table-of-contents entries with the current one highlighted.
struct ContentsList<Entry: Identifiable>: View {
    let entries: [Entry]
    let title: (Entry) -> String
    let level: (Entry) -> Int
    let isCurrent: (Entry) -> Bool
    let select: (Entry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    Button {
                        select(entry)
                        dismiss()
                    } label: {
                        HStack {
                            Text(title(entry))
                                .fontWeight(isCurrent(entry) ? .semibold : .regular)
                                .foregroundStyle(isCurrent(entry) ? Color.accentColor : Color.primary)
                                .padding(.leading, CGFloat(min(level(entry), 4)) * 16)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(entry.id)
                }
                .onAppear {
                    if let current = entries.last(where: isCurrent) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Contents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}
