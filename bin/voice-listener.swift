// voice-listener.swift
//
// Always-on mic listener for the /talk skill.
//
// - Streams microphone audio into Apple's SFSpeechRecognizer with partial results.
// - Posts live partials to the dispatch HUD (POST /stream-text).
// - After 2.5s of silence, flushes the buffered transcript into the active
//   iTerm pane (POST dispatch /flush) and closes the HUD.
// - Watches partials for spoken cycle commands and SWALLOWS the trigger
//   phrase (the words don't end up in the flushed transcript):
//     * "next {project|window|pane|terminal}"        -> POST /cycle next
//     * "previous|last|prev {project|window|...}"    -> POST /cycle prev
//   Triggers fire mid-sentence — saying "...let's check the build, next
//   project" both submits the sentence-up-to-trigger? No: the trigger is
//   swallowed AND the buffered transcript is cleared, so nothing types.
//   If you want a sentence to be sent THEN cycle, end the sentence with a
//   2.5s pause first, then say "next project."
//
// Build:
//   swiftc voice-listener.swift -o voice-listener \
//     -framework Speech -framework AVFoundation -framework Foundation

import Foundation
import AVFoundation
import Speech
import CoreAudio
import AppKit

// MARK: - Configuration

// Dispatch host is discovered at startup (see findDispatchHost()).
var DISPATCH_HOST = "http://127.0.0.1:9879"
let SILENCE_FLUSH_SECONDS: TimeInterval = 2.5

// Voice-command trigger phrases for window cycling. Matched as a regex
// against the latest partial transcript: a "next" or "previous" word
// followed (within a few words) by a target word. The trigger is
// SWALLOWED — when matched, the partial buffer is cleared and the cycle
// command fires; the trigger words don't get typed into the terminal.
//
// Tuned to fire mid-sentence ("...let's check the build, next project")
// since utterances commonly end with these phrases. We require the match
// to be near the end of the partial so we don't fire on a phrase from
// earlier in a long monologue that's already been transcribed.
let TARGET_NOUNS = "(?:project|window|pane|terminal)"
let NEXT_TRIGGER = try! NSRegularExpression(
    pattern: "\\b(next)\\s+\(TARGET_NOUNS)\\b",
    options: [.caseInsensitive]
)
let PREV_TRIGGER = try! NSRegularExpression(
    pattern: "\\b(previous|last|prev)\\s+\(TARGET_NOUNS)\\b",
    options: [.caseInsensitive]
)

// Pause/resume voice commands. When paused, the mic + STT keep running but
// nothing is sent to dispatch — no HUD, no flush, no cycle triggers. Useful
// when recording videos, talking to other people, etc.
let PAUSE_TRIGGER = try! NSRegularExpression(
    pattern: "\\bstop\\s+listening\\b",
    options: [.caseInsensitive]
)
let RESUME_TRIGGER = try! NSRegularExpression(
    pattern: "\\b(start|resume)\\s+listening\\b",
    options: [.caseInsensitive]
)

// MARK: - HUD anchoring to active iTerm window

// Returns the active iTerm window's bounds in AppKit/Cocoa screen coords
// (origin = bottom-left of primary screen). AppleScript's `bounds of window`
// returns Carbon-style coords (origin = top-left of primary screen, y down),
// so we convert.
func activeITermWindowRect() -> (x: Double, y: Double, w: Double, h: Double)? {
    let script = """
    set AppleScript's text item delimiters to ","
    tell application "iTerm2"
        try
            set b to bounds of current window
            return (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
        on error
            return ""
        end try
    end tell
    """
    let proc = Process()
    proc.launchPath = "/usr/bin/osascript"
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = out.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 4 else { return nil }
        // Carbon: (left, top, right, bottom) with origin top-left of primary screen.
        let left = parts[0], top = parts[1], right = parts[2], bottom = parts[3]
        let w = right - left, h = bottom - top
        // Convert top to Cocoa-y. Primary screen height is needed.
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cocoaY = primaryH - bottom
        logLine("activeITermWindowRect: carbon L=\(Int(left)) T=\(Int(top)) R=\(Int(right)) B=\(Int(bottom)) | primaryH=\(Int(primaryH)) | cocoa x=\(Int(left)) y=\(Int(cocoaY)) w=\(Int(w)) h=\(Int(h))")
        return (left, cocoaY, w, h)
    } catch {
        logLine("activeITermWindowRect: \(error)")
        return nil
    }
}

