import AVFoundation
import Foundation
import Observation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Downloads and holds the Kokoro-82M model (Apache 2.0, from Hugging Face via FluidAudio's Core ML port).
///
/// Nothing is bundled with the app: the model downloads the first time someone asks for it
/// and is cached in the app's own container. Other voices download on first use (they're small).
@MainActor
@Observable
final class KokoroVoices {
    static let shared = KokoroVoices()

    enum Status: Equatable {
        case notDownloaded
        /// On disk but not loaded into memory yet.
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status

    private static let downloadedKey = "speech.kokoroDownloaded"

    #if canImport(FluidAudio)
    @ObservationIgnored private var manager: KokoroAneManager?
    @ObservationIgnored private var loadTask: Task<KokoroAneManager, Error>?
    #endif

    private init() {
        status = UserDefaults.standard.bool(forKey: Self.downloadedKey) ? .downloaded : .notDownloaded
    }

    /// False when the app was built without the FluidAudio package.
    static var isSupported: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    var isDownloaded: Bool {
        switch status {
        case .downloaded, .loading, .ready: true
        case .notDownloaded, .failed: false
        }
    }

    var isBusy: Bool { status == .loading }

    /// Some OS releases have an Apple Core ML bug that can crash long Kokoro sessions
    /// (FluidAudio issues #844 and #889). Kokoro still works there, but we say so.
    static var hasKnownCrashRisk: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return version.majorVersion == 26 && (4...5).contains(version.minorVersion)
        #else
        return version.majorVersion >= 27 || (version.majorVersion == 26 && version.minorVersion >= 4)
        #endif
    }

    /// Downloads the model if needed and loads it.
    func download() async {
        #if canImport(FluidAudio)
        _ = try? await loadedManager()
        #endif
    }

    /// Deletes the downloaded model files to free space.
    func remove() {
        #if canImport(FluidAudio)
        loadTask?.cancel()
        loadTask = nil
        let manager = manager
        self.manager = nil
        Task { await manager?.cleanup() }
        if let folder = try? TtsCacheDirectory.ensure() {
            try? FileManager.default.removeItem(at: folder)
        }
        #endif
        UserDefaults.standard.set(false, forKey: Self.downloadedKey)
        status = .notDownloaded
    }

    #if canImport(FluidAudio)
    /// The loaded model, downloading and compiling it first if needed.
    func loadedManager() async throws -> KokoroAneManager {
        if let manager { return manager }
        let task: Task<KokoroAneManager, Error>
        if let loadTask {
            task = loadTask
        } else {
            task = Task {
                let manager = KokoroAneManager(variant: .english, defaultVoice: KokoroVoice.defaultVoice)
                try await manager.initialize()
                return manager
            }
            loadTask = task
        }
        status = .loading
        do {
            let manager = try await task.value
            self.manager = manager
            loadTask = nil
            UserDefaults.standard.set(true, forKey: Self.downloadedKey)
            status = .ready
            return manager
        } catch {
            loadTask = nil
            status = .failed(error.localizedDescription)
            throw error
        }
    }
    #endif
}

#if canImport(FluidAudio)
/// Speaks with a Kokoro voice: synthesizes a block to 24 kHz samples, then plays them.
/// The next block is synthesized while the current one plays, so there's no gap between paragraphs.
@MainActor
final class KokoroSpeechEngine: NSObject, SpeechEngine {
    private let voice: String
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var prepared: (text: String, rate: Double, task: Task<[Float], Error>)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var playbackID = UUID()
    /// Paused before the audio was ready: schedule it but don't start the player.
    private var isPaused = false

    init(voice: String) {
        self.voice = voice
        super.init()
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    /// The output changed (headphones unplugged, say) and the engine stopped. Move on to the next block
    /// rather than waiting forever for a buffer that won't finish; `play` restarts the engine.
    @objc private nonisolated func engineConfigurationChanged(_ notification: Notification) {
        Task { @MainActor in
            self.playbackID = UUID()
            self.finish(throwing: nil)
        }
    }

    func prepare(_ text: String, rate: Double) {
        if let prepared, prepared.text == text, prepared.rate == rate { return }
        prepared?.task.cancel()
        prepared = (text, rate, synthesisTask(text, rate: rate))
    }

    func speak(_ text: String, rate: Double) async throws {
        stopPlayback()
        let task: Task<[Float], Error>
        if let prepared, prepared.text == text, prepared.rate == rate {
            task = prepared.task
        } else {
            prepared?.task.cancel()
            task = synthesisTask(text, rate: rate)
        }
        prepared = nil

        let samples = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else { return }
        try await play(samples)
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        player.play()
    }

    func stop() {
        isPaused = false
        prepared?.task.cancel()
        prepared = nil
        stopPlayback()
    }

    private func stopPlayback() {
        playbackID = UUID()
        player.stop()
        finish(throwing: CancellationError())
    }

    private func synthesisTask(_ text: String, rate: Double) -> Task<[Float], Error> {
        let voice = voice
        let speed = Float(min(SpeechVoice.rateRange.upperBound, max(SpeechVoice.rateRange.lowerBound, rate)))
        return Task {
            let manager = try await KokoroVoices.shared.loadedManager()
            try Task.checkCancellation()
            return try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed).samples
        }
    }

    private func play(_ samples: [Float]) async throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        let id = UUID()
        playbackID = id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.playbackID == id else { return }
                        self.finish(throwing: nil)
                    }
                }
                if !isPaused { player.play() }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
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
}
#endif
