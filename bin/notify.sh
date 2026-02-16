#!/usr/bin/env bash
# Zapat - Notification Dispatcher
# Sends notifications to Slack and/or GitHub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

# --- Usage ---
usage() {
    cat <<EOF
Usage: notify.sh [OPTIONS]

Options:
  --slack                    Send to Slack webhook
  --github-comment REPO NUM  Post as GitHub comment (e.g., --github-comment owner/repo 123)
  --message TEXT             Message content (or reads from stdin if not provided)
  --job-name NAME            Job name for Slack header
  --status STATUS            success|failure|emergency (default: success)
  --type TYPE                pr|issue (for GitHub comments, default: pr)
  -h, --help                 Show this help

Examples:
  notify.sh --slack --message "Standup complete" --job-name "daily-standup" --status success
  notify.sh --github-comment owner/repo 123 --message "Review done" --type pr
  notify.sh --slack --github-comment owner/repo 42 --message "Triage" --job-name "issue-triage"
EOF
}

# --- Defaults ---
SEND_SLACK=false
SEND_GITHUB=false
GITHUB_REPO=""
GITHUB_NUMBER=""
MESSAGE=""
JOB_NAME="zapat"
STATUS="success"
COMMENT_TYPE="pr"

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --slack)
            SEND_SLACK=true
            shift
            ;;
        --github-comment)
            SEND_GITHUB=true
            GITHUB_REPO="$2"
            GITHUB_NUMBER="$3"
            shift 3
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --job-name)
            JOB_NAME="$2"
            shift 2
            ;;
        --status)
            STATUS="$2"
            shift 2
            ;;
        --type)
            COMMENT_TYPE="$2"
            shift 2
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

# Read from stdin if no message provided
if [[ -z "$MESSAGE" ]]; then
    MESSAGE=$(cat)
fi

if [[ -z "$MESSAGE" ]]; then
    log_error "No message provided"
    exit 1
fi

# --- Markdown to Slack mrkdwn ---
# Slack uses its own markup: *bold*, _italic_, ~strike~, `code`
# No support for ## headers, **bold**, or markdown tables
convert_md_to_slack() {
    # shellcheck disable=SC2016
    python3 -c '
import sys, re

text = sys.stdin.read()

# Remove preamble lines like "I have all the data..." before the first heading or ---
text = re.sub(r"^.*?(?=\n---|\n##)", "", text, count=1, flags=re.DOTALL).lstrip("\n")

# Convert markdown tables to aligned plain text
def convert_table(match):
    lines = match.group(0).strip().split("\n")
    # Filter out separator lines (|---|---|)
    data_lines = [l for l in lines if not re.match(r"^\s*\|[\s\-:|]+\|\s*$", l)]
    if not data_lines:
        return match.group(0)
    rows = []
    for line in data_lines:
        cells = [c.strip() for c in line.strip("|").split("|")]
        rows.append(cells)
    if not rows:
        return match.group(0)
    # Calculate column widths
    col_count = max(len(r) for r in rows)
    widths = [0] * col_count
    for row in rows:
        for i, cell in enumerate(row):
            if i < col_count:
                widths[i] = max(widths[i], len(cell))
    # Format rows
    result = []
    for j, row in enumerate(rows):
        formatted = "  ".join(
            (row[i] if i < len(row) else "").ljust(widths[i])
            for i in range(col_count)
        )
        result.append(formatted)
        if j == 0:
            result.append("  ".join("-" * w for w in widths))
    return "```" + "\n".join(result) + "```"

text = re.sub(r"(\|.+\|[\n]?)+", convert_table, text)

# ## Header and ### Header → *bold* on its own line
text = re.sub(r"^#{1,3}\s+(.+)$", r"*\1*", text, flags=re.MULTILINE)

# **bold** → *bold* (Slack single asterisk)
text = re.sub(r"\*\*(.+?)\*\*", r"*\1*", text)

# --- horizontal rules → divider-like line
text = re.sub(r"^---+\s*$", "─" * 30, text, flags=re.MULTILINE)

# Bullet points: - item → • item
text = re.sub(r"^(\s*)- ", r"\1• ", text, flags=re.MULTILINE)

# Clean up excessive blank lines
text = re.sub(r"\n{3,}", "\n\n", text)

print(text.strip())
'
}

