import AVFoundation

/// Turns text into audio. `ReadAloudController` speaks one block (a paragraph or so) at a time.
@MainActor
protocol SpeechEngine: AnyObject {
    /// Speaks `text` and returns when it has finished playing.
    /// Throws `CancellationError` if `stop()` is called or the task is cancelled.
    func speak(_ text: String, rate: Double) async throws

    /// Gives the engine a chance to get the next block ready while the current one plays.
    func prepare(_ text: String, rate: Double)

    func pause()
    func resume()
    func stop()
}

extension SpeechEngine {
    func prepare(_ text: String, rate: Double) {}
}

/// Apple's built-in voices through `AVSpeechSynthesizer`. Always available, no download.
@MainActor
final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private var continuation: CheckedContinuation<Void, Error>?
    private var currentUtterance: ObjectIdentifier?

    init(voiceIdentifier: String?) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Double) async throws {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.utteranceRate(for: rate)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.postUtteranceDelay = 0.05

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.currentUtterance = ObjectIdentifier(utterance)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        currentUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish(throwing: CancellationError())
    }

    private func finish(throwing error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Maps the reader's speed (1 = normal) onto `AVSpeechUtterance.rate`, which isn't linear.
    nonisolated static func utteranceRate(for speed: Double) -> Float {
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let value = speed >= 1 ? normal + (speed - 1) * 0.15 : normal - (1 - speed) * 0.2
        return Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), value)))
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard id == self.currentUtterance else { return }
            self.currentUtterance = nil
            self.finish(throwing: nil)
        }
    }
}
