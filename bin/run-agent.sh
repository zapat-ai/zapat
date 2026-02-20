#!/usr/bin/env bash
# Zapat - Core Agent Runner
# Every automation calls through this wrapper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Usage ---
usage() {
    cat <<EOF
Usage: run-agent.sh [OPTIONS]

Options:
  --job-name NAME           Job identifier for logging and notifications
  --prompt-file FILE        Path to prompt template file
  --prompt TEXT             Direct prompt text (alternative to --prompt-file)
  --budget USD              Max budget in USD (default: 5)
  --allowed-tools TOOLS     Comma-separated tool list (default: Read,Glob,Grep)
  --notify CHANNEL          Notification channels: slack, github, or both (comma-separated)
  --github-comment REPO#NUM GitHub comment target (e.g., owner/repo#123)
  --timeout SECONDS         Max runtime in seconds (default: 600)
  --model MODEL             Override Claude model (default: CLAUDE_MODEL or claude-opus-4-6)
  --project SLUG            Target a specific project (loads project.env overrides)
  --substitutions K=V...    Prompt placeholder substitutions (repeatable)
  -h, --help                Show this help

Exit codes:
  0 = success
  1 = environment error
  2 = timeout
  3 = claude error
EOF
}

# --- Defaults ---
JOB_NAME=""
PROMPT_FILE=""
PROMPT_TEXT=""
BUDGET=5
ALLOWED_TOOLS="Read,Glob,Grep"
NOTIFY_CHANNELS=""
GITHUB_TARGET=""
TIMEOUT=600
AGENT_MODEL=""
PROJECT=""
SUBSTITUTIONS=()

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --job-name)
            JOB_NAME="$2"
            shift 2
            ;;
        --prompt-file)
            PROMPT_FILE="$2"
            shift 2
            ;;
        --prompt)
            PROMPT_TEXT="$2"
            shift 2
            ;;
        --budget)
            BUDGET="$2"
            shift 2
            ;;
        --allowed-tools)
            ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --notify)
            NOTIFY_CHANNELS="$2"
            shift 2
            ;;
        --github-comment)
            GITHUB_TARGET="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --model)
            AGENT_MODEL="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --substitutions)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SUBSTITUTIONS+=("$1")
                shift
            done
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Validate ---
if [[ -z "$JOB_NAME" ]]; then
    log_error "Job name is required (--job-name)"
    exit 1
fi

# --- Load Environment ---
load_env

# --- Activate Project (if specified) ---
if [[ -n "$PROJECT" ]]; then
    set_project "$PROJECT"
fi

# --- Pre-flight Checks ---
if ! check_prereqs; then
    log_error "Prerequisites check failed"
    # Send emergency alert
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Prerequisites check failed for job '$JOB_NAME'. Keychain may be locked or auth expired." \
        --job-name "$JOB_NAME" \
        --status emergency
    exit 1
fi

# --- Build Prompt ---
FINAL_PROMPT=""

if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_error "Prompt file not found: $PROMPT_FILE"
        exit 1
    fi
    # Add default DATE substitution
    SUBSTITUTIONS+=("DATE=$(date '+%Y-%m-%d')")
    if [[ "$(detect_os)" == "macos" ]]; then
        SUBSTITUTIONS+=("WEEK_START=$(date -v-7d '+%Y-%m-%d')")
    else
        SUBSTITUTIONS+=("WEEK_START=$(date -d '7 days ago' '+%Y-%m-%d')")
    fi
    SUBSTITUTIONS+=("MONTH_START=$(date '+%Y-%m-01')")
    FINAL_PROMPT=$(substitute_prompt "$PROMPT_FILE" "${SUBSTITUTIONS[@]}")
elif [[ -n "$PROMPT_TEXT" ]]; then
    FINAL_PROMPT="$PROMPT_TEXT"
else
    log_error "Either --prompt-file or --prompt is required"
    exit 1
fi

if [[ -z "$FINAL_PROMPT" ]]; then
    log_error "Prompt is empty after substitution"
    exit 1
fi

# --- Prepare Logging ---
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d-%H%M%S')
LOG_FILE="${LOG_DIR}/${JOB_NAME}-${TIMESTAMP}.log"

EFFECTIVE_MODEL="${AGENT_MODEL:-${CLAUDE_MODEL:-claude-opus-4-6}}"

log_info "Starting job: $JOB_NAME"
log_info "Model: $EFFECTIVE_MODEL"
log_info "Budget: \$${BUDGET}"
log_info "Timeout: ${TIMEOUT}s"
log_info "Log: $LOG_FILE"

