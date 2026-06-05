---
name: talk
description: Toggle voice-to-iTerm dictation. Speak naturally; 2.5s of silence flushes the transcript into the active iTerm pane and presses Enter. Voice commands cycle iTerm windows and pause/resume the listener. Usage: /talk [on|off|status|<mic-name>]
---

Toggle a background mic listener that transcribes speech via Apple's on-device Speech framework, shows live partials in the dispatch HUD anchored to the active iTerm window, and on 2.5 seconds of silence types the buffered transcript into the currently active iTerm2 pane (followed by Enter).

This skill uses the dispatch server (port 9876) for window cycling, text injection, the floating dictation HUD, and the per-window status badge.

`/talk on` auto-starts the dispatch server if it isn't running, and `/talk off` stops it again — but only if /talk was the one that started it. If dispatch was already running before /talk on (e.g. the user has it on for the iPhone), /talk off leaves it alone.

## Behavior

Parse the user's argument and act accordingly. Default with no argument is **toggle**.

### `on`
1. Run `bash ~/.claude/skills/talk/scripts/start.sh` (foreground, NOT `run_in_background`).
2. Script ensures dispatch is reachable on `localhost:9876` (starts it on `--lan` if not), spawns the listener daemon, records both PIDs.
3. Report the script's stdout verbatim.

### `on <mic-name>` or just `<mic-name>` (e.g. `/talk on AirPods`, `/talk AirPods`, `/talk MacBook`, `/talk auto`)
1. Run `bash ~/.claude/skills/talk/scripts/start.sh "<mic-name>"`.
2. The script writes the mic name to `~/.claude/skills/talk/state/preferred-mic`. The listener uses a substring match against macOS input devices, so "AirPods" / "Yeti" / "MacBook" / "DJI" all work.
3. **If the listener is already running**, this hot-swaps the mic — start.sh kills only the listener and respawns it (dispatch stays up, no HUD blip). Do NOT toggle the listener off first; just pass the mic name.
4. Pass `auto` (or an empty string) to clear the pin and return to auto-detect: `/talk on auto` or `/talk auto`.
5. The pin persists across `/talk off` + `/talk on` until explicitly cleared.

### `off`
1. Run `bash ~/.claude/skills/talk/scripts/stop.sh`.
2. Stops the listener. If `.dispatch.owned` exists (we started dispatch), also stops dispatch.
3. Report stdout verbatim.

### `status` or no argument when intent is to inspect
1. Check `.listener.pid` and `kill -0` the PID.
2. Check `pgrep -f dispatch_server.py`.
3. Report listener and dispatch state.

### Toggle (no argument, intent to toggle)
- If listener is running → run `stop.sh`.
- If listener is not running → run `start.sh`.

### Parsing arg intent
The single argument after `/talk` can be: `on`, `off`, `status`, or a free-form mic name string. If it's not one of the first three reserved words, treat it as a mic-name request and call `start.sh "<arg>"` — that handles both fresh-start and hot-swap cases.

## Voice commands (all swallowed — never typed into the terminal)

- **`next project|window|pane|terminal`** → POST `/cycle {direction:"next"}`
- **`previous|last|prev project|window|pane|terminal`** → POST `/cycle {direction:"prev"}`
- **`stop listening`** → pause (mic and STT keep running, but flushes/HUD/cycle triggers are suppressed)
- **`start listening`** / **`resume listening`** → resume
- Triggers fire mid-sentence; the rest of the sentence is also swallowed by the session restart that follows.

## How it works

