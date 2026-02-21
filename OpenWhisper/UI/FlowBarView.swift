import SwiftUI

struct FlowBarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 10) {
            switch appState.recordingState {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .transcribing:
                transcribingContent
            }
        }
        .padding(.horizontal, idlePadding ? 14 : 20)
        .padding(.vertical, idlePadding ? 8 : 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.black.opacity(0.35))
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .animation(.spring(duration: 0.35), value: appState.recordingState)
    }

    private var idlePadding: Bool {
        appState.recordingState == .idle
    }

    // MARK: - Idle (always-visible small pill)

    private var idleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(appState.modelLoaded ? tealColor : .orange)

            if appState.modelLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Loading \(appState.whisperModel)...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else if !appState.modelLoaded {
                Text("Model not loaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.7))
            } else {
                Text("Hold Right ⌥")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .modifier(PulseAnimation())

            VoiceDots(level: appState.audioLevel)
                .frame(height: 24)

            Text("Listening...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Transcribing

    private var transcribingContent: some View {
        HStack(spacing: 10) {
            BouncingDots()

            Text("Transcribing...")
                .font(.system(.callout, design: .default))
                .foregroundStyle(.white.opacity(0.8))
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