# --- Slack ---
send_slack() {
    local webhook_url="${SLACK_WEBHOOK_URL:-}"
    if [[ -z "$webhook_url" ]]; then
        log_error "SLACK_WEBHOOK_URL not set"
        return 1
    fi

    # Status emoji
    local emoji
    case "$STATUS" in
        success)   emoji="white_check_mark" ;;
        failure)   emoji="x" ;;
        emergency) emoji="rotating_light" ;;
        *)         emoji="information_source" ;;
    esac

    # Convert markdown to Slack mrkdwn format
    local slack_msg
    slack_msg=$(echo "$MESSAGE" | convert_md_to_slack)

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname_val
    hostname_val=$(hostname)

    # Split long messages into chunks and write to temp files
    local chunk_dir
    chunk_dir=$(mktemp -d)
    trap 'rm -rf '"'$chunk_dir'"'' RETURN

    python3 -c "
import sys, os, json

msg = sys.stdin.read()
chunk_dir = sys.argv[1]
MAX_CHUNK = 2800

if len(msg) <= 3000:
    with open(os.path.join(chunk_dir, 'chunk_001.txt'), 'w') as f:
        f.write(msg)
else:
    paragraphs = msg.split('\n\n')
    chunks = []
    current = ''
    for para in paragraphs:
        if current and len(current) + len(para) + 2 > MAX_CHUNK:
            chunks.append(current.strip())
            current = para
        else:
            current = current + '\n\n' + para if current else para
    if current.strip():
        chunks.append(current.strip())
    # Safety: hard-split any chunk still over limit
    final = []
    for chunk in chunks:
        while len(chunk) > MAX_CHUNK:
            split_at = chunk.rfind('\n', 0, MAX_CHUNK)
            if split_at == -1:
                split_at = MAX_CHUNK
            final.append(chunk[:split_at].strip())
            chunk = chunk[split_at:].strip()
        if chunk:
            final.append(chunk)
    for i, chunk in enumerate(final, 1):
        with open(os.path.join(chunk_dir, f'chunk_{i:03d}.txt'), 'w') as f:
            f.write(chunk)
