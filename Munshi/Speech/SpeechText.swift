import Foundation
import NaturalLanguage

/// Turns raw page text into blocks that read well aloud.
enum SpeechText {
    /// Splits text extracted from a PDF page into blocks of a few sentences.
    ///
    /// PDF text breaks lines wherever the layout did, often mid-word with a hyphen,
    /// so lines are joined back together before splitting into sentences.
    static func blocks(fromPageText text: String, targetLength: Int = 400) -> [String] {
        let joined = joinLines(text)
        guard !joined.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = joined
        var blocks: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
            let sentence = joined[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            if !current.isEmpty && current.count + sentence.count + 1 > targetLength {
                blocks.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
            return true
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks.filter(isSpeakable)
    }

    /// Joins hard-wrapped lines: "exam-\nple" becomes "example", other line breaks become spaces.
    static func joinLines(_ text: String) -> String {
        var result = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if result.hasSuffix("-"), let first = line.first, first.isLowercase {
                result.removeLast()
                result += line
            } else if result.isEmpty {
                result = line
            } else {
                result += " " + line
            }
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// True if the text has something to say (not just page numbers or punctuation).
    static func isSpeakable(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}
