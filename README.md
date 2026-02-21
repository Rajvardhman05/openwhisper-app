# OpenWhisper

**100% local voice-to-text for macOS.** Hold a key, speak, and your words appear at the cursor — nothing leaves your Mac.

OpenWhisper runs entirely on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Apple Silicon optimized) with optional local LLM cleanup via [Ollama](https://ollama.com). No cloud, no subscription, no data collection.

## Why OpenWhisper?

| Problem with cloud dictation | OpenWhisper |
|---|---|
| Voice sent to remote servers | **100% local** — nothing leaves your Mac |
| Requires internet connection | **Works offline** |
| Monthly subscriptions | **Free & open-source** |
| High idle resource usage | **<100 MB RAM, <1% CPU when idle** |
| Hallucinated/invented text | **Local Whisper = faithful transcription** |

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon** Mac (M1/M2/M3/M4) — required for WhisperKit
- **Xcode Command Line Tools** — `xcode-select --install`
- **Ollama** (optional) — for AI grammar cleanup: [ollama.com](https://ollama.com)

## Installation

### Build from source

```bash
git clone https://github.com/anthropics/openwhisper-app.git
cd openwhisper-app
bash build.sh
open build/OpenWhisper.app
```

The first build downloads WhisperKit dependencies (~2 min). Subsequent builds take ~2 seconds.

### After launching

1. **Grant Microphone access** when prompted (or: System Settings → Privacy & Security → Microphone)
2. **Grant Accessibility access**: System Settings → Privacy & Security → Accessibility → toggle ON OpenWhisper
3. The Whisper model downloads automatically on first launch (~140 MB for `base`)

OpenWhisper lives in your **menu bar** (no dock icon). Look for the teal microphone icon.

## Usage

**Hold Right ⌥ (Option)** to start recording. Speak. Release to transcribe and paste.

That's it.

### What happens under the hood

1. **Hold Right ⌥** → recording starts, Flow Bar shows "Listening..." with animated dots
2. **Speak** → audio captured at 16 kHz mono
3. **Release** → audio sent to local Whisper model
4. **Transcription** → text cleaned up by local LLM (if enabled)
5. **Result** → automatically pasted at your cursor (or copied to clipboard)

Works in any app — VS Code, Terminal, Chrome, Slack, Notes, etc.

## Settings

Click the menu bar icon to open settings:

| Setting | Options | Default |
|---|---|---|
| **Model** | tiny (39 MB), base (140 MB), small (460 MB), small.en (460 MB) | base |
| **Language** | 29 languages + auto-detect | English |
| **LLM Cleanup** | On/Off — uses Ollama to fix grammar & filler words | On |
| **Auto-paste** | On = paste at cursor, Off = copy to clipboard only | On |
| **Flow Bar** | Show/hide the floating status bar | On |

### Model sizes

| Model | Size | Speed | Accuracy | Best for |
|---|---|---|---|---|
| tiny | 39 MB | Fastest | Good | Quick notes, short phrases |
| base | 140 MB | Fast | Better | General dictation (recommended) |
| small | 460 MB | Moderate | Best | Longer passages, multiple languages |
| small.en | 460 MB | Moderate | Best (English) | English-only, highest accuracy |

Models download automatically from HuggingFace on first use.

## Optional: LLM Cleanup

When enabled, transcriptions are cleaned up by a local LLM (removes filler words like "um", "uh", fixes grammar and punctuation) before pasting.

### Setup

```bash
# Install Ollama
brew install ollama

# Pull the model (1.5 GB one-time download)
ollama pull qwen2.5:3b

# Ollama runs automatically — no extra steps needed
```

OpenWhisper auto-detects Ollama. If it's not running, cleanup is skipped silently — raw transcription is used instead.

## Permissions

OpenWhisper needs two macOS permissions:

| Permission | Why | How to grant |
|---|---|---|
| **Microphone** | To capture your voice | Prompted automatically on first use |
| **Accessibility** | To detect the hotkey globally & paste text | System Settings → Privacy & Security → Accessibility → toggle ON |

If Accessibility isn't granted, you'll see an orange warning in the settings panel with a button to open System Settings.

## Troubleshooting

### "Model not loaded" in the Flow Bar
The Whisper model is still downloading. Check the settings panel for a progress indicator. First download takes 1-2 minutes depending on model size and internet speed.

### Text isn't pasting into my app
- Verify Accessibility permission is granted (System Settings → Privacy & Security → Accessibility)
- Some apps block CGEvent paste — switch "Auto-paste" off in settings and use Cmd+V manually after recording

### Ollama cleanup isn't working
- Check Ollama is running: `ollama list` should show `qwen2.5:3b`
- If not installed: `brew install ollama && ollama pull qwen2.5:3b`
- The settings panel shows a green dot next to "LLM Cleanup" when Ollama is reachable

### Recording doesn't start when I hold Right ⌥
- Grant Accessibility permission (this is required for global hotkey detection)
- Try restarting the app after granting permission

### Build fails
- Ensure Xcode Command Line Tools are installed: `xcode-select --install`
- Requires macOS 14.0+ and Apple Silicon

## Architecture

```
OpenWhisper.app (menu bar)
├── AudioEngine        — AVAudioEngine, 16kHz resampling
├── WhisperTranscriber — WhisperKit (CoreML, Apple Neural Engine)
├── LLMCleanup         — Ollama HTTP API (localhost:11434)
├── TextInjector       — NSPasteboard + CGEvent Cmd+V
├── GlobalHotkey       — Right ⌥ via NSEvent monitors
└── UI
    ├── MenuBar + Settings popover
    └── FlowBar (floating NSPanel)
```

All processing runs locally. The only network calls are:
- **One-time model download** from HuggingFace (on first launch)
- **Ollama API** on `localhost:11434` (never leaves your machine)

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

Built with Swift 5.10, SwiftUI, Swift Package Manager. No Xcode project required — everything builds from the command line.

## License

MIT License — see [LICENSE](LICENSE).