- **Listener binary**: `~/.claude/skills/talk/bin/voice-listener` — Swift, uses `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true` for streaming Apple Speech recognition.
- **Mic**: pinned to a preferred input device at startup (DJI wireless > MacBook built-in > built-in fallback) by setting the system default input via CoreAudio. Original default is restored on shutdown. AirPods are intentionally avoided so they stay in full-quality A2DP for music output instead of being downgraded to HFP/SCO mono 24kHz when used as input.
- **Codesigning**: every build is `xattr -cr`'d and ad-hoc codesigned via `scripts/build.sh`. macOS 26 silently delivers all-zero audio buffers to unsigned binaries.
- **Live partials** → `POST /stream-text` (dispatch updates the floating HUD).
- **HUD anchor** → `POST /hud-position {x,y,w,h}` with the active iTerm window's screen rect (Cocoa coords). Dispatch caches the latest position so it applies even when the HUD spawn races with the position request. HUD width is capped at the active window's width minus 24px; HUD height is capped at 50% of the screen the window lives on, with older text scrolling up and out (`…` prefix when truncated).
- **2.5s silence flush** → `POST /flush {text}` — dispatch types the text and a raw CR atomically into the active iTerm session under `_applescript_lock`, with a 50ms delay between text and CR so Ink-based TUIs (Claude Code) reliably submit.
- **Badge** → text label written via OSC 1337 `SetBadgeFormat` to the current iTerm window's TTYs only; all other panes get the badge cleared. Badge is `REC` when listening, `OFF` when paused. Badge re-asserts at 0.4s, 1.0s, 1.6s after each `/cycle` to follow focus.
- **Recognition resilience**: the listener has multiple defensive paths because macOS 26's `SFSpeechRecognizer` is fragile in long-running sessions:
  - **Audio engine recovery**: if the engine produces fewer than 10 buffers in 2 seconds (the macOS 26 "started but silent" quirk), tear down and rebuild without `audioEngine.reset()` (reset corrupts the input format).
  - **Recognition liveness check**: if 8+ seconds pass with no partials despite >8 speech-level audio buffers (peak > 0.05), force a recognition session restart. Idle silence won't trigger restarts because we gate on speech-level buffers, not total buffers.
  - **No-speech error backoff**: when Apple Speech returns "No speech detected" (long silent stream), wait 1.5s before restarting to avoid a runaway loop.
  - **Stale callback guard**: each session has a generation number; recognition callbacks from older sessions are dropped.

## Files

```
~/.claude/skills/talk/
  SKILL.md
  bin/
    voice-listener            # compiled mach-o (arm64), ad-hoc signed
    voice-listener.swift      # source
    clap-calibrate            # historical — clap-detector calibration tool
    clap-calibrate.swift
  scripts/
    start.sh                  # ensures dispatch + spawns listener
    stop.sh                   # stops listener; stops dispatch only if we started it
    build.sh                  # swiftc + xattr -cr + codesign --force --sign -
  .listener.pid               # current listener PID
  .listener.log               # listener stdout/stderr (ISO timestamps)
  .dispatch.pid               # dispatch PID (only if /talk on started it)
  .dispatch.owned             # marker file: presence means /talk owns dispatch
  .dispatch.log               # dispatch stdout/stderr (only when /talk launched it)
```

## Permissions

On first run, macOS prompts for **Microphone** and **Speech Recognition** for the binary at `~/.claude/skills/talk/bin/voice-listener`. Approve both. The binary is ad-hoc codesigned so the permission grant survives recompiles.

## Tuning

Adjustable constants at the top of `voice-listener.swift`:
- `SILENCE_FLUSH_SECONDS` (default 2.5) — how long after the last partial before flushing
- `NEXT_TRIGGER` / `PREV_TRIGGER` / `PAUSE_TRIGGER` / `RESUME_TRIGGER` — voice command regexes
- `BADGE_LISTENING` / `BADGE_PAUSED` — badge text

After editing: `bash ~/.claude/skills/talk/scripts/build.sh`

## Known issues

- **macOS 26 SFSpeechRecognizer can get permanently stuck** in a silent state where the audio engine works but no partials come out, even after liveness restarts. Recovery: `bash ~/.claude/skills/talk/scripts/stop.sh && bash ~/.claude/skills/talk/scripts/start.sh`. Auto-respawn from a parent watcher would handle this — not currently implemented.
- **Apple Speech mishears trigger phrases**: if it transcribes "next project" as "Read this project" the cycle won't fire. Out of our control.
