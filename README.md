# talk

> ## ⚠️ Before you start — what YOU (the human) must do
>
> An AI agent can run every command in this README, but a few things require **you**, because macOS and Apple security won't let any script do them. Read this first.
>
> **You need installed first:**
> - **Xcode** (full app — `swiftc` + Speech framework)
> - macOS + iTerm2 (must be running)
>
> **Steps only a human can do (your AI agent will pause and ask for these):**
> - **Grant Microphone + Speech Recognition** when first prompted — without it, dictation produces silence.
> - That's the only manual step: `build.sh` then `start.sh` auto-clones + starts the dispatch dependency for you.
> - ⚠️ BETA — Apple's speech recognizer can occasionally get stuck; a stop/start fixes it.

**Speak naturally. Two and a half seconds of silence flushes your transcript straight into the active iTerm2 pane — and your voice cycles windows.**

## What it does

`talk` is a macOS voice tool that turns your microphone into a hands-free keyboard for the terminal. A small background listener streams your speech through Apple's on-device Speech framework, shows live partial transcripts in a floating HUD anchored to your active iTerm2 window, and — after 2.5 seconds of silence — types the buffered transcript into the currently focused iTerm2 pane and presses Enter for you. Certain spoken phrases never get typed: say "next project" or "previous window" to cycle between iTerm2 windows, or "stop listening" / "start listening" to pause and resume without killing the session.

It was built for driving Claude Code (and any other terminal program) by voice while your hands are doing something else. It started life as a Claude Code skill — `SKILL.md` is still the canonical behavior contract — and was promoted to a standalone tool.

Honesty about maturity: this is a personal tool that works well day-to-day, but it leans on quirks of recent macOS Speech behavior and is best described as BETA. The recognizer can occasionally get stuck in a silent state (a known macOS `SFSpeechRecognizer` issue); the fix is a stop/start. Trigger phrases can also be misheard ("next project" → "read this project") and simply won't fire when that happens. It depends on a sibling service — [dispatch](https://github.com/brianharms/dispatch) — for the HUD, text injection, and window cycling.

## Features

- **Dictation-to-terminal** — streaming Apple on-device speech recognition; 2.5s of silence flushes the buffered transcript into the active iTerm2 pane, followed by Enter.
- **Floating HUD** — live partial transcripts rendered by dispatch, anchored to the active iTerm2 window (width-capped, scrolls older text up and out).
- **Voice window cycling** — "next / previous {project | window | pane | terminal}" cycles iTerm2 windows; the trigger phrase is swallowed, never typed.
- **Pause / resume by voice** — "stop listening" suspends flushing, the HUD, and cycle triggers (mic and recognizer keep running); "start listening" / "resume listening" brings it back.
- **Per-window status badge** — iTerm2 badge reads `REC` while listening, clears when paused, and re-asserts after each cycle to follow focus.
- **Mic pinning + hot-swap** — pin a preferred input device by substring ("MacBook", "DJI", "Yeti"); swapping mics restarts only the listener so dispatch and the HUD don't blink. AirPods are intentionally avoided as input so they stay in full-quality output mode.
- **Recognizer resilience** — audio-engine recovery for the macOS "started but silent" quirk, liveness restarts gated on speech-level audio, no-speech backoff, and a stale-callback generation guard for long-running sessions.
- **Lifecycle scripts** — `build.sh` (compile + ad-hoc sign), `start.sh` (ensures dispatch is up, then spawns the listener), `stop.sh` (stops the listener and only stops dispatch if `talk` started it).
- **clap-calibrate** — a historical Swift utility for calibrating a clap-detector, kept for reference.

## Requirements