// Tell dispatch's HUD to anchor itself above the active iTerm window. Safe
// to call repeatedly — if the HUD isn't running, dispatch ignores it.
func anchorHUDToActiveWindow() {
    guard let r = activeITermWindowRect() else {
        logLine("anchorHUDToActiveWindow: no rect from AppleScript")
        return
    }
    logLine("anchorHUDToActiveWindow: posting x=\(Int(r.x)) y=\(Int(r.y)) w=\(Int(r.w)) h=\(Int(r.h))")
    postJSON("/hud-position", ["x": r.x, "y": r.y, "w": r.w, "h": r.h])
}

// MARK: - iTerm2 badge

// iTerm2 supports a per-session "badge" overlay in the top-right corner of
// the pane, set via the `SetBadgeFormat` OSC 1337 escape sequence. We use
// it as a paused-state indicator so the user knows when the listener has
// stopped sending text to the terminal.
//
// Setting the badge requires writing the escape directly to each session's
// TTY (the OSC sequence is interpreted by iTerm2 when it appears in the
// terminal output stream). We enumerate all iTerm sessions and write to
// each TTY so the badge appears in every visible pane.
// Returns (current-window TTYs, all other iTerm session TTYs). The split lets
// us write the badge only to the focused window and clear it everywhere else
// so we never see stale badges on a non-focused pane.
func enumerateITermTTYs() -> (current: [String], others: [String]) {
    // Use `|` between TTYs and `||` between the two lists. AppleScript's
    // default `list as text` join is empty-string, hence the explicit
    // delimiter setup.
    let script = """
    set AppleScript's text item delimiters to "|"
    tell application "iTerm2"
        set currentList to {}
        set otherList to {}
        set curW to current window
        repeat with w in windows
            set isCur to (id of w is id of curW)
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if isCur then
                        set end of currentList to tty of s
                    else
                        set end of otherList to tty of s
                    end if
                end repeat
            end repeat
        end repeat
        return (currentList as text) & "||" & (otherList as text)
    end tell
    """
    let proc = Process()
    proc.launchPath = "/usr/bin/osascript"
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let halves = out.components(separatedBy: "||")
        let cur = halves.indices.contains(0)
            ? halves[0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("/dev/") }
            : []
        let oth = halves.indices.contains(1)
            ? halves[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("/dev/") }
            : []
        return (cur, oth)
    } catch {
        logLine("enumerateITermTTYs: \(error)")
        return ([], [])
    }
}

// Badge: short text labels. Emoji circles render at iTerm's badge font
// size (huge by default and only changeable by relaunching iTerm with a
// new "Badge Font" plist value). Plain text glyphs render at the badge's
// configured size, so they stay reasonable. Color is set globally per
// iTerm profile via "Badge Color"; we just convey state through the word.
let BADGE_LISTENING = "REC"
let BADGE_PAUSED = ""

