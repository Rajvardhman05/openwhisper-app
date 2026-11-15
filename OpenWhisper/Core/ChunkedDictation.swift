import Foundation
import Accelerate

/// Transcribes (and cleans) a dictation in pieces while it is still being spoken.
/// Audio is cut at natural pauses; each piece runs Whisper → LLM cleanup in order, in the background,
/// so on key release only the last few seconds are left to process — wait time no longer grows with length.
actor ChunkedDictation {
    private struct Piece { let raw: String; let cleaned: String }

    private let engine: AudioEngine
    private let transcriber: SpeechTranscriber
    private let cleanup: LLMCleanup?          // nil = cleanup off for this dictation
    private let language: String
    private let vocabulary: [String]

    private var committed = 0                 // raw-sample index already handed to the pipeline
    private var pieces: [Piece] = []
    private var pipeline: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var lastRaw = ""                  // previous piece's text, fed to Whisper as context
    private var failure: Error?
    private var cancelled = false
    private var pieceCount = 0

    // Tuning
    private let minChunk = 6.0                // seconds of audio before we look for a pause
    private let maxChunk = 25.0               // no pause by now → cut at the quietest point (Whisper's window is 30s)
    private let minPause = 0.35               // silence this long counts as a pause
    private let frameSeconds = 0.02

    init(engine: AudioEngine, transcriber: SpeechTranscriber, cleanup: LLMCleanup?,
         language: String, vocabulary: [String]) {
        self.engine = engine
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.language = language
        self.vocabulary = vocabulary
    }

    func start() {
        monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { break }
                self.tick()
            }
        }
    }

    /// Call after the engine has stopped. Processes the tail and returns the whole dictation.
    func finish() async throws -> (raw: String, cleaned: String) {
        monitor?.cancel()
        await monitor?.value
        let (tail, rate) = engine.rawSamples(from: committed)
        if !tail.isEmpty && (Double(tail.count) / rate >= 0.3 || pieceCount == 0) {
            dispatch(tail, rate: rate)
        }
        await pipeline?.value
        if let failure { throw failure }
        return (pieces.map(\.raw).joined(separator: " "),
                pieces.map(\.cleaned).joined(separator: " "))
    }

    func cancel() {
        cancelled = true
        monitor?.cancel()
    }

    // MARK: - Chunking

    private func tick() {
        guard !cancelled else { return }
        let (audio, rate) = engine.rawSamples(from: committed)
        let seconds = Double(audio.count) / rate
        guard seconds >= minChunk, let cut = findCut(audio, rate: rate, force: seconds >= maxChunk) else { return }
        dispatch(Array(audio[..<cut]), rate: rate)
        committed += cut
    }

    /// Sample index to cut at: the middle of the first pause after `minChunk`,
    /// or (when forced) the quietest moment in the last stretch.
    private func findCut(_ audio: [Float], rate: Double, force: Bool) -> Int? {
        let frameLen = Int(rate * frameSeconds)
        let rms = frameRMS(audio, frameLen: frameLen)
        guard rms.count > 10 else { return nil }

        // Adaptive threshold between the room's noise floor and the speech level.
        let sorted = rms.sorted()
        let floor = sorted[sorted.count / 10]
        let speech = sorted[sorted.count * 9 / 10]
        let threshold = floor + 0.25 * (speech - floor)

        let startFrame = Int(minChunk / frameSeconds)
        let needed = Int(minPause / frameSeconds)
        var run = 0
        for i in startFrame..<rms.count {
            if rms[i] <= threshold {
                run += 1
                if run >= needed { return (i - run / 2) * frameLen }
            } else {
                run = 0
            }
        }

        guard force else { return nil }
        // No pause in 25s: cut at the quietest 100ms window in the last 10 seconds.
        let searchFrom = max(startFrame, rms.count - Int(10 / frameSeconds))
        var best = searchFrom, bestSum = Float.greatestFiniteMagnitude
        for i in searchFrom..<(rms.count - 5) {
            let sum = rms[i..<(i + 5)].reduce(0, +)
            if sum < bestSum { bestSum = sum; best = i + 2 }
        }
        return best * frameLen
    }

    private func frameRMS(_ audio: [Float], frameLen: Int) -> [Float] {
        guard frameLen > 0 else { return [] }
        let frames = audio.count / frameLen
        var out = [Float](repeating: 0, count: frames)
        audio.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                vDSP_rmsqv(buf.baseAddress! + f * frameLen, 1, &out[f], vDSP_Length(frameLen))
            }
        }
        return out
    }

    // MARK: - Pipeline (strictly in order: one piece at a time)

    private func dispatch(_ raw: [Float], rate: Double) {
        pieceCount += 1
        let index = pieceCount
        let previous = pipeline
        pipeline = Task {
            await previous?.value
            await self.process(raw, rate: rate, index: index)
        }
    }

    private func process(_ raw: [Float], rate: Double, index: Int) async {
        guard !cancelled, failure == nil else { return }

        // Skip pieces that are pure silence (a long pause) — Whisper hallucinates on them.
        var peak: Float = 0
        vDSP_maxmgv(raw, 1, &peak, vDSP_Length(raw.count))
        if peak < 0.003 && index > 1 {
            owLog("[Chunk \(index)] silent, skipped")
            return
        }

        guard let audio = engine.resampleTo16kHz(raw, fromRate: rate) else { return }
        let started = Date()
        do {
            let text = try await transcriber.transcribe(
                audioData: audio, language: language, vocabulary: vocabulary, context: lastRaw)
            let whisperTime = Date().timeIntervalSince(started)
            guard !text.isEmpty else { return }
            lastRaw = text

            var cleaned = text
            if let cleanup, !cancelled {
                cleaned = await cleanup.cleanup(text: text, vocabulary: vocabulary)
            }
            pieces.append(Piece(raw: text, cleaned: cleaned))
            owLog(String(format: "[Chunk %d] %.1fs audio → whisper %.1fs, cleanup %.1fs",
                         index, Double(audio.count) / 16000, whisperTime,
                         Date().timeIntervalSince(started) - whisperTime))
        } catch {
            failure = error
        }
    }
}
