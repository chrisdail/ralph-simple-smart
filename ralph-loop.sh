#!/usr/bin/env bash
set -uo pipefail

MAGENTA='\033[0;35m'
NC='\033[0m'

# Allowed tools for non-auto mode. Override via RALPH_ALLOWED_TOOLS env var.
# Space-separated list of tool patterns.
RALPH_ALLOWED_TOOLS="${RALPH_ALLOWED_TOOLS:-Bash(gh *) Bash(git *) Bash(npm *) Bash(npx *) Bash(ls *) Bash(cp *) Bash(cat *) Bash(find *) Bash(grep *)}"

ralph() {
    echo -e "${MAGENTA}[ralph] $*${NC}" >&2
}

show_usage() {
    echo "Usage: $(basename "$0") [OPTIONS] PROMPT"
    echo ""
    echo "Run Claude in a loop until completion, max iterations, or usage threshold."
    echo ""
    echo "Arguments:"
    echo "  PROMPT                     Prompt string or @filename"
    echo ""
    echo "Options:"
    echo "  --auto-mode                Use auto permission mode (requires Team/Enterprise plan)"
    echo "  --max-iterations N         Max loop iterations (default: 1, or 999 with --max-session-usage)"
    echo "  --max-session-usage PCT    Stop when session usage reaches PCT% (e.g. 70)"
    echo "  --logs DIR                 Save iteration logs to DIR (default: auto-removed temp files)"
    echo "  -h, --help                 Show this help"
    echo ""
    echo "Environment:"
    echo "  RALPH_ALLOWED_TOOLS        Override default allowed tools (space-separated patterns)"
    exit 1
}

auto_mode=""
max_iterations=""
max_session_usage=""
logs_dir=""
prompt=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-mode)
            auto_mode=1
            shift
            ;;
        --max-iterations)
            max_iterations="$2"
            shift 2
            ;;
        --max-session-usage)
            max_session_usage="$2"
            shift 2
            ;;
        --logs)
            logs_dir="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_usage
            ;;
        *)
            prompt="$1"
            shift
            ;;
    esac
done

if [[ -z "$prompt" ]]; then
    echo "Error: PROMPT is required" >&2
    show_usage
fi

# Default max_iterations based on whether usage threshold is set
if [[ -z "$max_iterations" ]]; then
    if [[ -n "$max_session_usage" ]]; then
        max_iterations=999
    else
        max_iterations=1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "$logs_dir" ]]; then
    mkdir -p "$logs_dir"
fi

temp_logs=()
cleanup_temp_logs() {
    for f in "${temp_logs[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
if [[ -z "$logs_dir" ]]; then
    trap cleanup_temp_logs EXIT
fi

on_interrupt() {
    echo
    ralph "Interrupted, terminating claude..."
    pkill -TERM -P $$ 2>/dev/null || true
    exit 130
}
trap on_interrupt INT

get_usage() {
    local output
    output=$("$SCRIPT_DIR/claude-usage.sh" 2>/dev/null)
    local session_pct weekly_pct
    session_pct=$(echo "$output" | grep -i "session" | grep -oE '[0-9]+' | head -1 || true)
    weekly_pct=$(echo "$output" | grep -i "weekly" | grep -oE '[0-9]+' | head -1 || true)
    echo "${session_pct:-0} ${weekly_pct:-0}"
}

check_usage() {
    local usage
    usage=$(get_usage)
    local session_pct weekly_pct
    session_pct=$(echo "$usage" | awk '{print $1}')
    weekly_pct=$(echo "$usage" | awk '{print $2}')

    ralph "Session usage: ${session_pct}% | Weekly usage: ${weekly_pct}%"

    if [[ -n "$max_session_usage" ]] && [[ "$session_pct" -ge "$max_session_usage" ]]; then
        ralph "Stopping: session usage ${session_pct}% reached threshold of ${max_session_usage}%"
        exit 0
    fi
}

for (( i=1; i<=max_iterations; i++ )); do
    ralph "=== Iteration $i/$max_iterations === ($(date '+%Y-%m-%d %H:%M:%S'))"

    check_usage

    iteration_start=$(date +%s)

    if [[ -n "$logs_dir" ]]; then
        output_file="$logs_dir/ralph-$(date '+%Y%m%d-%H%M%S')-iter${i}.log"
        log_msg=" (output: $output_file)"
    else
        output_file=$(mktemp -t ralph-loop.XXXXXX)
        temp_logs+=("$output_file")
        log_msg=""
    fi

    claude_args=(-p "$prompt" --output-format stream-json --verbose --include-partial-messages)
    if [[ -n "$auto_mode" ]]; then
        claude_args+=(--permission-mode auto)
        ralph "Running claude (auto mode)...${log_msg}"
    else
        claude_args+=(--permission-mode acceptEdits)
        # shellcheck disable=SC2086
        for tool in $RALPH_ALLOWED_TOOLS; do
            claude_args+=(--allowedTools "$tool")
        done
        ralph "Running claude...${log_msg}"
    fi
    claude "${claude_args[@]}" \
        2>/dev/null \
        | tee "$output_file" \
        | jq --unbuffered -rj '
            def cyan: "\u001b[0;36m" + . + "\u001b[0m";
            def dim: "\u001b[2m" + . + "\u001b[0m";
            def tool_summary:
                if .name == "Read" then "Read " + (.input.file_path // "" | split("/") | last)
                elif .name == "Edit" then "Edit " + (.input.file_path // "" | split("/") | last)
                elif .name == "Write" then "Write " + (.input.file_path // "" | split("/") | last)
                elif .name == "Glob" then "Glob " + (.input.pattern // "")
                elif .name == "Grep" then "Grep " + (.input.pattern // "")
                elif .name == "Bash" then "Bash " + ((.input.command // "") | if length > 60 then .[:60] + "..." else . end)
                elif .name == "Agent" then "Agent " + (.input.description // "")
                else .name + " " + (.input | tostring | if length > 60 then .[:60] + "..." else . end)
                end;
            if .type == "stream_event" then
                if .event.type == "content_block_delta" and .event.delta.type == "text_delta" then
                    .event.delta.text // empty
                elif .event.type == "content_block_stop" then
                    "\n"
                else empty end
            elif .type == "assistant" then
                (.message.content[]? |
                    if .type == "tool_use" then
                        "\n" + ("[" + tool_summary + "]" | cyan) + "\n"
                    elif .type == "tool_result" then
                        ((.content // "") | if length > 200 then .[:200] + "..." else . end | dim) + "\n"
                    else empty end
                ) // empty
            else empty end'
    claude_exit=${PIPESTATUS[0]}
    echo

    iteration_end=$(date +%s)
    duration=$(( iteration_end - iteration_start ))

    if [[ $claude_exit -ne 0 ]]; then
        ralph "Warning: claude exited with code $claude_exit"
    fi

    if jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$output_file" 2>/dev/null | grep -q '<promise>COMPLETE</promise>'; then
        ralph "Complete: promise COMPLETE received on iteration $i"
        if [[ -n "$logs_dir" ]]; then
            ralph "Log file: $output_file"
        fi
        exit 0
    fi

    if [[ -n "$logs_dir" ]]; then
        ralph "Iteration $i complete (${duration}s) - log: $output_file"
    else
        ralph "Iteration $i complete (${duration}s)"
    fi
done

ralph "Stopping: max iterations ($max_iterations) reached"