// Set the iTerm2 badge to `text` on the currently focused iTerm window's
// sessions only. All other iTerm panes get the badge cleared so we never
// have stale badge state on a non-focused window. Empty string clears
// everywhere.
//
// Badge is base64-encoded per the OSC 1337 SetBadgeFormat protocol.
func setITermBadge(_ text: String) {
    let encoded = Data(text.utf8).base64EncodedString()
    let setEscape = "\u{001B}]1337;SetBadgeFormat=\(encoded)\u{0007}"
    let clearEscape = "\u{001B}]1337;SetBadgeFormat=\u{0007}"
    let (current, others) = enumerateITermTTYs()

    // Always clear the non-current panes.
    for tty in others {
        if let fh = FileHandle(forWritingAtPath: tty) {
            fh.write(clearEscape.data(using: .utf8)!)
            try? fh.close()
        }
    }

    let payload = text.isEmpty ? clearEscape : setEscape
    var written = 0
    for tty in current {
        if let fh = FileHandle(forWritingAtPath: tty) {
            fh.write(payload.data(using: .utf8)!)
            try? fh.close()
            written += 1
        }
    }

    let label = text.isEmpty ? "cleared" : "= \"\(text)\""
    logLine("badge \(label) on \(written)/\(current.count) current ttys, \(others.count) others cleared")
}

// MARK: - Audio device selection

// Find a CoreAudio input device by substring match against its name.
// Returns the AudioDeviceID, or nil if not found.
func findInputDevice(matching needle: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)

    for dev in devices {
        // Must have input streams.
        var inSize: UInt32 = 0
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(dev, &inAddr, 0, nil, &inSize)
        if inSize == 0 { continue }

        // Read name.
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &nameRef) { ptr -> OSStatus in
            AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, ptr)
        }
        if st != noErr { continue }
        let name = nameRef as String
        if name.localizedCaseInsensitiveContains(needle) {
            return dev
        }
    }
    return nil
}

// Read the current system default input device.
func getDefaultInputDevice() -> AudioDeviceID? {
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev
    )
    return st == noErr ? dev : nil
}

// Set the system default input device. This is a SYSTEM-WIDE change (any
// app that uses default input will follow). We use this approach instead of
// poking `kAudioOutputUnitProperty_CurrentDevice` on the inputNode's
// audioUnit because accessing inputNode.audioUnit on macOS 26 taints the
// CoreAudio session and prevents the engine from ever delivering buffers.
//
// The previous default is captured in `originalInputDevice` and restored on
// shutdown.
func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var dev = deviceID
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let st = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &dev
    )
    return st == noErr
}

// MARK: - Logging

func logLine(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - HTTP helper

func postJSON(_ path: String, _ body: [String: Any]) {
    guard let url = URL(string: DISPATCH_HOST + path) else {
        logLine("postJSON: bad url \(DISPATCH_HOST)\(path)")
        return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 2.0
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let task = URLSession.shared.dataTask(with: req) { _, resp, err in
        if let err = err {
            logLine("POST \(path) FAILED: \(err.localizedDescription)")
        } else if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            logLine("POST \(path) status=\(http.statusCode)")
        }
    }
    task.resume()
}

// Flush the transcript through dispatch's /flush endpoint. Dispatch runs the
// text+CR AppleScript under its `_applescript_lock`, which serializes against
// every other AppleScript dispatch makes (the 0.5s window-layout cache poll,
// /cycle, HUD ops). Earlier versions of this code spawned osascript directly
// from the listener — that bypassed the lock and produced an intermittent
// race where dispatch's poll and our text+CR write contended for iTerm2's
// scripting bridge, causing the CR to get split off and "fire" only on the
// next AppleScript call.
func flushViaDispatch(_ text: String) {
    guard let url = URL(string: DISPATCH_HOST + "/flush") else {
        logLine("flushViaDispatch: bad url")
        return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 5.0
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            logLine("flushViaDispatch failed: \(err.localizedDescription)")
        } else if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            logLine("flushViaDispatch status=\(http.statusCode)")
        } else if let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool, !ok {
            logLine("flushViaDispatch returned ok=false: \(obj)")
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 6.0)
}

// Synchronous GET — used only for discovery probing.
func pingHost(_ host: String, timeout: TimeInterval = 0.5) -> Bool {
    guard let url = URL(string: host + "/ping") else { return false }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200, data != nil {
            ok = true
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.2)
    return ok
}

