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

### Read aloud

The speaker button in the reader's toolbar (`⇧⌘R`) reads the book aloud from the paragraph on screen. The paragraph being read is highlighted, the page follows along, and it carries on into the next chapter (or PDF page). There are controls for pause, previous and next paragraph, and speed, plus lock screen and Control Center controls on iPhone.

Two kinds of voice:

- **Apple voices** (`AVSpeechSynthesizer`): the default. Nothing to download, though the Enhanced and Premium voices from Settings › Accessibility › Spoken Content sound much better than the compact ones.
- **Kokoro** ([Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), Apache 2.0): natural-sounding voices that run on device through [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port. Nothing is bundled: the model downloads once (a few hundred MB) when you tap "Download Kokoro voices" in the voice picker, and you can remove it there too. English only for now.

FluidAudio's maintainers flag an Apple Core ML bug on iOS 26.4 and later, iOS 27 included, and on macOS 26.4–26.5. It can crash long Kokoro sessions, and the voice picker warns about it on those versions. If Kokoro fails to load or speak, Munshi switches to the Apple voice and keeps reading.

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
  Speech/     read aloud: playback controller, Apple and Kokoro voices, voice picker
MunshiTests/  Swift Testing unit tests and a sample EPUB fixture
```

Everything that isn't a PDF becomes a `Publication`: a list of HTML files in reading order plus a table of contents. Imported books live in `Application Support/Munshi/Books/<id>/`. The only third-party dependency is FluidAudio (Swift Package Manager), used for the optional Kokoro voices. The ZIP reader uses Apple's Compression framework.

## Next up

- Reading web pages: fetch an article, extract the readable content, and save it as a `Publication` so it uses the same reader.
- Paginated (page-turn) layout as an alternative to scrolling.
- Highlights, notes and bookmarks.
- iCloud sync of the library and reading positions.
