# Munshi

Munshi is a reader for iPhone, iPad and Mac. It keeps a library of your books and documents and remembers where you left off in each one.

## What it reads today

| Format | How it's shown |
| --- | --- |
| EPUB (2 and 3) | Unpacked and rendered chapter by chapter in a themed web view, with the book's table of contents |
| PDF | PDFKit, with the document outline as contents |
| Plain text and Markdown | Converted to a single HTML page; `#` headings become the contents |
| HTML files | Rendered in the same web reader |

Reader features: light, sepia, dark and automatic themes, text size, font and line spacing, chapter navigation (`⌘[` / `⌘]`, `⌘T` for contents), and saved reading progress. The library supports search, sorting, drag and drop on the Mac, and "Open in Munshi" from Files or Finder.

## Building

Requirements: Xcode 16 or later. The app targets iOS 17 and macOS 14.

1. Open `Munshi.xcodeproj`.
2. Pick the **Munshi** scheme and either "My Mac" or an iPhone simulator.
3. To run on a real iPhone, choose your team under Signing & Capabilities.

From the command line:

```sh
# macOS
xcodebuild -scheme Munshi -destination 'platform=macOS' test
# iOS simulator
xcodebuild -scheme Munshi -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## How it's put together

```
Munshi/
  App/        app entry point
  Models/     Book (SwiftData), on-disk storage, importer
  Formats/    ZIP reader, EPUB parser, text-to-HTML, the shared Publication model
  Library/    library grid, covers
  Reader/     web reader (EPUB/text/HTML), PDF reader, appearance settings
MunshiTests/  Swift Testing unit tests and a sample EPUB fixture
```

Everything that isn't a PDF becomes a `Publication`: a list of HTML files in reading order plus a table of contents. Imported books live in `Application Support/Munshi/Books/<id>/`. There are no third-party dependencies; the ZIP reader uses Apple's Compression framework.

## Next up

- Reading web pages: fetch an article, extract the readable content, and save it as a `Publication` so it uses the same reader.
- Paginated (page-turn) layout as an alternative to scrolling.
- Highlights, notes and bookmarks.
- iCloud sync of the library and reading positions.
