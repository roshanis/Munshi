import AVFoundation

/// A voice the reader can speak with, stored in user defaults as a short string.
enum SpeechVoice: Hashable {
    /// One of Apple's built-in voices. `nil` means the default voice for the device's language.
    case system(identifier: String?)
    /// A Kokoro-82M voice such as `af_heart`, run on device after a one-time download.
    case kokoro(String)

    static let storageKey = "speech.voice"
    static let rateKey = "speech.rate"
    static let rateRange = 0.5...2.0

    init(storageValue: String) {
        if storageValue.hasPrefix("kokoro:") {
            self = .kokoro(String(storageValue.dropFirst("kokoro:".count)))
        } else if storageValue.hasPrefix("system:") {
            let identifier = String(storageValue.dropFirst("system:".count))
            self = .system(identifier: identifier.isEmpty ? nil : identifier)
        } else {
            self = .system(identifier: nil)
        }
    }

    var storageValue: String {
        switch self {
        case .system(let identifier): "system:\(identifier ?? "")"
        case .kokoro(let name): "kokoro:\(name)"
        }
    }

    var isKokoro: Bool {
        if case .kokoro = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .system(let identifier):
            identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))?.name ?? "System voice"
        case .kokoro(let name):
            KokoroVoice.named(name)?.label ?? name
        }
    }
}

/// The Kokoro voices offered in the voice picker. Kokoro has more; these are the clearest for long reading.
struct KokoroVoice: Identifiable, Hashable {
    let id: String
    let label: String

    static let defaultVoice = "af_heart"

    static let all: [KokoroVoice] = [
        KokoroVoice(id: "af_heart", label: "Heart"),
        KokoroVoice(id: "af_bella", label: "Bella"),
        KokoroVoice(id: "af_nicole", label: "Nicole"),
        KokoroVoice(id: "af_sarah", label: "Sarah"),
        KokoroVoice(id: "am_michael", label: "Michael"),
        KokoroVoice(id: "am_fenrir", label: "Fenrir"),
        KokoroVoice(id: "am_puck", label: "Puck"),
        KokoroVoice(id: "bf_emma", label: "Emma (British)"),
        KokoroVoice(id: "bm_george", label: "George (British)"),
        KokoroVoice(id: "bm_fable", label: "Fable (British)"),
    ]

    static func named(_ id: String) -> KokoroVoice? { all.first { $0.id == id } }
}

extension AVSpeechSynthesisVoice {
    /// Built-in voices for the user's language, best quality first.
    static func readerVoices(for language: String = Locale.preferredLanguages.first ?? "en") -> [AVSpeechSynthesisVoice] {
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        return speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }

    var qualityLabel: String? {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: nil
        }
    }
}