- **OS:** macOS (developed and tested against macOS 26; uses CoreAudio, AppKit, and the on-device Speech framework).
- **Languages / runtimes:** Swift toolchain (`swiftc`, from the Xcode command line tools) to build the binaries; Python 3 to run dispatch.
- **Terminal:** iTerm2 — text injection, window cycling, and the status badge all target iTerm2 specifically.
- **Permissions:** **Microphone** and **Speech Recognition** must be granted to the compiled `voice-listener` binary on first run.
- **Code signing:** ad-hoc signing is mandatory. On macOS 26, TCC silently delivers all-zero audio buffers to unsigned binaries — the mic callback fires but every sample is 0. `build.sh` handles this with `xattr -cr` + `codesign --force --sign -`.
- **Sibling vibekit repo:** [**dispatch**](https://github.com/brianharms/dispatch) — the HUD / window-cycling / text-injection server. `talk` will not function without it. dispatch listens on **port 9879** and is located via the `DISPATCH_DIR` env var (defaults to `~/dispatch`).

## Setup / Install

You can clone `talk` **anywhere** — all three scripts (`build.sh`, `start.sh`, `stop.sh`) auto-detect their own location, and `start.sh` will **auto-clone the dispatch dependency for you** if it isn't already present. A fresh machine self-bootstraps in two commands.

**1. Clone and build.**

```bash
git clone https://github.com/brianharms/talk
cd talk
bash scripts/build.sh
```

`build.sh` compiles `bin/voice-listener.swift` against the Speech / AVFoundation / Foundation frameworks, strips quarantine xattrs, and ad-hoc signs the binary (ad-hoc signing is **required** on macOS 26 — without it the OS silently delivers all-zero audio buffers even after you grant Mic permission).

**2. Start it.**

```bash
bash scripts/start.sh
```

On first run, `start.sh`:
- looks for the dispatch server at `$DISPATCH_DIR` (default `~/dispatch`);
- if it's missing, **clones `github.com/brianharms/dispatch` automatically** (dispatch is Python-stdlib-only and needs no config, so this just works);
- starts dispatch (listening on this Mac only — see Security below), then spawns the voice listener.

macOS will prompt for **Microphone** and **Speech Recognition** — approve both. (This system permission dialog is the one step that genuinely requires a human click; everything else is automatic. Because the binary is ad-hoc signed, the grant survives recompiles.)

**Optional — reuse an existing dispatch checkout.** If you already have dispatch cloned somewhere, point talk at it instead of letting it clone its own copy:

```bash
export DISPATCH_DIR="$HOME/path/to/your/dispatch"
bash scripts/start.sh
```

**Optional — remote access (dispatch's iPhone app).** Basic local dictation needs no secrets and nothing listening on the network. Only if you also want dispatch's iPhone app to reach this Mac, opt in once on the Mac — `mkdir -p ~/.config/dispatch && echo tailscale > ~/.config/dispatch/remote` (or `lan`) — and build the app with your token as dispatch's README describes. `talk` stores no secrets and never needs the token: it always talks to dispatch from this Mac, auto-discovering it on `127.0.0.1`, the LAN IP, or a Tailscale IP via an `lsof` probe of port 9879.

### Security

dispatch types into your terminal and the terminal runs what it's given, so `talk` never exposes it: `start.sh` starts dispatch with no bind flag, which means localhost only unless you opted into remote access. In remote mode dispatch only accepts requests from other devices that are signed with the shared token, refuses anything from a web browser, and blocks DNS rebinding. Details: [dispatch → Security](https://github.com/brianharms/dispatch#security).

## Usage

Start and stop the listener with the scripts:

```bash
# turn it on (auto-starts dispatch if it isn't already running)
bash scripts/start.sh

# turn it off (stops the listener; stops dispatch only if talk started it)
bash scripts/stop.sh
```

Pin or hot-swap your microphone by passing a substring of the device name. If the listener is already running, this restarts only the listener (dispatch stays up):

```bash
bash scripts/start.sh "MacBook"   # pin built-in mic
bash scripts/start.sh "DJI"       # pin a DJI wireless mic
bash scripts/start.sh "auto"      # clear the pin, auto-detect
```

The pin is written to `state/preferred-mic` and persists across off/on until cleared.

**Day to day:**

1. Start it, then focus the iTerm2 pane you want to drive.
2. Speak. Live partials appear in the HUD over the active window; the badge reads `REC`.
3. Stop talking. After 2.5s of silence the buffered text is typed into the pane and Enter is pressed.
4. Say **"next project"** / **"previous window"** to cycle iTerm2 windows — these phrases are swallowed, not typed.
5. Say **"stop listening"** to pause (badge clears) and **"start listening"** to resume.

To send a sentence *and then* cycle, finish the sentence, let the 2.5s pause flush it, then say "next project." Spoken mid-sentence, a cycle trigger clears the buffer instead of submitting it.

**If it goes silent / stops transcribing** (a known macOS `SFSpeechRecognizer` issue), restart it:

```bash
bash scripts/stop.sh && bash scripts/start.sh
```

**Tuning** lives at the top of `bin/voice-listener.swift`: `SILENCE_FLUSH_SECONDS` (default 2.5), the `NEXT_TRIGGER` / `PREV_TRIGGER` / `PAUSE_TRIGGER` / `RESUME_TRIGGER` regexes, and `BADGE_LISTENING` / `BADGE_PAUSED`. Rebuild with `build.sh` after any edit.

## For AI coding agents

This section is for an AI agent working *on* this repo.

**Repo layout (top level):**

```
talk/
  SKILL.md            # canonical behavior contract — the source of truth for /talk
  LICENSE             # MIT
  .gitignore          # secrets, certs, logs, PIDs, state/, internal notes
  bin/
    voice-listener        # compiled mach-o (arm64), ad-hoc signed
    voice-listener.swift   # main listener source (Speech + AVFoundation + CoreAudio + AppKit)
    clap-calibrate         # historical clap-detector calibration binary
    clap-calibrate.swift   # its source
  scripts/
    build.sh           # swiftc + xattr -cr + codesign --force --sign -
    start.sh           # ensure dispatch up; spawn listener; record PIDs/ownership
    stop.sh            # stop listener; stop dispatch only if .dispatch.owned exists
  clap-calibration/    # sample CSV output from clap-calibrate (WAV recordings stay local)
```

**Key entry points:**

- `bin/voice-listener.swift` — the whole listener: speech recognition, silence-flush timer, voice-command regex matching, HUD anchoring, badge writes, and recognizer-resilience logic. Configuration constants are at the top (`DISPATCH_HOST`, `SILENCE_FLUSH_SECONDS`, the trigger regexes, badge strings).
- `scripts/start.sh` / `scripts/stop.sh` — process lifecycle and dispatch ownership.
- `SKILL.md` — describes intended behavior end to end. When code and `SKILL.md` disagree, the code is reality (the port is **9879** consistently across SKILL.md, the scripts, and the Swift source — matching the dispatch server's fixed port).

**Build / run / test:**

```bash
bash scripts/build.sh                 # compile + sign (run from anywhere; it cd's into bin)
bash scripts/start.sh                 # run it (needs dispatch + mic permission)
bash scripts/start.sh "MacBook"       # pin/hot-swap mic
bash scripts/stop.sh                  # stop
```

There is no automated test suite; verification is manual — start it, speak, confirm a flush lands in iTerm2 and that "next project" cycles windows. Mic permission and ad-hoc signing are prerequisites for *any* meaningful run.

**Invariants — do not break these:**

- **Keep the `DISPATCH_DIR` override.** `start.sh` must resolve dispatch via `DISPATCH_DIR` (default `~/dispatch`) and never hardcode an absolute path. Public code must stay path-parameterized.
- **Keep port 9879.** This MUST match the dispatch server's hardcoded port (`PORT = 9879` in dispatch_server.py, no override). The listener and dispatch communicate on **9879** (Swift `DISPATCH_HOST`, the `lsof -iTCP:9879` probe, and the `start.sh` health checks all assume it). Change it in exactly one place and it breaks the others — don't.
- **Never open dispatch to the network from talk.** `start.sh` must start dispatch with no bind flag (localhost, or whatever the user opted into in `~/.config/dispatch/remote`) and with stdin from `/dev/null`. Never add `--lan`, `--tailscale` or `--bind` here, and never send dispatch's token from talk — the listener only ever calls dispatch on this Mac.
- **Never weaken signing.** Always `xattr -cr` + `codesign --force --sign -` after compiling. Dropping ad-hoc signing reintroduces the macOS 26 all-zero-audio-buffer bug. Do not "simplify" `build.sh` by removing these steps.
- **Don't `audioEngine.reset()` in recovery.** Engine recovery rebuilds the engine deliberately without `reset()` because `reset()` corrupts the input format. Preserve that.
- **Preserve dispatch ownership semantics.** `start.sh` writes `.dispatch.owned` only when *it* started dispatch; `stop.sh` stops dispatch only if that marker exists. Never make `stop.sh` unconditionally kill dispatch — the user may run it for other clients (e.g. iPhone over Tailscale).
- **Keep trigger phrases swallowed.** Voice commands must never end up in the flushed transcript or get typed into the terminal.
- **No secrets in git.** `talk` stores none; respect `.gitignore` (`.env`, `certs/`, `*.pem`, `*.key`, `*.pid`, `*.log`, `state/`, internal notes) and never commit any.
- **Keep tunables discoverable.** `SILENCE_FLUSH_SECONDS`, the trigger regexes, and badge strings stay as named constants at the top of `voice-listener.swift` — don't bury them inline.

## License

MIT © 2026 Brian Harms / Ritual Industries — [ritual.industries](https://ritual.industries)