// Find the dispatch server. It binds port 9879 on either 127.0.0.1, the LAN
// IP, or the Tailscale IP depending on how it was started. Probe candidates.
func findDispatchHost() -> String? {
    var candidates: [String] = ["http://127.0.0.1:9879"]

    // `lsof` tells us exactly what address dispatch is bound to.
    let proc = Process()
    proc.launchPath = "/usr/sbin/lsof"
    proc.arguments = ["-nP", "-iTCP:9879", "-sTCP:LISTEN"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            // e.g. "Python  16852 ... TCP 100.x.y.z:9879 (LISTEN)"
            if let range = line.range(of: #"(\d+\.\d+\.\d+\.\d+):9879"#, options: .regularExpression) {
                let m = String(line[range])
                let host = "http://" + m.replacingOccurrences(of: ":9879", with: "") + ":9879"
                if !candidates.contains(host) { candidates.append(host) }
            }
        }
    } catch {
        logLine("lsof probe failed: \(error)")
    }

    for c in candidates {
        logLine("probing dispatch at \(c)")
        if pingHost(c) {
            logLine("dispatch found at \(c)")
            return c
        }
    }
    return nil
}

// MARK: - State

final class Listener {
    let audioEngine = AVAudioEngine()
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?

    // Partials -> dispatch /stream-text (sequence number for ordering guard).
    var streamSeq: Int = 0
    var lastPartialSentAt: Date = .distantPast
    var hudVisible: Bool = false

    // Bumped on every restartSession(). Stale recognition callbacks compare
    // against this and self-discard.
    var sessionGen: Int = 0

    // Saved on startup so we can restore the user's prior default input
    // device when the listener exits (so AirPods, etc., come back).
    var originalInputDevice: AudioDeviceID? = nil

    // Silence-flush bookkeeping.
    var lastTranscript: String = ""
    var lastTranscriptUpdate: Date = .distantPast
    var flushTimer: Timer?

    // Clap detector state.
    // Last fire time per direction for the spoken-trigger debounce.
    var lastTriggerAt: [String: Date] = [:]

    // When true, mic + STT keep running but nothing goes to dispatch.
    var paused: Bool = false

    func start() {
        logLine("startup: voice-listener launched")

        // Discover dispatch endpoint.
        if let host = findDispatchHost() {
            DISPATCH_HOST = host
        } else {
            logLine("ERROR: dispatch server not reachable on any candidate. Is it running?")
            // Continue anyway so logs accumulate; STT can still work, just no HUD/typing.
        }
        logLine("using dispatch host: \(DISPATCH_HOST)")

        // Pin the system default input to the built-in mic ONCE, before any
        // AVAudioEngine setup. Done at the system-default layer (not via
        // inputNode.audioUnit) because touching inputNode.audioUnit on
        // macOS 26 leaves the engine permanently unable to deliver buffers.
        // The user keeps AirPods for output (full-quality A2DP) and we get
        // the built-in mic for input. Restored on shutdown.
        originalInputDevice = getDefaultInputDevice()
        // Mic selection priority:
        //   1. User's pinned mic from state/preferred-mic (overrides everything,
        //      including AirPods which we'd otherwise skip).
        //   2. Auto-detect fallback list: DJI > MacBook built-in > any built-in.
        //      AirPods deliberately omitted from auto-detect so music stays A2DP.
        // Path is supplied by start.sh via TALK_PREFERRED_MIC_FILE so the binary
        // works no matter where the repo is cloned; falls back to the legacy location.
        let preferredMicPath = ProcessInfo.processInfo.environment["TALK_PREFERRED_MIC_FILE"]
            ?? (NSHomeDirectory() + "/.claude/skills/talk/state/preferred-mic")
        var micCandidates: [String] = []
        if let pinned = try? String(contentsOfFile: preferredMicPath, encoding: .utf8) {
            let trimmed = pinned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                micCandidates.append(trimmed)
                logLine("preferred-mic file specifies: '\(trimmed)'")
            }
        }
        // Always append the auto-detect fallback after the user's pinned choice
        // so that if the pinned device isn't currently connected, we still get
        // a working mic.
        micCandidates.append(contentsOf: ["Wireless Microphone", "DJI", "MacBook", "Built-in"])
        var picked: AudioDeviceID? = nil
        var pickedName: String = ""
        for needle in micCandidates {
            if let id = findInputDevice(matching: needle) {
                picked = id
                pickedName = needle
                break
            }
        }
        if let mic = picked {
            if setSystemDefaultInputDevice(mic) {
                logLine("set system default input to '\(pickedName)' (id=\(mic)); was id=\(originalInputDevice ?? 0)")
            } else {
                logLine("WARN: could not set system default input")
            }
        } else {
            logLine("WARN: no preferred input device found")
        }