" "$chunk_dir" <<< "$slack_msg"

    local chunk_files=("$chunk_dir"/chunk_*.txt)
    local chunk_count=${#chunk_files[@]}
    local send_failed=0

    for i in $(seq 1 "$chunk_count"); do
        local chunk_file
        chunk_file="$chunk_dir/chunk_$(printf '%03d' "$i").txt"
        [[ -f "$chunk_file" ]] || continue
        local payload

        if [[ $i -eq 1 ]]; then
            # First chunk: header + section + context
            payload=$(python3 -c "
import json, sys
emoji = sys.argv[1]
job_name = sys.argv[2]
status = sys.argv[3]
timestamp = sys.argv[4]
hostname = sys.argv[5]
total = int(sys.argv[6])
msg = sys.stdin.read()

suffix = f' (1/{total})' if total > 1 else ''
blocks = [
    {
        'type': 'header',
        'text': {
            'type': 'plain_text',
            'text': f':{emoji}: {job_name} ({status}){suffix}',
            'emoji': True
        }
    },
    {
        'type': 'section',
        'text': {
            'type': 'mrkdwn',
            'text': msg
        }
    },
    {
        'type': 'context',
        'elements': [
            {
                'type': 'mrkdwn',
                'text': f'Zapat | {hostname} | {timestamp}'
            }
        ]
    }
]
print(json.dumps({'blocks': blocks}))
" "$emoji" "$JOB_NAME" "$STATUS" "$timestamp" "$hostname_val" "$chunk_count" < "$chunk_file")
        else
            # Continuation chunks: section + context only
            payload=$(python3 -c "
import json, sys
job_name = sys.argv[1]
idx = sys.argv[2]
total = sys.argv[3]
msg = sys.stdin.read()

blocks = [
    {
        'type': 'section',
        'text': {
            'type': 'mrkdwn',
            'text': msg
        }
    },
    {
        'type': 'context',
        'elements': [
            {
                'type': 'mrkdwn',
                'text': f'{job_name} (continued {idx}/{total})'
            }
        ]
    }
]
print(json.dumps({'blocks': blocks}))
" "$JOB_NAME" "$i" "$chunk_count" < "$chunk_file")
            # Delay between messages to preserve ordering
            sleep 0.5
        fi

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$webhook_url")

        if [[ "$http_code" == "200" ]]; then
            log_info "Slack notification sent (${STATUS}, chunk ${i}/${chunk_count})"
        else
            log_error "Slack notification failed (HTTP ${http_code}, chunk ${i}/${chunk_count})"
            send_failed=1
        fi
    done

    if [[ $send_failed -ne 0 ]]; then
        return 1
    fi
}

# --- GitHub Comment ---
send_github_comment() {
    if [[ -z "$GITHUB_REPO" || -z "$GITHUB_NUMBER" ]]; then
        log_error "GitHub repo and number required for comments"
        return 1
    fi

    # Wrap in collapsible details
    local body
    body=$(cat <<EOBODY
<details>
<summary>Agent Analysis — ${JOB_NAME}</summary>

${MESSAGE}

</details>

---
_Generated by [Zapat](https://github.com/zapat-ai/zapat)_
EOBODY
)

    if [[ "$COMMENT_TYPE" == "issue" ]]; then
        if gh issue comment "$GITHUB_NUMBER" --repo "$GITHUB_REPO" --body "$body"; then
            log_info "GitHub comment posted on ${GITHUB_REPO}#${GITHUB_NUMBER}"
        else
            log_error "Failed to post GitHub comment on ${GITHUB_REPO}#${GITHUB_NUMBER}"
            return 1
        fi
    else
        if gh pr comment "$GITHUB_NUMBER" --repo "$GITHUB_REPO" --body "$body"; then
            log_info "GitHub comment posted on ${GITHUB_REPO}#${GITHUB_NUMBER}"
        else
            log_error "Failed to post GitHub comment on ${GITHUB_REPO}#${GITHUB_NUMBER}"
            return 1
        fi
    fi
}

# --- Emergency Alert ---
send_emergency() {
    local webhook_url="${SLACK_WEBHOOK_URL:-}"
    if [[ -z "$webhook_url" ]]; then
        log_error "SLACK_WEBHOOK_URL not set, cannot send emergency alert"
        return 1
    fi

    local escaped_msg
    escaped_msg=$(echo "$MESSAGE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    escaped_msg="${escaped_msg:1:${#escaped_msg}-2}"

    local payload
    payload=$(cat <<EOJSON
{
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": ":rotating_light: EMERGENCY — Zapat Down",
                "emoji": true
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*${JOB_NAME}* failed critically:\\n${escaped_msg}\\n\\n*Action required:* SSH into $(hostname) and run:\\n\`bin/startup.sh\`"
            }
        }
    ]
}
EOJSON
)

    curl -s -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$webhook_url"

    log_warn "Emergency alert sent to Slack"
}

# --- Main ---

# Emergency status always goes to Slack
if [[ "$STATUS" == "emergency" ]]; then
    send_emergency
    exit 0
fi

EXIT_CODE=0

if [[ "$SEND_SLACK" == "true" ]]; then
    send_slack || EXIT_CODE=1
fi

if [[ "$SEND_GITHUB" == "true" ]]; then
    send_github_comment || EXIT_CODE=1
fi

exit $EXIT_CODE
