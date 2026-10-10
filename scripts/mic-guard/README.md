# mic-guard

Keeps OpenWhisper dictation working when Bluetooth earbuds are connected.

> **No longer needed.** OpenWhisper now records from the Mac's built-in mic on
> its own whenever the system default input is Bluetooth (Settings → "Use Mac
> mic when default is Bluetooth", on by default), and picking a named input
> device works. Kept for reference.

## The problem

Older builds recorded with AVAudioEngine, which could not pin a non-default mic:
it reported the default device's stale format and `installTap` threw a
sample-rate mismatch, so only **System Default** worked and the OS default
input had to be managed externally (that's what this agent does).

When Bluetooth
earbuds (e.g. OnePlus Nord Buds) are the default mic, macOS runs them in **HFP
mode — 16 kHz mono, telephone quality**. That:

- degrades / breaks Whisper transcription, and
- muffles any simultaneous audio playback (Netflix, music, etc.),

because Bluetooth earbuds physically can't do hi-fi A2DP playback and mic input
at the same time. macOS also tends to **auto-grab the earbuds as the mic every
time they reconnect**, so the problem keeps coming back.

## The fix

A launchd agent that, **only when the buds newly connect** and macOS grabs them
as the mic, switches the system input back to the MacBook mic. It does **not**
fight a deliberate mid-session choice to use the buds as mic.

Requires [`switchaudio-osx`](https://github.com/deweller/switchaudio-osx):

```bash
brew install switchaudio-osx
```

## Install

```bash
# 1. script
mkdir -p ~/.local/bin ~/.local/state
cp mic-guard.sh ~/.local/bin/mic-guard.sh
chmod +x ~/.local/bin/mic-guard.sh

# 2. launch agent (edit the plist path if your username differs)
cp com.raja.micguard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.raja.micguard.plist
```

Disable anytime:

```bash
launchctl unload ~/Library/LaunchAgents/com.raja.micguard.plist
```

## Handy aliases (optional, add to `~/.zshrc`)

```bash
alias micfix='SwitchAudioSource -s "MacBook Pro Microphone" -t input'   # mic -> MacBook
alias micbuds='SwitchAudioSource -s "OnePlus Nord Buds 3r" -t input'    # mic -> buds
alias micnow='SwitchAudioSource -c -t input'                           # show current
```

## Notes

- Device names in `mic-guard.sh` (`OnePlus Nord Buds 3r`, `MacBook Pro
  Microphone`) are hardcoded — change them for your hardware. List names with
  `SwitchAudioSource -a -t input`.
- Poll interval is 10s (`StartInterval` in the plist); it only acts on an
  absent→present transition of the buds.