# --- Run Claude ---
CLAUDE_EXIT=0
CLAUDE_OUTPUT=""
START_TIME=$(date +%s)
START_TIME_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Write prompt to temp file to avoid arg length limits
PROMPT_TMPFILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_TMPFILE"
trap 'rm -f "$PROMPT_TMPFILE"' EXIT

# Use gtimeout on macOS, timeout on Linux
if [[ "$(detect_os)" == "macos" ]]; then
    TIMEOUT_CMD="gtimeout"
else
    TIMEOUT_CMD="timeout"
fi

CLAUDE_OUTPUT=$($TIMEOUT_CMD "${TIMEOUT}" claude \
    -p "$(cat "$PROMPT_TMPFILE")" \
    --model "$EFFECTIVE_MODEL" \
    --allowedTools "$ALLOWED_TOOLS" \
    --max-budget-usd "$BUDGET" \
    2>&1) || CLAUDE_EXIT=$?

# Write output to log
{
    echo "=== Zapat ==="
    echo "Job: $JOB_NAME"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Model: $EFFECTIVE_MODEL"
    echo "Budget: \$${BUDGET}"
    echo "Exit Code: $CLAUDE_EXIT"
    echo "==================================="
    echo ""
    echo "$CLAUDE_OUTPUT"
} > "$LOG_FILE"

log_info "Output written to $LOG_FILE"

# --- Handle Result ---
if [[ $CLAUDE_EXIT -eq 124 ]]; then
    log_error "Job timed out after ${TIMEOUT}s"
    NOTIFY_STATUS="failure"
    NOTIFY_MSG="Job '$JOB_NAME' timed out after ${TIMEOUT} seconds.

Last output:
$(echo "$CLAUDE_OUTPUT" | tail -50)"
    EXIT_CODE=2
elif [[ $CLAUDE_EXIT -ne 0 ]]; then
    log_error "Claude exited with code $CLAUDE_EXIT"
    NOTIFY_STATUS="failure"
    NOTIFY_MSG="Job '$JOB_NAME' failed (exit code: $CLAUDE_EXIT).

Output:
$(echo "$CLAUDE_OUTPUT" | tail -100)"
    EXIT_CODE=3
else
    log_info "Job completed successfully"
    NOTIFY_STATUS="success"
    NOTIFY_MSG="$CLAUDE_OUTPUT"
    EXIT_CODE=0
fi

# --- Send Notifications ---
if [[ -n "$NOTIFY_CHANNELS" ]]; then
    NOTIFY_ARGS=()

    if echo "$NOTIFY_CHANNELS" | grep -q "slack"; then
        NOTIFY_ARGS+=(--slack)
    fi

    if [[ -n "$GITHUB_TARGET" ]]; then
        # Parse owner/repo#number
        GITHUB_REPO="${GITHUB_TARGET%%#*}"
        GITHUB_NUM="${GITHUB_TARGET##*#}"
        NOTIFY_ARGS+=(--github-comment "$GITHUB_REPO" "$GITHUB_NUM")

        # Determine if PR or issue based on job name
        if [[ "$JOB_NAME" == *"issue"* ]]; then
            NOTIFY_ARGS+=(--type issue)
        else
            NOTIFY_ARGS+=(--type pr)
        fi
    fi

    "$SCRIPT_DIR/bin/notify.sh" \
        "${NOTIFY_ARGS[@]}" \
        --message "$NOTIFY_MSG" \
        --job-name "$JOB_NAME" \
        --status "$NOTIFY_STATUS" || log_warn "Notification failed"
fi

# --- Record Metrics ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    "$SCRIPT_DIR/bin/zapat" metrics record "{\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"project\":\"${CURRENT_PROJECT:-default}\",\"job\":\"$JOB_NAME\",\"repo\":\"\",\"item\":\"\",\"exit_code\":$CLAUDE_EXIT,\"start\":\"$START_TIME_ISO\",\"end\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"duration_s\":$DURATION,\"status\":\"$NOTIFY_STATUS\"}" 2>/dev/null || true
fi

# --- Structured Log ---
_log_structured "info" "Job $JOB_NAME completed" "\"job\":\"$JOB_NAME\",\"exit_code\":$CLAUDE_EXIT,\"duration_s\":$DURATION,\"status\":\"$NOTIFY_STATUS\"" 2>/dev/null || true

exit $EXIT_CODE
