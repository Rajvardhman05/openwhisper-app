import SwiftUI
import Observation
import AVFoundation
import ApplicationServices

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    // MARK: - Recording State

    enum RecordingState: Sendable {
        case idle, recording, transcribing
    }

    var recordingState: RecordingState = .idle

    // MARK: - Settings (persisted via UserDefaults)

    var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var llmCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(llmCleanupEnabled, forKey: "llmCleanupEnabled") }
    }
    var flowBarEnabled: Bool {
        didSet { UserDefaults.standard.set(flowBarEnabled, forKey: "flowBarEnabled") }
    }
    var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }

    // MARK: - Runtime State

    var audioLevel: Float = 0.0
    var recordingDuration: TimeInterval = 0.0
    var ollamaAvailable: Bool = false
    var modelLoaded: Bool = false
    var modelLoading: Bool = false
    var modelLoadProgress: Double = 0.0
    var lastTranscription: String = ""
    var lastError: String?
    var accessibilityGranted: Bool = false
    var microphoneGranted: Bool = false

    // MARK: - Components

    private var audioEngine: AudioEngine?
    private var transcriber: WhisperTranscriber?
    private var llmCleanup: LLMCleanup?
    private var textInjector: TextInjector?
    private var hotkey: GlobalHotkey?
    private var flowBarController: FlowBarController?
    private var recordingTimer: Timer?
    private var targetApp: NSRunningApplication?

    // MARK: - Computed

    var menuBarIcon: String {
        switch recordingState {
        case .idle: "mic.fill"
        case .recording: "record.circle.fill"
        case .transcribing: "ellipsis.circle.fill"
        }
    }

    var menuBarIconColor: Color {
        switch recordingState {
        case .idle: Color(nsColor: .controlAccentColor)
        case .recording: .red
        case .transcribing: .orange
        }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        whisperModel = defaults.string(forKey: "whisperModel") ?? "base"
        language = defaults.string(forKey: "language") ?? "en"
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
    }

    // MARK: - Setup

    func setup() async {
        owLog("[OpenWhisper] Setting up...")
        audioEngine = AudioEngine()
        transcriber = WhisperTranscriber()
        llmCleanup = LLMCleanup()
        textInjector = TextInjector()
        flowBarController = FlowBarController(appState: self)

        // Show flow bar immediately (always visible like Wispr Flow)
        if flowBarEnabled {
            owLog("[OpenWhisper] Showing flow bar...")
            flowBarController?.show()
            owLog("[OpenWhisper] Flow bar shown")
        }

        // Request mic permission
        microphoneGranted = await audioEngine?.requestPermission() ?? false
        owLog("[OpenWhisper] Microphone permission: \(microphoneGranted)")

        // Check accessibility
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: true)
        owLog("[OpenWhisper] Accessibility: \(accessibilityGranted)")

        // Register global hotkey
        hotkey = GlobalHotkey(
            onPress: { [weak self] in
                Task { @MainActor in self?.startRecording() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.stopRecording() }
            }
        )
        hotkey?.register()
        owLog("[OpenWhisper] Hotkey registered (Right Option)")

        // Load Whisper model
        owLog("[OpenWhisper] Loading model: \(whisperModel)...")
        await loadModel()
        owLog("[OpenWhisper] Model loaded: \(modelLoaded)")

        // Check Ollama availability
        ollamaAvailable = await LLMCleanup.checkAvailability()
        owLog("[OpenWhisper] Ollama available: \(ollamaAvailable)")
        owLog("[OpenWhisper] Ready!")
    }

    func loadModel() async {
        modelLoaded = false
        modelLoading = true
        modelLoadProgress = 0
        owLog("[OpenWhisper] Loading model: \(whisperModel)...")
        do {
            try await transcriber?.loadModel(name: whisperModel) { [weak self] progress in
                Task { @MainActor in
                    self?.modelLoadProgress = progress
                }
            }
            modelLoaded = true
            modelLoading = false
            owLog("[OpenWhisper] Model loaded: \(modelLoaded)")
        } catch {
            modelLoading = false
            lastError = "Failed to load model: \(error.localizedDescription)"
            owLog("[OpenWhisper] Model load failed: \(error)")
        }
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard recordingState == .idle else { return }
        guard modelLoaded else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }

        // Save the currently focused app BEFORE we start recording,
        // so we can re-activate it when pasting the transcription
        targetApp = NSWorkspace.shared.frontmostApplication
        owLog("[OpenWhisper] Target app: \(targetApp?.localizedName ?? "unknown")")

        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil

        audioEngine?.startRecording { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
            }
        }

    }

    func stopRecording() {
        guard recordingState == .recording else { return }
        recordingState = .transcribing
        owLog("[OpenWhisper] Transcribing...")

        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioData = audioEngine?.stopRecording() else {
            owLog("[OpenWhisper] No audio captured")
            recordingState = .idle
            return
        }

        guard audioData.count > 4800 else {
            owLog("[OpenWhisper] Audio too short (\(audioData.count) samples)")
            recordingState = .idle
            return
        }

        Task {
            do {
                var text = try await transcriber?.transcribe(
                    audioData: audioData,
                    language: language
                ) ?? ""

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("[BLANK"),
                      !trimmed.hasPrefix("(BLANK") else {
                    owLog("[OpenWhisper] Empty/blank transcription, skipping")
                    recordingState = .idle
                    return
                }

                owLog("[OpenWhisper] Raw: \(text)")

                if llmCleanupEnabled && ollamaAvailable {
                    text = await llmCleanup?.cleanup(text: text) ?? text
                    owLog("[OpenWhisper] Cleaned: \(text)")
                }

                lastTranscription = text

                if autoPasteEnabled {
                    textInjector?.pasteText(text, targetApp: targetApp)
                } else {
                    textInjector?.copyToClipboard(text)
                }
            } catch {
                owLog("[OpenWhisper] Error: \(error)")
                lastError = error.localizedDescription
            }

            recordingState = .idle
        }
    }

    // MARK: - Refresh

    func refreshPermissions() {
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: false)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (status == .authorized)
    }

    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
    }
}
