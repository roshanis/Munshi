import Foundation
import Testing
@testable import Munshi

struct SpeechTextTests {
    @Test func joinsHyphenatedAndWrappedLines() {
        let text = "The quick brown fox jumps over the la-\nzy dog.\n  It was well-\nKnown.\n\n12\n"
        #expect(SpeechText.joinLines(text) == "The quick brown fox jumps over the lazy dog. It was well- Known. 12")
    }

    @Test func groupsSentencesIntoBlocks() {
        let sentence = "This sentence is about forty characters."
        let text = Array(repeating: sentence, count: 6).joined(separator: "\n")
        let blocks = SpeechText.blocks(fromPageText: text, targetLength: 100)
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.count <= 100 })
        #expect(blocks.joined(separator: " ") == Array(repeating: sentence, count: 6).joined(separator: " "))
    }

    @Test func skipsPagesWithNothingToSay() {
        #expect(SpeechText.blocks(fromPageText: "  \n 17 \n").isEmpty)
        #expect(SpeechText.blocks(fromPageText: "").isEmpty)
    }

    @Test func voiceRoundTripsThroughStorage() {
        let voices: [SpeechVoice] = [.system(identifier: nil), .system(identifier: "com.apple.voice.premium.en-US.Zoe"), .kokoro("af_heart")]
        for voice in voices {
            #expect(SpeechVoice(storageValue: voice.storageValue) == voice)
        }
        #expect(SpeechVoice(storageValue: "") == .system(identifier: nil))
        #expect(SpeechVoice(storageValue: "nonsense") == .system(identifier: nil))
    }

    @Test func mapsSpeedOntoUtteranceRate() {
        let normal = SystemSpeechEngine.utteranceRate(for: 1)
        #expect(SystemSpeechEngine.utteranceRate(for: 0.5) < normal)
        #expect(SystemSpeechEngine.utteranceRate(for: 2) > normal)
        #expect(SystemSpeechEngine.utteranceRate(for: 10) <= 1)
    }
}
