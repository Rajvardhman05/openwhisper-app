import FluidAudio
import Foundation

/// Common surface for the speech-to-text engines (Whisper, Parakeet).
protocol SpeechTranscriber: AnyObject, Sendable {
    func transcribe(audioData: [Float], language: String, vocabulary: [String], context: String) async throws -> String
}

extension SpeechTranscriber {
    func transcribe(audioData: [Float], language: String, vocabulary: [String] = []) async throws -> String {
        try await transcribe(audioData: audioData, language: language, vocabulary: vocabulary, context: "")
    }
}

extension WhisperTranscriber: SpeechTranscriber {}

/// NVIDIA Parakeet (TDT 0.6B, "ultra" post-train) on the Neural Engine via FluidAudio.
/// ~100x real-time on Apple Silicon vs ~10x for Whisper small, similar or better English accuracy.
/// Custom vocabulary is applied with FluidAudio's CTC keyword boosting (a small second model).
actor ParakeetTranscriber: SpeechTranscriber {
    private var asr: AsrManager?
    private var ctcModels: CtcModels?
    private var boostSession: VocabularyBoostingSession?
    private var boostTerms: [String] = []

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        owLog("[Parakeet] Loading parakeet-ultra (downloads ~630 MB on first run)...")
        let models = try await AsrModels.downloadAndLoad(version: .ultra) { p in
            progress(p.fractionCompleted * 0.85)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
        progress(0.9)
        do {
            ctcModels = try await CtcModels.downloadAndLoad()
        } catch {
            owLog("[Parakeet] Vocabulary boosting unavailable: \(error)")
        }
        // First inference compiles Neural Engine kernels (~1s). Do it now with silence, not on the user's first dictation.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try? await manager.transcribe([Float](repeating: 0, count: 16000), decoderState: &state)
        progress(1.0)
        owLog("[Parakeet] Ready (warmed up)")
    }

    func transcribe(audioData: [Float], language: String, vocabulary: [String], context: String) async throws -> String {
        guard let asr else { throw TranscriberError.modelNotLoaded }
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audioData, decoderState: &state)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !vocabulary.isEmpty, !text.isEmpty, let session = await session(for: vocabulary),
           let out = await session.rescore(text: text, tokenTimings: result.tokenTimings ?? [], audioSamples: audioData),
           out.wasModified {
            let swaps = out.replacements.filter(\.shouldReplace)
                .map { "\($0.originalWord) → \($0.replacementWord ?? "?")" }.joined(separator: ", ")
            owLog("[Parakeet] Vocabulary applied: \(swaps)")
            text = out.text
        }

        owLog(String(format: "[Parakeet] %.1fs audio in %.2fs", Double(audioData.count) / 16000, Date().timeIntervalSince(started)))
        return text.count < 3 ? "" : text
    }

    /// Build the vocabulary booster ahead of time so the first dictation doesn't pay for it.
    func prepare(vocabulary: [String]) async {
        guard !vocabulary.isEmpty else { return }
        _ = await session(for: vocabulary)
    }

    private func session(for vocabulary: [String]) async -> VocabularyBoostingSession? {
        if vocabulary == boostTerms, let boostSession { return boostSession }
        guard let ctcModels else { return nil }
        let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
        do {
            // Acoustic "spotter rescue" off: with a short list of short names it swaps ordinary words for
            // vocabulary terms ("slower" → "Claude"). FluidAudio's own numbers: off = ~80% fewer false swaps
            // and higher recall for this kind of list. Your exact words come first.
            let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
            boostSession = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels, config: config)
            boostTerms = vocabulary
        } catch {
            owLog("[Parakeet] Vocabulary session failed: \(error)")
            boostSession = nil
        }
        return boostSession
    }
}
