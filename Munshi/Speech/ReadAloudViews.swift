import AVFoundation
import SwiftUI

/// Playback controls shown above the reader's bottom bar while reading aloud.
struct ReadAloudBar: View {
    @Bindable var controller: ReadAloudController
    let foreground: Color
    let background: Color

    @State private var showingVoices = false

    var body: some View {
        VStack(spacing: 6) {
            if let message = controller.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 18) {
                Button {
                    showingVoices = true
                } label: {
                    Image(systemName: "person.wave.2")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Voice and speed")
                .help("Voice and speed")
                .popover(isPresented: $showingVoices) {
                    VoicePicker(controller: controller)
                        .presentationCompactAdaptation(.sheet)
                }

                Spacer(minLength: 0)

                Button {
                    controller.skipBackward()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Previous paragraph")

                Button {
                    controller.togglePlayPause()
                } label: {
                    Group {
                        if controller.state == .preparing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: controller.state == .playing ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .accessibilityLabel(controller.state == .playing ? "Pause" : "Play")

                Button {
                    controller.skipForward()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Next paragraph")

                Spacer(minLength: 0)

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                        Button {
                            controller.rate = rate
                        } label: {
                            if controller.rate == rate {
                                Label(Self.rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.rateLabel(controller.rate))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 32)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Speed")

                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Stop reading aloud")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(foreground)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(background)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Choose between Apple's built-in voices and the downloadable Kokoro voices, and set the speed.
struct VoicePicker: View {
    @Bindable var controller: ReadAloudController
    @State private var kokoro = KokoroVoices.shared
    @Environment(\.dismiss) private var dismiss

    private let systemVoices = AVSpeechSynthesisVoice.readerVoices()

    var body: some View {
        NavigationStack {
            Form {
                Section("Speed") {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $controller.rate, in: SpeechVoice.rateRange, step: 0.05)
                        Image(systemName: "hare")
                    }
                    Text(ReadAloudBar.rateLabel(controller.rate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if KokoroVoices.isSupported {
                    kokoroSection
                }

                Section {
                    voiceRow(.system(identifier: nil), title: "Automatic", detail: "Your device's default voice")
                    ForEach(systemVoices, id: \.identifier) { voice in
                        voiceRow(.system(identifier: voice.identifier), title: voice.name, detail: voice.qualityLabel)
                    }
                } header: {
                    Text("Apple voices")
                } footer: {
                    #if os(iOS)
                    Text("For more natural Apple voices, download Enhanced or Premium voices in Settings › Accessibility › Spoken Content › Voices.")
                    #else
                    Text("For more natural Apple voices, download Enhanced or Premium voices in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private var kokoroSection: some View {
        Section {
            switch kokoro.status {
            case .notDownloaded:
                Button {
                    Task { await kokoro.download() }
                } label: {
                    Label("Download Kokoro voices", systemImage: "arrow.down.circle")
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Downloading and preparing Kokoro… The first time takes a few minutes.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again") {
                    Task { await kokoro.download() }
                }
            case .downloaded, .ready:
                ForEach(KokoroVoice.all) { voice in
                    voiceRow(.kokoro(voice.id), title: voice.label, detail: nil)
                }
                Button("Remove download", role: .destructive) {
                    if controller.voice.isKokoro {
                        controller.voice = .system(identifier: nil)
                    }
                    kokoro.remove()
                }
            }
        } header: {
            Text("Kokoro (natural AI voices)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kokoro-82M runs entirely on this device. It's a one-time download of a few hundred MB; each extra voice is a small download the first time you use it.")
                if KokoroVoices.hasKnownCrashRisk {
                    Text("This OS version has an Apple bug that can make Kokoro crash during long listening sessions. If that happens, switch to an Apple voice.")
                }
            }
        }
    }

    private func voiceRow(_ voice: SpeechVoice, title: String, detail: String?) -> some View {
        Button {
            controller.voice = voice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.voice == voice {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The toolbar button that starts reading aloud, or stops it.
struct ReadAloudButton: View {
    let controller: ReadAloudController

    var body: some View {
        Button {
            if controller.isActive {
                controller.stop()
            } else {
                controller.start()
            }
        } label: {
            Label(
                controller.isActive ? "Stop Reading Aloud" : "Read Aloud",
                systemImage: controller.isActive ? "speaker.slash" : "speaker.wave.2"
            )
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}