        guard let recognizer = recognizer else {
            logLine("ERROR: SFSpeechRecognizer init returned nil (locale en-US unavailable)")
            exit(1)
        }
        guard recognizer.isAvailable else {
            logLine("ERROR: speech recognizer not currently available")
            exit(1)
        }
        logLine("speech recognizer available")

        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                logLine("speech auth: AUTHORIZED")
            case .denied:
                logLine("ERROR speech auth: DENIED — open System Settings > Privacy & Security > Speech Recognition and enable voice-listener")
                exit(1)
            case .restricted:
                logLine("ERROR speech auth: RESTRICTED")
                exit(1)
            case .notDetermined:
                logLine("ERROR speech auth: NOT DETERMINED (no prompt shown?)")
                exit(1)
            @unknown default:
                logLine("ERROR speech auth: unknown status \(status.rawValue)")
                exit(1)
            }
            DispatchQueue.main.async { self.startSession() }
        }

        // Schedule the silence checker on the main runloop.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkSilenceFlush()
            self?.checkRecognitionLiveness()
        }
    }

    // If the recognition task hasn't emitted any partials for 8+ seconds
    // **despite hearing speech-level audio**, the session has silently died
    // (macOS 26 quirk seen after pause/resume cycles). Restart it.
    //
    // We gate on `speechBuffersThisSession` — the count of buffers whose
    // peak amplitude was above the speech-loudness threshold — instead of
    // total buffers, so idle silence doesn't trigger needless restarts.
    func checkRecognitionLiveness() {
        let now = Date()
        let lastActivity = max(sessionStartedAt, lastTranscriptUpdate)
        if lastActivity == .distantPast { return }
        let idle = now.timeIntervalSince(lastActivity)
        if idle > 8.0 && speechBuffersThisSession > 8 {
            logLine("recognition liveness: \(Int(idle))s since last partial; \(speechBuffersThisSession) speech-level buffers heard — forcing session restart")
            sessionStartedAt = now
            speechBuffersThisSession = 0
            DispatchQueue.main.async { self.restartSession() }
        }
    }

    func startSession() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        request = req

        let myGen = sessionGen

        let input = audioEngine.inputNode
        // We never touch inputNode.audioUnit — doing so on macOS 26 leaves
        // the engine permanently unable to deliver buffers. System default
        // input was already pinned in start(), so AVAudioEngine picks up
        // the built-in mic transparently here.
        let format = input.inputFormat(forBus: 0)
        logLine("audio input format: sr=\(format.sampleRate) ch=\(format.channelCount) gen=\(myGen)")

        // Sanity check — a 0-channel or 0-sr format means CoreAudio hasn't
        // settled yet. Bail and let the health check rebuild.
        if format.channelCount == 0 || format.sampleRate == 0 {
            logLine("ERROR: invalid input format, will retry via health check")
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)
            self.bumpAudioCheckpoint()
            // Track speech-level buffers (peak above threshold) so the
            // liveness check only restarts when real speech is being lost.
            if let chan = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var peak: Float = 0
                for i in 0..<frames {
                    let m = abs(chan[i])
                    if m > peak { peak = m }
                }
                if peak > 0.05 {
                    self.speechBuffersThisSession += 1
                }
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                logLine("ERROR audio engine start: \(error.localizedDescription)")
                exit(1)
            }
            logLine("audio engine started")
        }

        // Reset session bookkeeping and arm health check — macOS 26's
        // AVAudioEngine sometimes silently yields zero buffers on first
        // start. We detect that and rebuild.
        totalBuffersThisSession = 0
        speechBuffersThisSession = 0
        sessionStartedAt = Date()
        scheduleAudioHealthCheck()

        task = recognizer!.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            // Drop callbacks from stale sessions.
            if myGen != self.sessionGen { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.handlePartial(text: text)
            }
            if let error = error {
                logLine("recognition error (gen=\(myGen)): \(error.localizedDescription)")
                if myGen == self.sessionGen {
                    // "No speech detected" comes back when Apple Speech
                    // gets bored of a long silent stream. If we restart
                    // immediately the next session will hit the same error
                    // right away — runaway loop. Wait for actual speech
                    // before rebuilding.
                    let nsErr = error as NSError
                    let isNoSpeech = nsErr.localizedDescription
                        .localizedCaseInsensitiveContains("no speech")
                    let delay: TimeInterval = isNoSpeech ? 1.5 : 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if myGen == self.sessionGen {
                            self.restartSession()
                        }
                    }
                }
            }
        }

        logLine("listener active (gen=\(myGen))")

        // Re-assert the badge that matches our current state. We can't
        // unconditionally write BADGE_LISTENING here — restartSession() runs
        // after pause/resume, and startSession() would race the pause path's
        // 🟢 write. Always reflect the actual `paused` flag.
        let badge = paused ? BADGE_PAUSED : BADGE_LISTENING
        DispatchQueue.global().async { setITermBadge(badge) }
    }

    // Heartbeat so we can confirm audio buffers are flowing even when there's
    // no speech to transcribe yet.
    var lastBufferLog: Date = .distantPast
    var bufferCount: Int = 0
    var totalBuffersThisSession: Int = 0
    // Buffers whose peak amplitude exceeded the speech-level threshold.
    // Used by the liveness check to avoid restarting when the user is
    // simply silent.
    var speechBuffersThisSession: Int = 0
    var sessionStartedAt: Date = .distantPast
    var recoveryAttempts: Int = 0

    func bumpAudioCheckpoint() {
        bufferCount += 1
        totalBuffersThisSession += 1
        let now = Date()
        if now.timeIntervalSince(lastBufferLog) >= 5.0 {
            logLine("audio heartbeat: \(bufferCount) buffers in last \(String(format: "%.1f", now.timeIntervalSince(lastBufferLog)))s")
            bufferCount = 0
            lastBufferLog = now
        }
    }

    // Initial-launch audio engine on macOS 26 sometimes never delivers buffers.
    // Check 2s after starting; if zero buffers received, tear down and restart.
    func scheduleAudioHealthCheck() {
        let myGen = sessionGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if myGen != self.sessionGen { return }
            // Healthy means a sustained stream of buffers. macOS 26 sometimes
            // delivers ONE buffer at start and then goes silent, so the
            // threshold must be > 1.
            // 44.1kHz / 1024 frames ≈ 43 buffers/sec → expect 80+ in 2s.
            if self.totalBuffersThisSession < 10 {
                self.recoveryAttempts += 1
                if self.recoveryAttempts > 5 {
                    logLine("ERROR: audio engine stuck across 5 recovery attempts — giving up")
                    exit(1)
                }
                logLine("audio recovery: only \(self.totalBuffersThisSession) buffers in 2s, reinitializing (attempt \(self.recoveryAttempts))")
                self.recoverAudioEngine()
            } else {
                self.recoveryAttempts = 0
            }
        }
    }

    // Recover from "engine started but no buffers" — macOS 26 CoreAudio
    // quirk. Stop the engine, wait for CoreAudio to settle, and restart.
    // We deliberately do NOT call audioEngine.reset() — that scrambles the
    // input format and causes "format mismatch" on the next installTap.
    func recoverAudioEngine() {
        sessionGen += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.startSession()
        }
    }

    func restartSession() {
        sessionGen += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        // Keep the audio engine running across restarts — only the recognition
        // request needs to be torn down. Tearing down the engine causes the
        // ~0.3s gap to drop initial audio of the next utterance.
        audioEngine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.startSession() }
    }

    // MARK: Partial transcript handling

    func handlePartial(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // PAUSED: keep transcribing so we can detect "start listening", but
        // suppress HUD, /stream-text, /flush, and cycle triggers.
        if paused {
            if checkForResume(in: trimmed) {
                logLine("voice trigger: RESUME (matched in: \"\(trimmed)\")")
                paused = false
                DispatchQueue.global().async { setITermBadge(BADGE_LISTENING) }
                swallowCurrentUtterance()
            }
            return
        }

        // Not paused: check for "stop listening" before doing anything else,
        // so the user's pause command never appears in HUD or terminal.
        if checkForPause(in: trimmed) {
            logLine("voice trigger: PAUSE (matched in: \"\(trimmed)\")")
            paused = true
            DispatchQueue.global().async { setITermBadge(BADGE_PAUSED) }
            swallowCurrentUtterance()
            return
        }

        if !hudVisible {
            logLine("partial start: showing HUD")
            // Send the anchor position FIRST. Dispatch caches it as
            // `_pending_hud_position` so it's applied as soon as the HUD
            // spawns regardless of HTTP arrival order.
            DispatchQueue.global().async { anchorHUDToActiveWindow() }
            postJSON("/recording-start", [:])
            hudVisible = true
            // Re-send the position 0.3s later in case the HUD was already
            // alive (no spawn-time apply path) or the cache write raced.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                anchorHUDToActiveWindow()
            }
        }

        if trimmed != lastTranscript {
            lastTranscript = trimmed
            lastTranscriptUpdate = Date()
            streamSeq += 1
            logLine("partial: \(trimmed)")
            postJSON("/stream-text", ["text": trimmed, "seq": streamSeq])

            // Check for window-cycle voice triggers AFTER updating state but
            // BEFORE flush. If matched, the trigger phrase is swallowed: the
            // transcript buffer is cleared and the session restarts so
            // trigger words don't end up in the next flush.
            if checkForCycleTrigger(in: trimmed) { return }
        }
    }

    func checkForPause(in text: String) -> Bool {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return PAUSE_TRIGGER.firstMatch(in: text, options: [], range: range) != nil
    }

    func checkForResume(in text: String) -> Bool {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return RESUME_TRIGGER.firstMatch(in: text, options: [], range: range) != nil
    }

    func checkSilenceFlush() {
        guard !paused else { return }
        guard !lastTranscript.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(lastTranscriptUpdate)
        if elapsed >= SILENCE_FLUSH_SECONDS {
            flushNow()
        }
    }

    func flushNow() {
        let text = lastTranscript
        lastTranscript = ""
        lastTranscriptUpdate = .distantPast
        if hudVisible {
            postJSON("/recording-stop", [:])
            hudVisible = false
        }
        guard !text.isEmpty else { return }

        // Last-chance trigger check. If the flushed text itself is/ends with
        // a trigger phrase, fire it instead of typing into the terminal.
        // Happens when the user says only the trigger phrase ("next project")
        // and goes silent — Apple Speech may finalize the partial before we
        // saw it grow, so checkForCycleTrigger() never fired in handlePartial.
        if checkForCycleTrigger(in: text) {
            logLine("FLUSH swallowed (trigger detected at flush time)")
            DispatchQueue.main.async { self.restartSession() }
            return
        }
        if checkForPause(in: text) {
            logLine("FLUSH swallowed (pause trigger at flush time)")
            paused = true
            DispatchQueue.global().async { setITermBadge(BADGE_PAUSED) }
            DispatchQueue.main.async { self.restartSession() }
            return
        }

        logLine("FLUSH (\(SILENCE_FLUSH_SECONDS)s silence): \(text)")

        // Route the flush through dispatch's /flush endpoint so it runs
        // under dispatch's _applescript_lock (serialized vs. dispatch's
        // own AppleScript activity).
        DispatchQueue.global().async { flushViaDispatch(text) }

        // Apple Speech keeps a session "open" and concatenates new audio onto
        // the previous utterance. After a flush we must tear down and restart
        // the recognition session so the next utterance starts fresh.
        DispatchQueue.main.async { self.restartSession() }
    }

    // MARK: Voice-trigger window cycling

    // Scan a partial transcript for "next/previous {project|window|pane|terminal}".
    // If found, fire the corresponding /cycle and SWALLOW the trigger phrase
    // (clear the transcript buffer and tear down the recognition session so
    // the trigger words don't end up in the next 2.5s flush). Per-direction
    // debounce prevents the same partial from firing twice as it grows.
    func checkForCycleTrigger(in text: String) -> Bool {
        let now = Date()
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        for (regex, direction) in [(NEXT_TRIGGER, "next"), (PREV_TRIGGER, "prev")] {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                if let last = lastTriggerAt[direction], now.timeIntervalSince(last) < 2.0 {
                    return false  // already fired recently for this direction
                }
                lastTriggerAt[direction] = now
                postJSON("/cycle", ["direction": direction, "seq": Int(now.timeIntervalSince1970 * 1000)])
                logLine("voice trigger: \(direction) (matched in: \"\(text)\")")
                swallowCurrentUtterance()
                // /cycle just activated a new iTerm window — re-assert the
                // badge so it follows focus. iTerm's `current window`
                // sometimes lags the activation, so we re-assert at multiple
                // delays (0.4s, 1.0s, 1.6s) to win the race robustly.
                let badge = paused ? BADGE_PAUSED : BADGE_LISTENING
                for d in [0.4, 1.0, 1.6] {
                    DispatchQueue.global().asyncAfter(deadline: .now() + d) {
                        setITermBadge(badge)
                    }
                }
                return true
            }
        }
        return false
    }

    // Drop everything we've buffered for the current utterance, force the
    // HUD closed, and start a fresh recognition session. Used after firing
    // a voice trigger so the trigger words don't appear in the next flush
    // and the HUD doesn't stay stuck showing the trigger phrase.
    func swallowCurrentUtterance() {
        lastTranscript = ""
        lastTranscriptUpdate = .distantPast
        postJSON("/recording-stop", [:])
        hudVisible = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            postJSON("/recording-stop", [:])
        }
        DispatchQueue.main.async { self.restartSession() }
    }
}

// MARK: - Entry

let listener = Listener()

// Clean shutdown on SIGTERM/SIGINT so /talk off doesn't leave the HUD up,
// and restores the user's previous default input device so AirPods etc.
// reclaim the mic.
func cleanShutdown() {
    if listener.hudVisible { postJSON("/recording-stop", [:]) }
    // Always clear the badge on shutdown — otherwise "REC" stays burned
    // into iTerm tabs after /talk off. The prior `paused` guard was wrong
    // (it left the badge stuck whenever the listener was actively
    // listening, which is the common case).
    setITermBadge("")
    if let prev = listener.originalInputDevice, prev != 0 {
        if setSystemDefaultInputDevice(prev) {
            logLine("restored prior default input device id=\(prev)")
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
    exit(0)
}

let sigSrcTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrcTerm.setEventHandler { cleanShutdown() }
sigSrcTerm.resume()
signal(SIGTERM, SIG_IGN)

let sigSrcInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrcInt.setEventHandler { cleanShutdown() }
sigSrcInt.resume()
signal(SIGINT, SIG_IGN)

listener.start()
RunLoop.main.run()
