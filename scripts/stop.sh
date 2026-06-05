#!/usr/bin/env bash
# Stop the /talk listener.
# If we started dispatch ourselves (start.sh wrote .dispatch.owned), stop
# dispatch too. Otherwise leave it alone — the user may want to keep it
# running for the iPhone or other clients.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="$SKILL_DIR/.listener.pid"
DISPATCH_PID_FILE="$SKILL_DIR/.dispatch.pid"
DISPATCH_OWNED_FILE="$SKILL_DIR/.dispatch.owned"

stopped_listener=0

# 1) Stop the listener.
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            kill -KILL "$PID" 2>/dev/null || true
        fi
        stopped_listener=1
    fi
    rm -f "$PID_FILE"
fi

# Sweep any orphaned listener processes (PID file lost but binary running).
if pgrep -f "$SKILL_DIR/bin/voice-listener" >/dev/null 2>&1; then
    pkill -TERM -f "$SKILL_DIR/bin/voice-listener" 2>/dev/null || true
    stopped_listener=1
fi

# 2) Stop dispatch if /talk started it.
stopped_dispatch=0
if [ -f "$DISPATCH_OWNED_FILE" ]; then
    DPID=$(cat "$DISPATCH_PID_FILE" 2>/dev/null || true)
    if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
        kill -TERM "$DPID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$DPID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$DPID" 2>/dev/null; then
            kill -KILL "$DPID" 2>/dev/null || true
        fi
        stopped_dispatch=1
    fi
    # Belt: in case the recorded PID is stale but a dispatch we own is still
    # alive (e.g. fork happened), kill anything matching dispatch_server.py.
    if pgrep -f dispatch_server.py >/dev/null 2>&1; then
        pkill -TERM -f dispatch_server.py 2>/dev/null || true
        stopped_dispatch=1
    fi
    rm -f "$DISPATCH_PID_FILE" "$DISPATCH_OWNED_FILE"
fi

if [ "$stopped_listener" -eq 1 ] && [ "$stopped_dispatch" -eq 1 ]; then
    echo "talk: OFF (listener + dispatch stopped)"
elif [ "$stopped_listener" -eq 1 ]; then
    if pgrep -f dispatch_server.py >/dev/null 2>&1; then
        echo "talk: OFF (listener stopped; dispatch left running — wasn't ours)"
    else
        echo "talk: OFF"
    fi
elif [ "$stopped_dispatch" -eq 1 ]; then
    echo "talk: OFF (dispatch stopped; no listener was running)"
else
    echo "talk: already off"
fi
