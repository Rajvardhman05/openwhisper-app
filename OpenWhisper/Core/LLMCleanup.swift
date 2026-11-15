import Foundation

final class LLMCleanup: Sendable {
    private let baseURL = "http://localhost:11434"
    /// Ollama model. "s1-mini" is a 600M model trained only for dictation cleanup (faster, keeps your phrasing);
    /// its system prompt + template live in the Ollama Modelfile, so we only send the control line here.
    let model: String
    static let s1Mini = "s1-mini"
    static let qwen = "qwen2.5:3b"

    init(model: String = LLMCleanup.s1Mini) {
        self.model = model
    }

    private let cleanupPrompt = """
        Fix this voice dictation transcript. Rules:
        - Remove ONLY filler words (um, uh, like, you know, so, basically, actually, I mean)
        - Fix grammar, spelling, and punctuation
        - Keep EVERY sentence and every idea the speaker said. Never drop, merge, shorten or summarize sentences
        - Keep the EXACT meaning and tone — do NOT rephrase or add words
        - If it's code-related, preserve technical terms, variable names, function names exactly
        - Output ONLY the cleaned text, nothing else
        - Do NOT add quotes around the output
        """

    private func vocabularyRule(_ vocabulary: [String]) -> String {
        guard !vocabulary.isEmpty else { return "" }
        return "\n- Spell these words exactly as written: " + vocabulary.joined(separator: ", ")
    }

    private static let fillers: Set<String> = [
        "um", "uh", "umm", "uhh", "like", "you", "know", "so", "basically", "actually", "i", "mean",
        "kind", "of", "right", "okay", "ok", "well", "just", "alright", "yeah",
    ]

    /// Distinct lowercased words that carry meaning (fillers and very short words excluded).
    private static func contentWords(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { $0.count > 2 && !fillers.contains($0) })
    }

    /// Check if Ollama is running and responsive
    static func checkAvailability() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Load the cleanup model into memory and pin it there (keep_alive -1), so the first dictation isn't slow.
    static func warmUp(model: String) async {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        // Run a real (tiny) generation: loading weights alone still leaves a ~4s first-call cost.
        let prompt = model == s1Mini
            ? "[Styling: semi-formal] [Structure: prose] [Context: general]\num this is a warm up"
            : "Say OK."
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false, "keep_alive": -1,
                                   "options": ["temperature": 0, "num_predict": 8]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
        owLog("[LLMCleanup] Warm-up \(model): \(ok ? "done, pinned in memory" : "failed (is it installed in Ollama?)")")
    }

    /// Clean up transcribed text using local Ollama LLM
    func cleanup(text: String, vocabulary: [String] = []) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return text }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "prompt": model == Self.s1Mini
                ? "[Styling: semi-formal] [Structure: prose] [Context: general]\n\(text)"
                : "\(cleanupPrompt)\(vocabularyRule(vocabulary))\n\nTranscript: \(text)",
            "stream": false,
            "keep_alive": -1,  // never unload: a cold reload costs seconds on the next dictation
            "options": [
                "temperature": 0,
                "num_predict": max(200, text.count * 2)
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return text }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responseText = json["response"] as? String {
                let cleaned = responseText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                // Sanity check: don't return empty or much longer than input
                guard !cleaned.isEmpty && cleaned.count < text.count * 3 else { return text }

                // Fidelity guard: the speaker's words matter more than polish. If cleanup dropped
                // real content (not just fillers), keep the raw transcript instead.
                let rawWords = Self.contentWords(text)
                let kept = Self.contentWords(cleaned)
                let missing = rawWords.subtracting(kept)
                if !rawWords.isEmpty && Double(missing.count) / Double(rawWords.count) > 0.15 {
                    owLog("[LLMCleanup] Cleanup dropped content (\(missing.sorted().joined(separator: ", "))) — using raw text")
                    return text
                }
                return cleaned
            }
        } catch {
            // Silently fall back to raw text
        }

        return text
    }
}
