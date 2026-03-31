# OpenWhisper — Free Voice-to-Text App for macOS

**Open-source, offline speech-to-text for Mac.** Hold a key, speak, and your words appear at the cursor — 100% local, nothing leaves your machine.

OpenWhisper is a free dictation app for macOS that transcribes speech to text entirely on your Mac using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI Whisper optimized for Apple Silicon). Optional local LLM cleanup via [Ollama](https://ollama.com) fixes grammar and removes filler words — all without an internet connection.

No cloud. No subscription. No data collection. Just fast, accurate voice typing on Mac.

## Features

- **100% Local & Private** — All speech recognition runs on-device. No audio ever leaves your Mac.
- **Offline Voice-to-Text** — Works without internet. Transcribe speech to text anywhere.
- **Hold-to-Talk** — Hold Right ⌥ (Option), speak, release. Text appears at your cursor.
- **Works in Any App** — VS Code, Terminal, Chrome, Slack, Notes, Pages — anywhere you can type.
- **AI Grammar Cleanup** — Optional local LLM removes "um", "uh", fixes punctuation (via Ollama).
- **Multiple Whisper Models** — Choose tiny (39 MB), base (140 MB), small (460 MB) based on your needs.
- **29 Languages** — English, Spanish, French, German, Hindi, Chinese, Japanese, and more.
- **Lightweight** — <100 MB RAM, <1% CPU when idle. No background drain.
- **Menu Bar App** — Lives quietly in your menu bar. No dock icon clutter.

## OpenWhisper vs Cloud Dictation Services

| | OpenWhisper | Cloud Services (Wispr Flow, Otter.ai, etc.) |
|---|---|---|
| **Privacy** | 100% local — nothing leaves your Mac | Voice uploaded to remote servers |
| **Internet** | Works offline | Requires internet |
| **Cost** | Free & open-source | $10-20/month subscriptions |
| **Latency** | Instant on-device processing | Network round-trip delay |
| **Resource usage** | <100 MB RAM idle | 400-800 MB RAM |
| **Data collection** | None | Voice data stored on third-party servers |
| **Accuracy** | OpenAI Whisper (state-of-the-art) | Varies |

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon** Mac (M1, M2, M3, M4) — required for WhisperKit CoreML acceleration
- **Xcode Command Line Tools** — `xcode-select --install`
- **Ollama** (optional) — for AI grammar cleanup: [ollama.com](https://ollama.com)

## Quick Install (One Line)

```bash
curl -fsSL https://raw.githubusercontent.com/Rajvardhman05/openwhisper-app/main/install.sh | bash
```

This clones the repo, builds the app, installs it to `/Applications`, and launches it. First install takes ~2 min (downloads WhisperKit dependencies). Also works to **update** an existing install to the latest version.

### Manual Install

```bash
git clone https://github.com/Rajvardhman05/openwhisper-app.git
cd openwhisper-app
bash build.sh
open build/OpenWhisper.app
```

### After launching

1. **Grant Microphone access** when prompted (or: System Settings → Privacy & Security → Microphone)
2. **Grant Accessibility access**: System Settings → Privacy & Security → Accessibility → toggle ON OpenWhisper
3. The Whisper model downloads automatically on first launch (~140 MB for `base`)

OpenWhisper lives in your **menu bar** (no dock icon). Look for the teal microphone icon.

## How to Use Voice-to-Text on Mac with OpenWhisper

**Hold Right ⌥ (Option)** to start recording. Speak. Release to transcribe and paste.

That's it.

### How it works

1. **Hold Right ⌥** → recording starts, Flow Bar shows "Listening..." with animated dots
2. **Speak** → audio captured locally at 16 kHz mono
3. **Release** → audio transcribed by on-device Whisper model
4. **Cleanup** → text cleaned up by local LLM (if enabled)
5. **Paste** → text automatically pasted at your cursor (or copied to clipboard)

Works in any app — VS Code, Terminal, Chrome, Slack, Notes, Pages, Word, and more.

## Whisper Model Selection

Click the menu bar icon to open settings and choose your model:

| Model | Download Size | Speed | Accuracy | Best for |
|---|---|---|---|---|
| tiny | 39 MB | Fastest | Good | Quick notes, short phrases |
| base | 140 MB | Fast | Better | General dictation (recommended) |
| small | 460 MB | Moderate | Best | Longer passages, multiple languages |
| small.en | 460 MB | Moderate | Best (English) | English-only, highest accuracy |

Models are downloaded once from HuggingFace and cached locally.

## Settings

| Setting | Options | Default |
|---|---|---|
| **Model** | tiny, base, small, small.en | base |
| **Language** | 29 languages + auto-detect | English |
| **LLM Cleanup** | On/Off — Ollama grammar correction | On |
| **Auto-paste** | On = paste at cursor, Off = clipboard only | On |
| **Flow Bar** | Show/hide the floating status indicator | On |

## Optional: Local LLM Grammar Cleanup

When enabled, transcriptions are cleaned up by a local LLM — removes filler words ("um", "uh", "like"), fixes grammar and punctuation — before pasting. All processing stays on your Mac.

```bash
# Install Ollama
brew install ollama

# Pull the model (1.5 GB one-time download)
ollama pull qwen2.5:3b

# Ollama runs automatically — no extra steps needed
```

OpenWhisper auto-detects Ollama. If it's not running, cleanup is skipped — raw Whisper transcription is used instead.

## macOS Permissions

OpenWhisper needs two macOS permissions to function:

| Permission | Why | How to grant |
|---|---|---|
| **Microphone** | To capture your voice for transcription | Prompted automatically on first use |
| **Accessibility** | To detect the global hotkey & paste text at cursor | System Settings → Privacy & Security → Accessibility → toggle ON |

## Supported Languages

OpenWhisper supports 29 languages for speech-to-text transcription:

English, Spanish, French, German, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean, Hindi, Arabic, Turkish, Polish, Czech, Swedish, Danish, Norwegian, Finnish, Greek, Hebrew, Thai, Vietnamese, Indonesian, Malay, Romanian, Hungarian, Ukrainian.

Set your language in the settings menu or use auto-detect.

## Architecture

```
OpenWhisper.app (menu bar)
├── AudioEngine        — AVAudioEngine, 16kHz mono resampling
├── WhisperTranscriber — WhisperKit (CoreML + Apple Neural Engine)
├── LLMCleanup         — Ollama HTTP API (localhost:11434)
├── TextInjector       — NSPasteboard + CGEvent Cmd+V
├── GlobalHotkey       — Right ⌥ via NSEvent monitors
└── UI
    ├── MenuBar + Settings popover
    └── FlowBar (floating NSPanel with voice-reactive animation)
```

All speech recognition runs locally. The only network calls are:
- **One-time model download** from HuggingFace (first launch only)
- **Ollama API** on `localhost:11434` (never leaves your machine)

## Troubleshooting

### "Model not loaded" in the Flow Bar
The Whisper model is still downloading. Check the settings panel for a progress indicator. First download takes 1-2 minutes depending on model size and connection speed.

### Text isn't pasting into my app
- Verify Accessibility permission is granted (System Settings → Privacy & Security → Accessibility)
- Some apps block CGEvent paste — switch "Auto-paste" off and use Cmd+V manually

### Ollama cleanup isn't working
- Check Ollama is running: `ollama list` should show `qwen2.5:3b`
- If not installed: `brew install ollama && ollama pull qwen2.5:3b`
- The settings panel shows a green dot next to "LLM Cleanup" when Ollama is reachable

### Recording doesn't start when I hold Right ⌥
- Grant Accessibility permission (required for global hotkey detection)
- Try restarting the app after granting permission

### Build fails
- Ensure Xcode Command Line Tools: `xcode-select --install`
- Requires macOS 14.0+ and Apple Silicon (M1/M2/M3/M4)

## FAQ

### Is OpenWhisper really free?
Yes. OpenWhisper is free and open-source under the MIT license. No subscriptions, no trials, no hidden costs.

### Does OpenWhisper send my voice to the cloud?
No. All speech recognition happens locally on your Mac using WhisperKit. No audio data ever leaves your machine.

### Does OpenWhisper work offline?
Yes. After the one-time model download, OpenWhisper works completely offline. No internet connection needed for transcription.

### How accurate is the transcription?
OpenWhisper uses OpenAI's Whisper model (via WhisperKit), which is one of the most accurate speech recognition models available. The `base` model handles most dictation well; `small` is even more accurate for longer or multilingual content.

### What's the difference between OpenWhisper and macOS built-in dictation?
macOS dictation sends audio to Apple's servers for processing. OpenWhisper processes everything locally — better privacy, works offline, and offers more control with model selection and LLM cleanup.

### Can I use OpenWhisper for languages other than English?
Yes. OpenWhisper supports 29 languages. Select your language in the settings, or use auto-detect to let Whisper identify the spoken language automatically.

### Do I need Ollama?
No. Ollama is optional — it provides AI grammar cleanup (removing filler words, fixing punctuation). Without it, OpenWhisper still transcribes perfectly; you just get the raw Whisper output.

## Development

```bash
# Build debug
swift build

# Build & package .app bundle
bash build.sh

# Run
open build/OpenWhisper.app

# Logs
tail -f /tmp/openwhisper.log
```

Built with Swift 5.10, SwiftUI, Swift Package Manager. No Xcode project required — builds entirely from the command line.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

MIT License — see [LICENSE](LICENSE).
