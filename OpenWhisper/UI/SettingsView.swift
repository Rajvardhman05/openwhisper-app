import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            // Permissions
            permissionsSection

            Divider()

            // Model
            HStack {
                Label("Model", systemImage: "cpu")
                Spacer()
                Picker("", selection: $appState.whisperModel) {
                    Text("Tiny (39 MB)").tag("tiny")
                    Text("Base (140 MB)").tag("base")
                    Text("Small (460 MB)").tag("small")
                    Text("Small EN").tag("small.en")
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: appState.whisperModel) {
                    Task { await appState.loadModel() }
                }
            }

            // Language
            HStack {
                Label("Language", systemImage: "globe")
                Spacer()
                Picker("", selection: $appState.language) {
                    Text("Auto-detect").tag("")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Hindi").tag("hi")
                    Text("Telugu").tag("te")
                    Text("Tamil").tag("ta")
                    Text("Kannada").tag("kn")
                    Text("Malayalam").tag("ml")
                    Text("Bengali").tag("bn")
                    Text("Marathi").tag("mr")
                    Text("Gujarati").tag("gu")
                    Text("Urdu").tag("ur")
                    Text("Punjabi").tag("pa")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Russian").tag("ru")
                    Text("Portuguese").tag("pt")
                    Text("Arabic").tag("ar")
                    Text("Italian").tag("it")
                    Text("Dutch").tag("nl")
                    Text("Turkish").tag("tr")
                    Text("Polish").tag("pl")
                    Text("Thai").tag("th")
                    Text("Vietnamese").tag("vi")
                    Text("Indonesian").tag("id")
                    Text("Ukrainian").tag("uk")
                    Text("Swedish").tag("sv")
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Divider()

            // LLM Cleanup
            HStack {
                Label("LLM Cleanup", systemImage: "sparkles")
                Spacer()
                if appState.llmCleanupEnabled {
                    Circle()
                        .fill(appState.ollamaAvailable ? .green : .red)
                        .frame(width: 6, height: 6)
                        .help(appState.ollamaAvailable ? "Ollama connected" : "Ollama not running")
                }
                Toggle("", isOn: $appState.llmCleanupEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Auto-paste
            HStack {
                Label("Auto-paste", systemImage: "doc.on.clipboard")
                Spacer()
                Toggle("", isOn: $appState.autoPasteEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Flow Bar
            HStack {
                Label("Flow Bar", systemImage: "rectangle.bottomhalf.filled")
                Spacer()
                Toggle("", isOn: $appState.flowBarEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Launch at Login
            HStack {
                Label("Launch at Login", systemImage: "arrow.right.circle")
                Spacer()
                Toggle("", isOn: $appState.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Divider()

            // Trigger hotkey
            HStack {
                Label("Trigger", systemImage: "keyboard")
                Spacer()
                Text("Hold Right ⌥")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                    )
            }

            // Model loading status
            if appState.modelLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading \(appState.whisperModel) model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !appState.modelLoaded {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("Model not loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Last error
            if let error = appState.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("v1.0.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit OpenWhisper") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Color(red: 0.08, green: 0.72, blue: 0.65))
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenWhisper")
                    .font(.headline)
                Text("100% local voice-to-text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(state: appState.recordingState)
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            PermissionRow(
                icon: "mic.fill",
                label: "Microphone",
                detail: "Voice recording",
                granted: appState.microphoneGranted,
                action: { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
            )

            PermissionRow(
                icon: "hand.raised.fill",
                label: "Accessibility",
                detail: "Hotkey & auto-paste",
                granted: appState.accessibilityGranted,
                action: { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
            )
        }
    }

    private func openSystemSettings(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let label: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let state: AppState.RecordingState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var color: Color {
        switch state {
        case .idle: .green
        case .recording: .red
        case .transcribing: .orange
        }
    }

    private var text: String {
        switch state {
        case .idle: "Ready"
        case .recording: "Recording"
        case .transcribing: "Processing"
        }
    }
}
