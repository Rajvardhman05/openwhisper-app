import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    // MARK: - Recording State

    enum RecordingState: Sendable {
        case idle, recording, transcribing
    }

    var recordingState: RecordingState = .idle {
        didSet {
            // OpenWhisper is a background menu-bar app, so macOS App Nap throttles it, which made
            // cleanup take 5–8s instead of 0.4s. Mark dictation as latency-critical while it runs.
            if recordingState == .idle {
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                activity = nil
            } else if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                    reason: "Dictation in progress")
            }
        }
    }
    private var activity: NSObjectProtocol?
    private var keepWarmTimer: Timer?

    /// The Mac is often short on RAM (heavy swap), and macOS pushes the idle cleanup model out of memory;
    /// the next dictation then waits ~5s while it's read back from disk. A tiny request every 2 minutes
    /// keeps its pages in use so they stay in RAM. Skipped while a dictation is running.
    private func startKeepWarm() {
        keepWarmTimer?.invalidate()
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .idle, self.ollamaAvailable,
                      self.llmCleanupEnabled else { return }
                let model = self.cleanupModel
                Task.detached { await LLMCleanup.warmUp(model: model, quiet: true) }
            }
        }
    }

    // MARK: - Settings (persisted via UserDefaults)

    var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    /// Ollama model used for cleanup: "s1-mini" (fast, faithful) or "qwen2.5:3b".
    var cleanupModel: String = LLMCleanup.s1Mini {
        didSet {
            UserDefaults.standard.set(cleanupModel, forKey: "cleanupModel")
            llmCleanup = LLMCleanup(model: cleanupModel)
            let model = cleanupModel
            Task { await LLMCleanup.warmUp(model: model) }
        }
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
    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                owLog("[OpenWhisper] Launch at login error: \(error)")
            }
        }
    }
    /// Persistent UID of the chosen input device. `nil` means "follow system default".
    var inputDeviceUID: String? {
        didSet {
            if let uid = inputDeviceUID {
                UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
            }
        }
    }

    /// When "System Default" resolves to a Bluetooth headset, record from the built-in mic instead,
    /// so the headset stays in hi-fi (A2DP) mode and playback isn't crushed by call mode.
    var avoidBluetoothMic: Bool = true {
        didSet { UserDefaults.standard.set(avoidBluetoothMic, forKey: "avoidBluetoothMic") }
    }

    /// Words Whisper keeps getting wrong (names, jargon), comma- or newline-separated.
    var customVocabulary: String = "" {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    var vocabularyList: [String] {
        customVocabulary
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Runtime State

    var availableInputDevices: [AudioInputDevice] = []
    var systemDefaultInputIsBluetooth: Bool = false

    var audioLevel: Float = 0.0
    var recordingDuration: TimeInterval = 0.0
    var ollamaAvailable: Bool = false
    var modelLoaded: Bool = false
    var modelLoading: Bool = false
    var modelLoadProgress: Double = 0.0
    var modelIsDownloading: Bool = false
    var lastTranscription: String = ""
    var lastError: String?
    var recentDictations: [DictationEntry] = []
    var retryingEntryID: UUID?
    var accessibilityGranted: Bool = false
    var microphoneGranted: Bool = false

    // MARK: - Components

    private var audioEngine: AudioEngine?
    private var transcriber: SpeechTranscriber?   // whichever engine is active
    private var whisper: WhisperTranscriber?
    private var parakeet: ParakeetTranscriber?
    private var llmCleanup: LLMCleanup?
    private var textInjector: TextInjector?
    private var hotkey: GlobalHotkey?
    private var flowBarController: FlowBarController?
    private var reminderManager: ReminderManager?
    private var recordingTimer: Timer?
    private var chunker: ChunkedDictation?
    private var targetApp: NSRunningApplication?
    private let history = DictationHistory()

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
        case .idle: .gray
        case .recording: .red
        case .transcribing: .orange
        }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        // One-time switch to Parakeet (2026-11-16): ~10x faster than Whisper with equal-or-better English.
        if !defaults.bool(forKey: "migratedToParakeet") {
            defaults.set("parakeet", forKey: "whisperModel")
            defaults.set(true, forKey: "migratedToParakeet")
        }
        whisperModel = defaults.string(forKey: "whisperModel") ?? "parakeet"
        cleanupModel = defaults.string(forKey: "cleanupModel") ?? LLMCleanup.s1Mini
        language = defaults.string(forKey: "language") ?? "en"
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        avoidBluetoothMic = defaults.object(forKey: "avoidBluetoothMic") as? Bool ?? true
        customVocabulary = defaults.string(forKey: "customVocabulary") ?? ""
        recentDictations = history.entries
    }

    // MARK: - Setup

    func setup() async {
        owLog("[OpenWhisper] Setting up...")
        audioEngine = AudioEngine()
        llmCleanup = LLMCleanup(model: cleanupModel)
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

        // Enumerate input devices for the picker + BT detection
        refreshInputDevices()
        owLog("[OpenWhisper] Input devices: \(availableInputDevices.count), default-is-BT: \(systemDefaultInputIsBluetooth)")

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
        if ollamaAvailable { let m = cleanupModel; Task { await LLMCleanup.warmUp(model: m) } }
        startKeepWarm()

        // Setup reminders
        reminderManager = ReminderManager.shared
        let notifGranted = await reminderManager?.requestPermission() ?? false
        owLog("[OpenWhisper] Notification permission: \(notifGranted)")
        owLog("[OpenWhisper] Ready!")
    }

    func loadModel() async {
        modelLoaded = false
        modelLoading = true
        modelLoadProgress = 0
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.modelLoadProgress = value }
        }
        do {
            if whisperModel == "parakeet" {
                modelIsDownloading = false
                owLog("[OpenWhisper] Loading engine: Parakeet")
                let engine = parakeet ?? ParakeetTranscriber()
                try await engine.load(progress: progress)
                await engine.prepare(vocabulary: vocabularyList)
                parakeet = engine
                transcriber = engine
                whisper = nil   // free Whisper's memory
            } else {
                let engine = whisper ?? WhisperTranscriber()
                modelIsDownloading = !engine.isModelDownloaded(name: whisperModel)
                owLog("[OpenWhisper] Loading model: \(whisperModel) (download needed: \(modelIsDownloading))...")
                try await engine.loadModel(name: whisperModel, progress: progress)
                whisper = engine
                transcriber = engine
                parakeet = nil
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

        audioEngine?.startRecording(deviceUID: effectiveInputDeviceUID()) { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        // Transcribe + clean in the background while the user is still talking.
        if let audioEngine, let transcriber {
            let chunker = ChunkedDictation(
                engine: audioEngine,
                transcriber: transcriber,
                cleanup: (llmCleanupEnabled && ollamaAvailable) ? llmCleanup : nil,
                language: language,
                vocabulary: vocabularyList
            )
            self.chunker = chunker
            Task { await chunker.start() }
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
        let stoppedAt = Date()
        let chunker = self.chunker
        self.chunker = nil

        guard let audioData = audioEngine?.stopRecording() else {
            Task { await chunker?.cancel() }
            owLog("[OpenWhisper] No audio captured")
            recordingState = .idle
            return
        }

        guard audioData.count > 4800 else {
            owLog("[OpenWhisper] Audio too short (\(audioData.count) samples)")
            Task { await chunker?.cancel() }
            recordingState = .idle
            return
        }

        // A muted or dead mic delivers digital silence; say so instead of pasting nothing.
        let peak = audioEngine?.lastPeakLevel ?? 0
        if peak < 0.0005 {
            owLog("[OpenWhisper] Mic delivered silence (peak RMS \(peak))")
            lastError = "Your mic recorded only silence. Is it muted?"
            notify(title: "Microphone is silent", body: "OpenWhisper heard nothing. Check the mic isn't muted, or pick another input in Settings.")
            Task { await chunker?.cancel() }
            recordingState = .idle
            return
        }

        Task {
            do {
                // Most of the audio was already transcribed + cleaned while recording; this waits for the tail.
                var cleanedText = ""
                var text: String
                if let chunker {
                    (text, cleanedText) = try await chunker.finish()
                } else {
                    text = try await transcriber?.transcribe(
                        audioData: audioData,
                        language: language,
                        vocabulary: vocabularyList
                    ) ?? ""
                }

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("[BLANK"),
                      !trimmed.hasPrefix("(BLANK") else {
                    owLog("[OpenWhisper] Empty/blank transcription, skipping")
                    recordingState = .idle
                    return
                }

                owLog("[OpenWhisper] Raw: \(text)")

                // Check raw text for reminder intent BEFORE LLM cleanup can alter it
                let isReminderCommand = ReminderManager.isReminder(text)

                if isReminderCommand {
                    owLog("[OpenWhisper] Reminder detected: \(text)")
                    lastTranscription = text
                    if ollamaAvailable {
                        let _ = await reminderManager?.handleReminder(text: text)
                    } else {
                        owLog("[OpenWhisper] Cannot set reminder — Ollama not available")
                    }
                } else {
                    if chunker != nil {
                        if !cleanedText.isEmpty && cleanedText != text {
                            text = cleanedText
                            owLog("[OpenWhisper] Cleaned: \(text)")
                        }
                    } else if llmCleanupEnabled && ollamaAvailable {
                        text = await llmCleanup?.cleanup(text: text, vocabulary: vocabularyList) ?? text
                        owLog("[OpenWhisper] Cleaned: \(text)")
                    }
                    owLog(String(format: "[OpenWhisper] Ready %.1fs after key release", Date().timeIntervalSince(stoppedAt)))

                    lastTranscription = text
                    history.add(text: text, failed: false, audio: audioData)
                    recentDictations = history.entries

                    if autoPasteEnabled {
                        textInjector?.pasteText(text, targetApp: targetApp)
                    } else {
                        textInjector?.copyToClipboard(text)
                    }
                }
            } catch {
                owLog("[OpenWhisper] Error: \(error)")
                lastError = error.localizedDescription
                // Keep the audio so the dictation can be retried from Recent.
                history.add(text: "", failed: true, audio: audioData)
                recentDictations = history.entries
            }

            recordingState = .idle
        }
    }

    // MARK: - History

    func canRetry(_ entry: DictationEntry) -> Bool {
        history.audio(for: entry.id) != nil
    }

    /// Re-transcribe a recent dictation from its kept audio and copy the result.
    func retry(_ entry: DictationEntry) {
        guard retryingEntryID == nil, let audio = history.audio(for: entry.id) else { return }
        retryingEntryID = entry.id
        Task {
            defer { retryingEntryID = nil }
            do {
                var text = try await transcriber?.transcribe(audioData: audio, language: language, vocabulary: vocabularyList) ?? ""
                if !text.isEmpty, llmCleanupEnabled && ollamaAvailable {
                    text = await llmCleanup?.cleanup(text: text, vocabulary: vocabularyList) ?? text
                }
                owLog("[OpenWhisper] Retry result: \(text)")
                history.update(entry.id, text: text, failed: text.isEmpty)
                recentDictations = history.entries
                if !text.isEmpty { textInjector?.copyToClipboard(text) }
            } catch {
                owLog("[OpenWhisper] Retry failed: \(error)")
                lastError = error.localizedDescription
            }
        }
    }

    func copy(_ entry: DictationEntry) {
        textInjector?.copyToClipboard(entry.text)
    }

    func clearHistory() {
        history.clear()
        recentDictations = []
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Refresh

    func refreshPermissions() {
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: false)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (status == .authorized)
    }

    func refreshInputDevices() {
        availableInputDevices = AudioEngine.availableInputDevices()
        systemDefaultInputIsBluetooth = AudioEngine.systemDefaultInputIsBluetooth()
        // If the previously selected device is no longer present, fall back to system default
        if let uid = inputDeviceUID, !availableInputDevices.contains(where: { $0.uid == uid }) {
            inputDeviceUID = nil
        }
    }

    /// The device to record from right now. An explicit pick always wins; otherwise follow the
    /// system default, unless that's Bluetooth and `avoidBluetoothMic` is on.
    private func effectiveInputDeviceUID() -> String? {
        if let uid = inputDeviceUID { return uid }
        guard avoidBluetoothMic, AudioEngine.systemDefaultInputIsBluetooth() else { return nil }
        let builtIn = AudioEngine.builtInInputUID()
        owLog("[OpenWhisper] System default input is Bluetooth — using built-in mic (\(builtIn ?? "none found"))")
        return builtIn
    }

    /// Returns true when dictation will route through a Bluetooth device — i.e. either
    /// the user explicitly picked one, or "System Default" is currently a BT device.
    var resolvedInputIsBluetooth: Bool {
        if let uid = inputDeviceUID {
            return availableInputDevices.first(where: { $0.uid == uid })?.isBluetooth ?? false
        }
        return systemDefaultInputIsBluetooth && !avoidBluetoothMic
    }

    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
        if ollamaAvailable { let m = cleanupModel; Task { await LLMCleanup.warmUp(model: m) } }
    }
}
