import AVFoundation
import MediaPlayer
import Observation

/// Text to read for one section of a book (a chapter, or a PDF page), split into blocks.
struct SpeechSection: Equatable {
    var blocks: [String]
    /// The block to start from, usually the first one on screen.
    var startIndex: Int
}

/// Where the reader gets its text. Each reader (web or PDF) provides one.
@MainActor
protocol ReadAloudSource: AnyObject {
    /// The current section's text. With `fromStart` false, start near what's on screen.
    func speechSection(fromStart: Bool) async -> SpeechSection?
    /// Moves to the next section. Returns false at the end of the book.
    func advanceSpeechSection() -> Bool
    /// Marks the block being read, or clears the mark with `nil`.
    func highlightSpeechBlock(_ index: Int?)
}

/// Reads a book aloud block by block, following on into the next chapter or page.
@MainActor
@Observable
final class ReadAloudController {
    enum State: Equatable {
        case idle
        /// Getting text, or loading the Kokoro model.
        case preparing
        case playing
        case paused
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var blockIndex = 0
    private(set) var blockCount = 0

    var voice: SpeechVoice {
        didSet {
            guard voice != oldValue else { return }
            UserDefaults.standard.set(voice.storageValue, forKey: SpeechVoice.storageKey)
            replaceEngine()
        }
    }

    var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: SpeechVoice.rateKey) }
    }

    var isActive: Bool { state != .idle }

    @ObservationIgnored weak var source: ReadAloudSource?
    @ObservationIgnored var nowPlayingTitle = ""
    @ObservationIgnored var nowPlayingArtist: String?

    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingJump: Int?
    @ObservationIgnored private var resumeWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        voice = SpeechVoice(storageValue: defaults.string(forKey: SpeechVoice.storageKey) ?? "")
        let savedRate = defaults.double(forKey: SpeechVoice.rateKey)
        rate = savedRate == 0 ? 1 : min(SpeechVoice.rateRange.upperBound, max(SpeechVoice.rateRange.lowerBound, savedRate))
        if voice.isKokoro && !KokoroVoices.isSupported {
            voice = .system(identifier: nil)
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        switch state {
        case .idle: start()
        case .playing: pause()
        case .paused: resume()
        case .preparing: stop()
        }
    }

    /// Starts reading from what's on screen.
    func start() {
        guard let source else { return }
        stop()
        errorMessage = nil
        state = .preparing
        activateAudioSession()
        setUpRemoteCommands()
        task = Task { await run(source) }
    }

    func pause() {
        guard state == .playing else { return }
        engine?.pause()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        activateAudioSession()
        engine?.resume()
        state = .playing
        updateNowPlaying()
        wakeLoop()
    }

    func stop() {
        task?.cancel()
        task = nil
        pendingJump = nil
        engine?.stop()
        wakeLoop()
        source?.highlightSpeechBlock(nil)
        guard state != .idle else { return }
        state = .idle
        tearDownRemoteCommands()
        deactivateAudioSession()
    }

    func skipForward() { jump(to: blockIndex + 1) }

    func skipBackward() { jump(to: blockIndex - 1) }

    /// The reader moved somewhere else (contents, chapter buttons). Pick up from there.
    func sourceDidMove() {
        guard isActive else { return }
        start()
    }

    private func jump(to index: Int) {
        guard state == .playing || state == .paused else { return }
        pendingJump = max(0, index)
        state = .playing
        engine?.stop()
        wakeLoop()
    }

    private func replaceEngine() {
        engine?.stop()
        engine = nil
        // Restart the current block in the new voice.
        if state == .playing || state == .paused {
            pendingJump = blockIndex
            state = .playing
            wakeLoop()
        }
    }

    private func currentEngine() -> SpeechEngine {
        if let engine { return engine }
        let made: SpeechEngine
        switch voice {
        case .system(let identifier):
            made = SystemSpeechEngine(voiceIdentifier: identifier)
        case .kokoro(let name):
            #if canImport(FluidAudio)
            made = KokoroSpeechEngine(voice: name)
            #else
            made = SystemSpeechEngine(voiceIdentifier: nil)
            #endif
        }
        engine = made
        return made
    }

    // MARK: Reading loop

    private func run(_ source: ReadAloudSource) async {
        var section = await source.speechSection(fromStart: false)
        while !Task.isCancelled {
            guard let current = section, !current.blocks.isEmpty else {
                // Nothing readable here (a cover image, say): move on.
                guard source.advanceSpeechSection() else { break }
                section = await source.speechSection(fromStart: true)
                continue
            }
            blockCount = current.blocks.count
            var index = min(max(0, current.startIndex), current.blocks.count - 1)
            while index < current.blocks.count {
                if state == .paused { await waitUntilResumed() }
                if Task.isCancelled { return }
                if let jump = pendingJump {
                    pendingJump = nil
                    guard jump < current.blocks.count else { break }
                    index = jump
                }

                blockIndex = index
                source.highlightSpeechBlock(index)
                let engine = currentEngine()
                if case .kokoro = voice, !KokoroVoices.shared.isReady {
                    state = .preparing
                } else {
                    state = .playing
                }
                if index + 1 < current.blocks.count {
                    engine.prepare(current.blocks[index + 1], rate: rate)
                }
                updateNowPlaying()

                do {
                    try await speakPrepared(current.blocks[index], with: engine)
                    index += 1
                } catch {
                    if Task.isCancelled { return }
                    // A skip or a voice change stopped the engine; the top of the loop picks up the new block.
                    if pendingJump != nil { continue }
                    if case .kokoro = voice, !(error is CancellationError) {
                        // Fall back to Apple's voice so reading doesn't just stop.
                        errorMessage = "Kokoro couldn't speak (\(error.localizedDescription)), so Munshi switched to the system voice."
                        voice = .system(identifier: nil)
                        continue
                    }
                    if !(error is CancellationError) { errorMessage = error.localizedDescription }
                    stop()
                    return
                }
            }
            source.highlightSpeechBlock(nil)
            guard source.advanceSpeechSection() else { break }
            state = .preparing
            section = await source.speechSection(fromStart: true)
        }
        if !Task.isCancelled { stop() }
    }

    private func waitUntilResumed() async {
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    private func wakeLoop() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    /// Speaks once the engine is ready. While Kokoro loads, the state stays `.preparing`.
    private func speakPrepared(_ text: String, with engine: SpeechEngine) async throws {
        if state == .preparing {
            #if canImport(FluidAudio)
            if case .kokoro = voice {
                _ = try await KokoroVoices.shared.loadedManager()
            }
            #endif
            state = .playing
            updateNowPlaying()
        }
        try await engine.speak(text, rate: rate)
    }

    // MARK: Audio session and Now Playing

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { self?.pause() }
            }
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
    }

    private func tearDownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let nowPlayingArtist { info[MPMediaItemPropertyArtist] = nowPlayingArtist }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = state == .paused ? .paused : .playing
        #endif
    }
}

extension KokoroVoices {
    var isReady: Bool { status == .ready }
}
