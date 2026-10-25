import SwiftUI

struct BookCardView: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(book: book)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .overlay(alignment: .bottom) {
                    if book.progress > 0 {
                        ProgressBar(value: book.progress)
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let author = book.author {
                        Text(author).lineLimit(1)
                        Text("·")
                    }
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if book.progress >= 0.99 { return "Finished" }
        if book.progress > 0 { return "\(Int((book.progress * 100).rounded()))%" }
        return book.format.displayName
    }
}

struct BookCoverView: View {
    let book: Book

    var body: some View {
        if let image = CoverCache.shared.image(for: book.id, data: book.coverData) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            GeneratedCover(title: book.title, author: book.author, seed: book.id)
        }
    }
}

/// A simple typographic cover for books that don't ship one.
private struct GeneratedCover: View {
    let title: String
    let author: String?
    let seed: UUID

    private var hue: Double {
        Double(seed.uuidString.unicodeScalars.reduce(0) { abs($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55), Color(hue: hue, saturation: 0.55, brightness: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 10) {
                Spacer()
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .minimumScaleFactor(0.6)
                if let author {
                    Text(author)
                        .font(.caption)
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(14)
        }
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                Capsule().fill(.white).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
    }
}
