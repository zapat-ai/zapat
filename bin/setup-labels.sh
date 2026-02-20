#!/usr/bin/env bash
# Zapat - GitHub Labels Setup
# Creates consistent labels across all configured repos.
# Run manually: bin/setup-labels.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Repos (read from config/repos.conf) ---
REPOS=()
while IFS=$'\t' read -r repo local_path repo_type; do
    [[ -z "$repo" ]] && continue
    REPOS+=("$repo")
done < <(read_repos)

if [[ ${#REPOS[@]} -eq 0 ]]; then
    log_error "No repos found in config/repos.conf"
    exit 1
fi

# --- Labels: name|color|description ---
LABELS=(
    # Tier 1 — User-facing
    "agent|1D76DB|Let the pipeline handle this"
    # Tier 2 — Power-user
    "agent-work|0E8A16|Skip triage, implement immediately"
    "agent-research|0075CA|Research and analyze, not code"
    "hold|B60205|Block auto-merge on this PR"
    "human-only|E4E669|Pipeline should not touch this item"
    "agent-full-review|1D76DB|Force full team review regardless of complexity"
    # Tier 3 — Internal/status
    "zapat-triaging|CCCCCC|Triage in progress"
    "zapat-implementing|CCCCCC|Implementation in progress"
    "zapat-review|CCCCCC|Code review pending"
    "zapat-testing|CCCCCC|Test run pending"
    "zapat-rework|CCCCCC|Addressing review feedback"
    "zapat-researching|CCCCCC|Research in progress"
    "needs-rebase|CCCCCC|Auto-rebase failed, manual resolution needed"
    "agent-write-tests|0E8A16|Write tests for specified code"
    # Classification
    "feature|0075CA|New feature"
    "bug|D73A49|Bug fix"
    "tech-debt|FBCA04|Technical debt"
    "security|B60205|Security issue"
    "research|C5DEF5|Research task"
    # Priority
    "P0-critical|B60205|Critical priority"
    "P1-high|D93F0B|High priority"
    "P2-medium|FBCA04|Medium priority"
    "P3-low|0E8A16|Low priority"
)

# --- Verify gh auth ---
if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated. Run: gh auth login -h github.com -p ssh"
    exit 1
fi

# --- Create Labels ---
TOTAL=0
SUCCESS=0
FAILED=0

for repo in "${REPOS[@]}"; do
    echo ""
    log_info "Setting up labels for $repo..."

    for label_def in "${LABELS[@]}"; do
        IFS='|' read -r name color description <<< "$label_def"
        TOTAL=$((TOTAL + 1))

        if gh label create "$name" \
            --color "$color" \
            --description "$description" \
            --repo "$repo" \
            --force &>/dev/null; then
            SUCCESS=$((SUCCESS + 1))
        else
            log_warn "Failed to create label '$name' in $repo"
            FAILED=$((FAILED + 1))
        fi
    done

    log_info "Done with $repo"
done

# --- Summary ---
echo ""
echo "============================================"
echo "  Label Setup Complete"
echo "============================================"
echo ""
echo "  Repos:    ${#REPOS[@]}"
echo "  Labels:   ${#LABELS[@]} per repo"
echo "  Total:    $TOTAL operations"
echo "  Success:  $SUCCESS"
echo "  Failed:   $FAILED"
echo ""
