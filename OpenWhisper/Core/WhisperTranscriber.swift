import WhisperKit
import Foundation

final class WhisperTranscriber: @unchecked Sendable {
    private var whisperKit: WhisperKit?

    /// Load a Whisper model by name (e.g., "tiny", "base", "small", "small.en")
    func loadModel(name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // WhisperKit model naming: "openai_whisper-{name}"
        // It auto-downloads from Hugging Face on first use
        whisperKit = try await WhisperKit(
            model: "openai_whisper-\(name)",
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        progress(1.0)
    }

    /// Transcribe 16kHz mono Float32 audio to text
    func transcribe(audioData: [Float], language: String) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        owLog("[Whisper] Transcribing with language='\(language)' task=transcribe samples=\(audioData.count)")

        let options = DecodingOptions(
            task: .transcribe,  // Transcribe in original language, NOT translate to English
            language: language.isEmpty ? nil : language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            suppressBlank: true,
            supressTokens: nil,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        let results = try await whisperKit.transcribe(
            audioArray: audioData,
            decodeOptions: options
        )

        // Log detected language from results
        for (i, result) in results.enumerated() {
            owLog("[Whisper] Result[\(i)] language=\(result.language) text=\(result.text)")
        }

        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter out Whisper hallucinations on silence/noise
        let hallucinations: Set<String> = [
            "Thank you.", "Thanks for watching.", "Subscribe.",
            "you", "You", ".", "", "...", "Thank you for watching.",
            "Bye.", "Bye bye.", "Bye-bye.", "The end.",
            "Thanks.", "Thank you so much.", "See you next time.",
        ]
        if hallucinations.contains(text) { return "" }
        if text.hasPrefix("[") || text.hasPrefix("(") { return "" }  // [BLANK_AUDIO], (silence), etc.
        if text.count < 3 { return "" }  // Too short to be meaningful

        return text
    }
}

enum TranscriberError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not loaded."
        }
    }
}
