#!/usr/bin/env bash
# Start the /talk listener.
# - Ensures the dispatch server is running on :9876 (auto-starts if not).
# - Spawns voice-listener as a background daemon, recording its PID.
#
# If /talk started dispatch itself, it writes .dispatch.pid + .dispatch.owned
# so stop.sh knows to shut dispatch down on /talk off. If dispatch was
# already running when /talk on was invoked, /talk leaves it alone on
# shutdown (the user might be running it for other reasons, e.g. iPhone).

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="$SKILL_DIR/.listener.pid"
LOG_FILE="$SKILL_DIR/.listener.log"
LISTENER="$SKILL_DIR/bin/voice-listener"
PREFERRED_MIC_FILE="$SKILL_DIR/state/preferred-mic"
export TALK_PREFERRED_MIC_FILE="$PREFERRED_MIC_FILE"

# Optional first argument: substring of the desired mic device name (e.g.
# "AirPods", "MacBook", "DJI", "Yeti"). Saved to state/preferred-mic and
# applied every time the listener starts.
# - Pass "" (empty) to clear the pin and return to auto-detect.
# - If the listener is already running and a mic is passed, we hot-swap by
#   killing+respawning just the listener; dispatch stays up so the HUD
#   doesn't blip.
MIC_REQUEST="${1-__nochange__}"
# Treat "auto" (case-insensitive) the same as empty string: clear the pin.
MIC_REQUEST_LOWER="$(echo "$MIC_REQUEST" | tr '[:upper:]' '[:lower:]')"
if [ "$MIC_REQUEST_LOWER" = "auto" ]; then
    MIC_REQUEST=""
fi
if [ "$MIC_REQUEST" != "__nochange__" ]; then
    mkdir -p "$SKILL_DIR/state"
    if [ -z "$MIC_REQUEST" ]; then
        rm -f "$PREFERRED_MIC_FILE"
        echo "talk: cleared mic pin (auto-detect)"
    else
        printf '%s' "$MIC_REQUEST" > "$PREFERRED_MIC_FILE"
        echo "talk: pinned mic to match '$MIC_REQUEST'"
    fi
    # Hot-swap: if listener is alive, kill just it so we restart with new pin.
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            echo "talk: hot-swapping (restarting listener, dispatch stays up)"
            kill "$OLD_PID" 2>/dev/null
            for _ in 1 2 3 4 5; do
                kill -0 "$OLD_PID" 2>/dev/null || break
                sleep 0.2
            done
            kill -9 "$OLD_PID" 2>/dev/null || true
            rm -f "$PID_FILE"
        fi
    fi
fi

# talk depends on the dispatch server (github.com/brianharms/dispatch).
# Set DISPATCH_DIR to wherever you cloned it; defaults to ~/dispatch.
DISPATCH_DIR="${DISPATCH_DIR:-$HOME/dispatch}"
DISPATCH_SCRIPT="$DISPATCH_DIR/server/dispatch_server.py"
DISPATCH_PID_FILE="$SKILL_DIR/.dispatch.pid"
DISPATCH_OWNED_FILE="$SKILL_DIR/.dispatch.owned"
DISPATCH_LOG="$SKILL_DIR/.dispatch.log"

# Find a usable Python 3 — prefer Homebrew, fall back to the Xcode-bundled
# Python3 framework that dispatch's launch instructions historically used.
DISPATCH_PY=""
for candidate in \
    /opt/homebrew/bin/python3.14 \
    /opt/homebrew/bin/python3.13 \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python
do
    if [ -x "$candidate" ]; then DISPATCH_PY="$candidate"; break; fi
done

# 1) If a listener is already running, refuse to double-start.
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "talk: already on (pid $OLD_PID)"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

# 2) Ensure dispatch server is up. We probe localhost first; if that doesn't
#    answer, dispatch isn't running OR is bound to a non-localhost address
#    (e.g. Tailscale only). Either way we (re)start it on --lan so localhost
#    works AND iPhone clients on the LAN/Tailnet still reach it.
NEED_DISPATCH_START=0
if curl -fs -m 0.5 http://127.0.0.1:9876/ping >/dev/null 2>&1; then
    : # localhost works, leave it alone
elif pgrep -f dispatch_server.py >/dev/null 2>&1; then
    echo "talk: dispatch is running but not reachable on localhost — leaving it as-is"
    echo "      (if /talk fails to talk to it, restart dispatch with --lan)"
else
    NEED_DISPATCH_START=1
fi

if [ "$NEED_DISPATCH_START" -eq 1 ]; then
    # talk reuses the dispatch server (github.com/brianharms/dispatch) for the
    # HUD, window cycling, and text injection. dispatch is zero-dependency
    # (Python stdlib only) and needs no config to run, so if it isn't present
    # we clone it automatically — a fresh machine self-bootstraps with no
    # manual second clone. Set DISPATCH_DIR to reuse an existing checkout.
    if [ ! -f "$DISPATCH_SCRIPT" ]; then
        echo "talk: dispatch server not found at $DISPATCH_DIR — cloning it (one-time)…"
        if command -v git >/dev/null 2>&1; then
            git clone --depth 1 https://github.com/brianharms/dispatch "$DISPATCH_DIR" \
                >"$DISPATCH_LOG" 2>&1 || true
        fi
    fi
    if [ -z "$DISPATCH_PY" ] || [ ! -f "$DISPATCH_SCRIPT" ]; then
        echo "talk: ERROR — could not obtain the dispatch server."
        echo "      Needed: $DISPATCH_SCRIPT"
        echo "      Fix:    git clone https://github.com/brianharms/dispatch \"$DISPATCH_DIR\""
        echo "              (or set DISPATCH_DIR to an existing dispatch checkout)"
        echo "      python: ${DISPATCH_PY:-(no usable python3 found — install Python 3)}"
        exit 1
    fi
    echo "talk: starting dispatch server..."
    cd "$DISPATCH_DIR" || exit 1
    nohup "$DISPATCH_PY" -u "$DISPATCH_SCRIPT" --lan \
        >"$DISPATCH_LOG" 2>&1 &
    DISPATCH_PID=$!
    echo "$DISPATCH_PID" > "$DISPATCH_PID_FILE"
    # Sentinel that says "we started dispatch" — stop.sh checks this before
    # shutting dispatch down so we don't kill a dispatch the user started
    # manually.
    : > "$DISPATCH_OWNED_FILE"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fs -m 0.5 http://127.0.0.1:9876/ping >/dev/null 2>&1; then break; fi
        sleep 0.3
    done
    if ! curl -fs -m 0.5 http://127.0.0.1:9876/ping >/dev/null 2>&1; then
        echo "talk: ERROR — dispatch failed to come up. Log:"
        tail -20 "$DISPATCH_LOG" 2>/dev/null || true
        rm -f "$DISPATCH_PID_FILE" "$DISPATCH_OWNED_FILE"
        exit 1
    fi
fi

# 3) Spawn the listener.
nohup "$LISTENER" >"$LOG_FILE" 2>&1 &
LISTENER_PID=$!
echo "$LISTENER_PID" > "$PID_FILE"

# Sanity: did it survive the first second?
sleep 1
if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
    echo "talk: listener died on startup. Tail of log:"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 1
fi

echo "talk: ON (pid $LISTENER_PID)"
echo "  speak normally; 2.5s of silence flushes into the active iTerm pane"
echo "  say 'next project/window/pane/terminal' to cycle forward"
echo "  say 'previous/last project/...' to cycle back"
echo "  say 'stop listening' to pause; 'start listening' to resume"
