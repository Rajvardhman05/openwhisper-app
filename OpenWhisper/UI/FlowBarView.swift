import SwiftUI

struct FlowBarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 6) {
            switch appState.recordingState {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .transcribing:
                transcribingContent
            }
        }
        .padding(.horizontal, isIdle ? 10 : 12)
        .padding(.vertical, isIdle ? 5 : 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.35))
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .opacity(appState.recordingState == .idle ? 0.45 : 1.0)
        .animation(.spring(duration: 0.3), value: appState.recordingState)
    }

    private var isIdle: Bool {
        appState.recordingState == .idle
    }

    // MARK: - Idle

    private var idleContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9))
                .foregroundStyle(appState.modelLoaded ? .white.opacity(0.45) : .orange)

            if appState.modelLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text(appState.modelLoadProgress > 0
                     ? (appState.modelIsDownloading
                        ? "Downloading \(Int(appState.modelLoadProgress * 100))%"
                        : "Switching model...")
                     : "Loading...")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if !appState.modelLoaded {
                Text("No model")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.7))
            } else {
                Text("Right ⌥")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
                .modifier(PulseAnimation())

            VoiceDots(level: appState.audioLevel)

            Text("Listening...")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Transcribing

    private var transcribingContent: some View {
        HStack(spacing: 6) {
            BouncingDots()

            Text("Transcribing...")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Helpers

    private var tealColor: Color {
        Color(red: 0.08, green: 0.72, blue: 0.65)
    }
}

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
