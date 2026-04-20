#!/usr/bin/env bash
set -uo pipefail

show_usage() {
    echo "Usage: $(basename "$0") [-w] [-s]"
    echo "  -w  Show weekly usage percentage"
    echo "  -s  Show current session usage percentage"
    echo "  (no flags shows both)"
    exit 1
}

show_weekly=false
show_session=false

while getopts "wsh" opt; do
    case "$opt" in
        w) show_weekly=true ;;
        s) show_session=true ;;
        h) show_usage ;;
        *) show_usage ;;
    esac
done

if ! $show_weekly && ! $show_session; then
    show_weekly=true
    show_session=true
fi

SESSION_NAME="claude-usage-$$"

cleanup() {
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
}
trap cleanup EXIT

wait_for() {
    local pattern="$1"
    local max_attempts="${2:-20}"
    for i in $(seq 1 "$max_attempts"); do
        sleep 0.5
        raw=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
        if echo "$raw" | grep -q "$pattern"; then
            return 0
        fi
    done
    return 1
}

tmux new-session -d -s "$SESSION_NAME" -x 120 -y 50 "env -u CLAUDECODE claude"

if ! wait_for "❯" 20; then
    echo "Error: claude failed to start" >&2
    exit 1
fi

tmux send-keys -t "$SESSION_NAME" "/usage"
sleep 0.5
tmux send-keys -t "$SESSION_NAME" Enter

if ! wait_for "Current" 20; then
    echo "Error: usage dialog failed to appear" >&2
    exit 1
fi

raw=$(tmux capture-pane -t "$SESSION_NAME" -p)

tmux send-keys -t "$SESSION_NAME" Escape
sleep 0.3
tmux send-keys -t "$SESSION_NAME" "/exit" Enter
sleep 0.5

session_pct=$(echo "$raw" | grep -i "current session" -A2 | grep -oE '[0-9]+%' | head -1 || true)
weekly_pct=$(echo "$raw" | grep -iE "current week" -A4 | grep -oE '[0-9]+%' | head -1 || true)

if $show_session; then
    echo "Session: ${session_pct:-N/A}"
fi
if $show_weekly; then
    echo "Weekly: ${weekly_pct:-N/A}"
fi
