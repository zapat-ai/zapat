#!/usr/bin/env bash
# Zapat — Shared Library
# Source this file in all scripts: source "$SCRIPT_DIR/lib/common.sh"

set -euo pipefail

# Detect operating system
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

# Ensure tools are on PATH (critical for cron jobs)
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi

# Resolve automation root directory
AUTOMATION_DIR="${AUTOMATION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Current project context (set by set_project(), used by all project-scoped functions)
CURRENT_PROJECT="${CURRENT_PROJECT:-}"

# --- Logging ---

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# Structured JSON logging — writes to logs/structured.jsonl alongside normal output
# Usage: _log_structured "level" "message" ["extra_json_fields"]
_log_structured() {
    local level="$1" message="$2" extra="${3:-}"
    local log_dir="${AUTOMATION_DIR}/logs"
    local log_file="${log_dir}/structured.jsonl"
    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local hostname_val
    hostname_val=$(hostname -s 2>/dev/null || echo "unknown")

    local json="{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$message\",\"project\":\"${CURRENT_PROJECT:-default}\",\"hostname\":\"$hostname_val\",\"pid\":$$"
    if [[ -n "$extra" ]]; then
        json="${json},${extra}"
    fi
    json="${json}}"

    echo "$json" >> "$log_file" 2>/dev/null || true
}

# --- Environment ---

load_env() {
    local env_file="${AUTOMATION_DIR}/.env"
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        log_error "Copy .env.example to .env and fill in values: cp .env.example .env"
        return 1
    fi
    # Export variables from .env, skipping comments and blank lines
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Remove leading/trailing whitespace from key
        key=$(echo "$key" | xargs)
        # Remove surrounding quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        export "$key=$value"
    done < "$env_file"
    log_info "Environment loaded from $env_file"
}

# --- Multi-Project Support ---

# Read project slugs. Output: one slug per line.
# Tier 1: config/projects.conf manifest
# Tier 2: scan config/*/ directories that contain repos.conf
# Tier 3: legacy single-project (synthesize "default")
read_projects() {
    local conf="${AUTOMATION_DIR}/config/projects.conf"

    # Tier 1: explicit manifest
    if [[ -f "$conf" ]]; then
        while IFS=$'\t' read -r slug _name enabled; do
            [[ -z "$slug" || "$slug" =~ ^[[:space:]]*# ]] && continue
            [[ "${enabled:-true}" == "true" ]] && echo "$slug"
        done < "$conf"
        return 0
    fi

    # Tier 2: scan config/*/ for directories containing repos.conf
    local found=0
    for dir in "${AUTOMATION_DIR}"/config/*/; do
        [[ -d "$dir" && -f "$dir/repos.conf" ]] || continue
        basename "$dir"
        found=1
    done
    [[ $found -eq 1 ]] && return 0

    # Tier 3: legacy — top-level repos.conf exists
    if [[ -f "${AUTOMATION_DIR}/config/repos.conf" ]]; then
        echo "default"
        return 0
    fi

    log_error "No projects found (no projects.conf, no config/*/, no config/repos.conf)"
    return 1
}

# Returns the config directory for a project.
# Legacy: "default" with no config/default/ dir → top-level config/
project_config_dir() {
    local slug="${1:-${CURRENT_PROJECT:-default}}"

    # Legacy fallback: bare config/repos.conf, no config/default/ directory
    if [[ "$slug" == "default" && ! -d "${AUTOMATION_DIR}/config/default" \
          && -f "${AUTOMATION_DIR}/config/repos.conf" ]]; then
        echo "${AUTOMATION_DIR}/config"
        return 0
    fi

    echo "${AUTOMATION_DIR}/config/${slug}"
}

# Activate a project context. Layers project.env on top of global .env.
# Usage: set_project "my-project"
set_project() {
    local slug="$1"
    CURRENT_PROJECT="$slug"
    export CURRENT_PROJECT

    local project_env
    project_env="$(project_config_dir "$slug")/project.env"

    if [[ -f "$project_env" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key=$(echo "$key" | xargs)
            value="${value%\"}" ; value="${value#\"}"
            value="${value%\'}" ; value="${value#\'}"
            export "$key=$value"
        done < "$project_env"
    fi
}

# Get the agent memory directory for the current project
project_agent_memory_dir() {
    local slug="${1:-${CURRENT_PROJECT:-default}}"
    local dir="$HOME/.claude/agent-memory/projects/${slug}"
    mkdir -p "$dir"
    echo "$dir"
}

# Validate that no repo appears in more than one project
# Returns 0 if no overlap, 1 if overlap found
validate_no_repo_overlap() {
    local projects
    projects=$(read_projects 2>/dev/null) || return 0

    local project_count
    project_count=$(echo "$projects" | wc -l | tr -d ' ')
    [[ "$project_count" -le 1 ]] && return 0

    # Build associative array of repo → first project seen
    local -A seen_repos
    local has_overlap=0

    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        while IFS=$'\t' read -r repo _path _type; do
            [[ -z "$repo" ]] && continue
            if [[ -n "${seen_repos[$repo]:-}" ]]; then
                log_error "Repo $repo appears in both '${seen_repos[$repo]}' and '$proj'"
                has_overlap=1
            else
                seen_repos[$repo]="$proj"
            fi
        done < <(read_repos "$proj" 2>/dev/null)
    done <<< "$projects"

    if [[ $has_overlap -eq 0 ]]; then
        log_info "Repo ownership validation passed (no overlaps)"
    fi
    return $has_overlap
}

# Initialize a new project directory with template config files.
# Usage: init_project "my-project"
# Creates config/{slug}/ with repos.conf, agents.conf, project-context.txt, project.env
init_project() {
    local slug="$1"

    if [[ -z "$slug" ]]; then
        log_error "Project slug is required"
        return 1
    fi

    # Validate slug format: lowercase, hyphens, digits only
    if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        log_error "Invalid project slug '$slug'. Use lowercase letters, digits, and hyphens."
        return 1
    fi

    local project_dir="${AUTOMATION_DIR}/config/${slug}"

    if [[ -d "$project_dir" ]]; then
        log_error "Project directory already exists: $project_dir"
        return 1
    fi

    mkdir -p "$project_dir"

    # repos.conf — copy example or create minimal template
    if [[ -f "${AUTOMATION_DIR}/config/repos.conf.example" ]]; then
        cp "${AUTOMATION_DIR}/config/repos.conf.example" "$project_dir/repos.conf"
    else
        cat > "$project_dir/repos.conf" <<'TMPL'
# Zapat — Repository Configuration
# Format: owner/repo<TAB>local_path<TAB>type
# Types: backend, web, ios, mobile, extension, marketing, other
#
# Examples:
# your-org/backend	/home/you/code/backend	backend
# your-org/web-app	/home/you/code/web-app	web
TMPL
    fi

    # agents.conf — copy example or create minimal template
    if [[ -f "${AUTOMATION_DIR}/config/agents.conf.example" ]]; then
        cp "${AUTOMATION_DIR}/config/agents.conf.example" "$project_dir/agents.conf"
    else
        cat > "$project_dir/agents.conf" <<'TMPL'
# Zapat — Agent Team Configuration
# Maps team roles to agent persona file names (without .md extension)
builder=engineer
security=security-reviewer
product=product-manager
ux=ux-reviewer
TMPL
    fi

    # project-context.txt — copy example or create minimal template
    if [[ -f "${AUTOMATION_DIR}/config/project-context.example.txt" ]]; then
        cp "${AUTOMATION_DIR}/config/project-context.example.txt" "$project_dir/project-context.txt"
    else
        cat > "$project_dir/project-context.txt" <<TMPL
# Project Context for ${slug}
# Describe your system architecture here.
# This is injected into agent prompts as {{PROJECT_CONTEXT}}.
TMPL
    fi

    # project.env — empty overrides file
    cat > "$project_dir/project.env" <<TMPL
# Project-specific environment overrides for ${slug}
# Variables here override the global .env for this project only.
# Example:
# CLAUDE_MODEL=claude-sonnet-4-5-20250929
# AUTO_MERGE_ENABLED=false
TMPL

    log_info "Project '${slug}' initialized at $project_dir"
    log_info "Next steps:"
    log_info "  1. Edit $project_dir/repos.conf — add your repositories"
    log_info "  2. Edit $project_dir/project-context.txt — describe your architecture"
    log_info "  3. (Optional) Edit $project_dir/agents.conf — customize agent roles"
    log_info "  4. (Optional) Edit $project_dir/project.env — override env vars"
}

# --- Pre-flight Checks ---

PREREQ_FAILURES=""

check_prereqs() {
    local failed=0
    PREREQ_FAILURES=""

    # Check tmux session exists (proxy for keychain being unlocked)
    if ! tmux has-session -t zapat 2>/dev/null; then
        log_warn "tmux session 'zapat' not found, recreating..."
        if tmux new-session -d -s zapat 2>/dev/null; then
            log_info "tmux session 'zapat' recreated"
        else
            log_error "Failed to recreate tmux session 'zapat'"
            PREREQ_FAILURES="${PREREQ_FAILURES}\n- tmux session creation failed"
            failed=1
        fi
    fi

    # Check gh CLI is authenticated (GH_TOKEN from .env is preferred for cron)
    # Use 'gh auth token' which checks locally without making an API call
    local gh_token
    if gh_token=$(gh auth token 2>/dev/null) && [[ -n "$gh_token" ]]; then
        log_info "GitHub CLI token configured"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        log_info "GitHub CLI using GH_TOKEN from .env"
    else
        log_error "GitHub CLI not authenticated. Set GH_TOKEN in .env or run: gh auth login"
        PREREQ_FAILURES="${PREREQ_FAILURES}\n- No GitHub token found (GH_TOKEN not set, gh auth token empty)"
        failed=1
    fi

    # Check AI CLI is available (provider-aware)
    if [[ -f "${AUTOMATION_DIR}/lib/provider.sh" ]] && declare -f provider_prereq_check &>/dev/null; then
        local provider_failures
        if ! provider_failures=$(provider_prereq_check); then
            log_error "${AGENT_PROVIDER:-claude} provider prerequisites failed"
            PREREQ_FAILURES="${PREREQ_FAILURES}${provider_failures}"
            failed=1
        fi
    else
        # Fallback: check claude CLI directly
        if ! command -v claude &>/dev/null; then
            log_error "claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
            PREREQ_FAILURES="${PREREQ_FAILURES}\n- claude CLI not found"
            failed=1
        fi
    fi

    # Check jq is available
    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Install: brew install jq"
        PREREQ_FAILURES="${PREREQ_FAILURES}\n- jq not found"
        failed=1
    fi

    # Check Claude Code agent teams setting (warn only, don't block)
    local claude_settings="$HOME/.claude/settings.json"
    if [[ -f "$claude_settings" ]]; then
        local teams_enabled
        teams_enabled=$(jq -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS // empty' "$claude_settings" 2>/dev/null)
        if [[ "$teams_enabled" != "1" ]]; then
            log_warn "Agent teams not enabled in Claude Code settings."
            log_warn "Interactive sessions will not be able to use agent teams."
            log_warn "To fix, add to $claude_settings:"
            log_warn '  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }'
        fi
    else
        log_warn "Claude Code settings not found at $claude_settings"
        log_warn "Agent teams require: \"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" }"
    fi

    if [[ $failed -ne 0 ]]; then
        return 1
    fi

    log_info "All prerequisites satisfied"
    return 0
}

# --- File Locking ---

acquire_lock() {
    local lock_file="$1"
    local lock_dir="${lock_file}.d"

    # Ensure parent directory exists
    mkdir -p "$(dirname "$lock_file")"

    # mkdir is atomic on POSIX systems — no TOCTOU race
    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$lock_dir/pid"
        log_info "Lock acquired: $lock_file (pid: $$)"
        return 0
    fi

    # Lock exists — check if holder is still alive
    local pid
    pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log_warn "Lock held by active process $pid ($lock_file)"
        return 1
    fi

    # Stale lock — remove and retry
    log_warn "Removing stale lock $lock_file (pid: $pid)"
    rm -rf "$lock_dir"

    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$lock_dir/pid"
        log_info "Lock acquired (after stale cleanup): $lock_file (pid: $$)"
        return 0
    fi

    # Race condition — another process got it first
    log_warn "Lock contention on $lock_file, backing off"
    return 1
}

release_lock() {
    local lock_file="$1"
    rm -rf "${lock_file}.d"
    log_info "Lock released: $lock_file"
}

# --- Slot-based Concurrency ---

# Acquire a concurrency slot. Allows up to MAX concurrent sessions.
# Usage: acquire_slot "state/agent-work-slots" 10 [job_type] [repo] [number]
# Returns 0 on success (slot file path in $SLOT_FILE), 1 if at capacity.
# Slot file is JSON: {"pid":…,"job_type":…,"repo":…,"number":…,"started_at":…}
acquire_slot() {
    local slot_dir="$1"
    local max_concurrent="${2:-10}"
    local job_type="${3:-unknown}"
    local repo="${4:-}"
    local number="${5:-}"
    mkdir -p "$slot_dir"

    # Clean up stale slots (process no longer running)
    for slot in "$slot_dir"/slot-*.pid; do
        [[ -f "$slot" ]] || continue
        local pid
        # Support both legacy plain-PID files and new JSON files
        local content
        content=$(cat "$slot" 2>/dev/null || echo "")
        if echo "$content" | grep -q '^{'; then
            pid=$(echo "$content" | grep -o '"pid":[0-9]*' | grep -o '[0-9]*')
        else
            pid="$content"
        fi
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            log_warn "Removing stale slot $slot (pid: $pid)"
            rm -f "$slot"
        fi
    done

    # Count active slots
    local active
    active=$(find "$slot_dir" -maxdepth 1 -name 'slot-*.pid' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$active" -ge "$max_concurrent" ]]; then
        log_warn "Concurrency limit reached: $active/$max_concurrent active sessions"
        return 1
    fi

    # Create slot with metadata
    SLOT_FILE="$slot_dir/slot-$$.pid"
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"pid":%s,"job_type":"%s","repo":"%s","number":"%s","started_at":"%s"}\n' \
        "$$" "$job_type" "$repo" "$number" "$started_at" > "$SLOT_FILE"
    log_info "Slot acquired: $SLOT_FILE ($((active + 1))/$max_concurrent active)"
    return 0
}

release_slot() {
    local slot_file="$1"
    rm -f "$slot_file"
    log_info "Slot released: $slot_file"
}

# --- Cleanup ---

cleanup_on_exit() {
    local lock_file="${1:-}"
    local item_state_file="${2:-}"
    local exit_code="${3:-0}"

    if [[ -n "$lock_file" ]]; then
        # Check if it's a slot file or a lock file
        if [[ "$lock_file" == *"/slot-"* ]]; then
            [[ -f "$lock_file" ]] && release_slot "$lock_file"
        else
            # Lock files now use .d directories
            [[ -d "${lock_file}.d" ]] && release_lock "$lock_file"
        fi
    fi

    # Update item state on failure (non-zero exit)
    if [[ -n "$item_state_file" && -f "$item_state_file" && "$exit_code" -ne 0 ]]; then
        update_item_state "$item_state_file" "failed" "Trigger exited with code $exit_code"
    fi
}

# --- Repo Helpers ---

# Read repos.conf for the current project and output: owner/repo local_path type (one per line)
read_repos() {
    local slug="${1:-${CURRENT_PROJECT:-default}}"
    local conf
    conf="$(project_config_dir "$slug")/repos.conf"
    if [[ ! -f "$conf" ]]; then
        log_error "repos.conf not found at $conf (project: ${slug})"
        return 1
    fi
    grep -v '^#' "$conf" | grep -v '^[[:space:]]*$'
}

# Create a fresh, detached worktree at WORKTREE_DIR from origin's default branch.
# Usage: ensure_repo_fresh REPO_PATH WORKTREE_DIR
# Returns 0 on success, 1 on failure (caller should fall back to REPO_PATH).
ensure_repo_fresh() {
    local repo_path="$1"
    local worktree_dir="$2"

    if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
        log_warn "Not a git repo: $repo_path — skipping worktree setup"
        return 1
    fi

    # Fetch latest refs (tolerate failure — agents will read cached state)
    git -C "$repo_path" fetch origin 2>/dev/null || log_warn "git fetch failed for $repo_path — using cached refs"

    # Determine default branch via remote HEAD
    local default_branch
    default_branch=$(git -C "$repo_path" remote show origin 2>/dev/null \
        | sed -n 's/.*HEAD branch: //p')
    if [[ -z "$default_branch" ]]; then
        # Fallback: try main then master
        if git -C "$repo_path" rev-parse --verify "origin/main" &>/dev/null; then
            default_branch="main"
        elif git -C "$repo_path" rev-parse --verify "origin/master" &>/dev/null; then
            default_branch="master"
        else
            log_warn "Cannot determine default branch for $repo_path"
            return 1
        fi
    fi

    # Clean up any stale worktree at the target path
    if [[ -d "$worktree_dir" ]]; then
        log_warn "Cleaning up stale readonly worktree at $worktree_dir"
        git -C "$repo_path" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    fi

    # Create detached worktree from origin/<default_branch>
    mkdir -p "$(dirname "$worktree_dir")"
    if ! git -C "$repo_path" worktree add --detach "$worktree_dir" "origin/${default_branch}" 2>/dev/null; then
        log_warn "Failed to create readonly worktree at $worktree_dir"
        return 1
    fi

    log_info "Readonly worktree created at $worktree_dir (origin/${default_branch})"
    return 0
}

# Remove a readonly worktree created by ensure_repo_fresh.
# Safe to call even if already removed.
# Usage: cleanup_readonly_worktree REPO_PATH WORKTREE_DIR
cleanup_readonly_worktree() {
    local repo_path="$1"
    local worktree_dir="$2"

    [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]] && return 0

    git -C "$repo_path" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
}

# --- Agent Configuration ---

# Read agents.conf for the current project and set role variables
# Sets: BUILDER_AGENT, SECURITY_AGENT, PRODUCT_AGENT, UX_AGENT, plus any custom roles
# Optional second parameter: repo_type (e.g., "ios", "web", "backend", "extension")
# When provided, lines like "builder.ios=ios-engineer" override the default "builder=engineer"
read_agents_conf() {
    local slug="${1:-${CURRENT_PROJECT:-default}}"
    local repo_type="${2:-}"
    local conf
    conf="$(project_config_dir "$slug")/agents.conf"
    if [[ ! -f "$conf" ]]; then
        # Fall back to defaults
        BUILDER_AGENT="engineer"
        SECURITY_AGENT="security-reviewer"
        PRODUCT_AGENT="product-manager"
        UX_AGENT="ux-reviewer"
        return 0
    fi

    # PASS 1: Load role=persona defaults
    while IFS='=' read -r role persona; do
        [[ -z "$role" || "$role" =~ ^[[:space:]]*# ]] && continue
        role=$(echo "$role" | xargs)
        persona=$(echo "$persona" | xargs)
        # Skip repo-type overrides (contain a dot) in pass 1
        [[ "$role" == *.* ]] && continue
        case "$role" in
            builder)    BUILDER_AGENT="$persona" ;;
            security)   SECURITY_AGENT="$persona" ;;
            product)    PRODUCT_AGENT="$persona" ;;
            ux)         UX_AGENT="$persona" ;;
            compliance) COMPLIANCE_AGENT="$persona" ;;
            *)          local upper_role; upper_role=$(echo "$role" | tr '[:lower:]' '[:upper:]')
                        export "AGENT_${upper_role}=$persona" ;;
        esac
    done < "$conf"

    # PASS 2: Overlay role.<repo_type>=persona overrides
    if [[ -n "$repo_type" ]]; then
        while IFS='=' read -r role persona; do
            [[ -z "$role" || "$role" =~ ^[[:space:]]*# ]] && continue
            role=$(echo "$role" | xargs)
            persona=$(echo "$persona" | xargs)
            # Only process lines matching role.<repo_type>
            [[ "$role" != *.* ]] && continue
            local base_role="${role%%.*}"
            local override_type="${role#*.}"
            [[ "$override_type" != "$repo_type" ]] && continue
            case "$base_role" in
                builder)    BUILDER_AGENT="$persona" ;;
                security)   SECURITY_AGENT="$persona" ;;
                product)    PRODUCT_AGENT="$persona" ;;
                ux)         UX_AGENT="$persona" ;;
                compliance) COMPLIANCE_AGENT="$persona" ;;
                *)          local upper_base; upper_base=$(echo "$base_role" | tr '[:lower:]' '[:upper:]')
                            export "AGENT_${upper_base}=$persona" ;;
            esac
        done < "$conf"
    fi

    # Ensure defaults for any unset roles
    BUILDER_AGENT="${BUILDER_AGENT:-engineer}"
    SECURITY_AGENT="${SECURITY_AGENT:-security-reviewer}"
    PRODUCT_AGENT="${PRODUCT_AGENT:-product-manager}"
    UX_AGENT="${UX_AGENT:-ux-reviewer}"
}

# Generate a formatted repo map from repos.conf
_generate_repo_map() {
    local map=""
    while IFS=$'\t' read -r repo local_path repo_type; do
        [[ -z "$repo" ]] && continue
        map="${map}- ${repo} (${repo_type}) -> ${local_path}\n"
    done < <(read_repos 2>/dev/null)
    echo -e "$map"
}

# Generate compliance rules block (empty if compliance mode is off)
_generate_compliance_rules() {
    if [[ "${ENABLE_COMPLIANCE_MODE:-false}" == "true" ]]; then
        local agent="${COMPLIANCE_AGENT:-}"
        if [[ -n "$agent" ]]; then
            echo "## Compliance Review Required
- Spawn a compliance reviewer (subagent_type: ${agent}) to review all changes
- Ensure data handling follows regulatory requirements
- Check for sensitive data exposure in logs, error messages, and responses
- Verify encryption at rest and in transit for sensitive data"
        else
            echo "## Compliance Mode Active
- Review all changes for regulatory compliance
- Check for sensitive data exposure in logs, error messages, and responses
- Verify encryption at rest and in transit for sensitive data"
        fi
    fi
}

# --- Project Context ---

# Load project context for the current project
load_project_context() {
    local slug="${1:-${CURRENT_PROJECT:-default}}"
    local ctx_file
    ctx_file="$(project_config_dir "$slug")/project-context.txt"
    if [[ -f "$ctx_file" ]]; then
        cat "$ctx_file"
    fi
}

# --- Prompt Substitution ---

# Prompt Caching Notes:
# Claude Code automatically caches static system prompt prefixes. The generated
# prompt becomes part of the system prompt, so content order matters:
#   - Static instructions (template text, shared footer) → cached across invocations
#   - Dynamic placeholders ({{ISSUE_BODY}}, {{PR_DIFF}}) → vary per invocation
# Templates should keep static instructions first and dynamic content (issue body,
# PR diff, etc.) early in the details section. The shared footer (_shared-footer.txt)
# is appended identically across all invocations, maximizing cache hits for the
# trailing portion of the prompt.

# Replace {{PLACEHOLDER}} in a file with values
# Auto-injects: REPO_MAP, BUILDER_AGENT, SECURITY_AGENT, PRODUCT_AGENT, UX_AGENT,
#               ORG_NAME, COMPLIANCE_RULES, PROJECT_CONTEXT, SUBAGENT_MODEL, REPO_TYPE
# Usage: substitute_prompt "template.txt" "DATE=2026-02-06" "ISSUE_NUMBER=42"
substitute_prompt() {
    local template="$1"
    shift
    local content
    content=$(cat "$template")

    # Append shared footer if it exists in the same directory
    local footer_file
    footer_file="$(dirname "$template")/_shared-footer.txt"
    if [[ -f "$footer_file" ]]; then
        content="${content}
$(cat "$footer_file")"
    fi

    # Derive Task tool model shorthand from subagent model env var.
    # Uses provider_get_model_shorthand() if available, otherwise falls back to
    # pattern matching for Claude model names.
    local _subagent_model="sonnet"
    local _raw_subagent_model="${CLAUDE_SUBAGENT_MODEL:-}"
    # Codex provider uses its own model env var
    if [[ "${AGENT_PROVIDER:-claude}" == "codex" ]]; then
        _raw_subagent_model="${CODEX_SUBAGENT_MODEL:-${_raw_subagent_model}}"
    fi
    if declare -f provider_get_model_shorthand &>/dev/null && [[ -n "$_raw_subagent_model" ]]; then
        _subagent_model="$(provider_get_model_shorthand "$_raw_subagent_model")"
    else
        case "$_raw_subagent_model" in
            *opus*) _subagent_model="opus" ;;
            *haiku*) _subagent_model="haiku" ;;
            *sonnet*) _subagent_model="sonnet" ;;
        esac
    fi

    # Determine provider (claude or codex)
    local _provider="${PROVIDER:-claude}"

    # For Codex provider, use Codex model name instead of Claude's
    if [[ "$_provider" == "codex" ]]; then
        _subagent_model="${CODEX_MODEL:-o3}"
    fi

    # Cap PR_DIFF at configurable limit (~40,000 characters ≈ ~10,000 tokens)
    local max_diff_chars="${MAX_DIFF_CHARS:-40000}"
    [[ "$max_diff_chars" =~ ^[0-9]+$ ]] || max_diff_chars=40000
    local pr_number_val="" repo_val=""
    local -a capped_args=()
    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        case "$key" in
            PR_NUMBER) pr_number_val="$value" ;;
            REPO)      repo_val="$value" ;;
        esac
        if [[ "$key" == "PR_DIFF" && ${#value} -gt $max_diff_chars ]]; then
            local total_lines total_chars
            total_lines=$(printf '%s\n' "$value" | wc -l | tr -d ' ')
            total_chars=${#value}
            local shown_lines
            shown_lines=$(printf '%s' "${value:0:$max_diff_chars}" | wc -l | tr -d ' ')
            value="${value:0:$max_diff_chars}

--- DIFF TRUNCATED ---
Showing first ~${shown_lines} lines of ${total_lines} total lines (~${max_diff_chars} of ${total_chars} total chars).
⚠️  All reviewers MUST fetch the full diff before reviewing:
  gh pr diff ${pr_number_val} --repo ${repo_val}"
        fi
        capped_args+=("${key}=${value}")
    done

    # PASS 1: Apply explicit KEY=VALUE overrides first
    # This ensures TASK_ASSESSMENT (which contains {{PLACEHOLDER}} tokens) is expanded
    # before auto-injection resolves those inner tokens.
    if [[ ${#capped_args[@]} -gt 0 ]]; then
        for pair in "${capped_args[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            content="${content//\{\{${key}\}\}/${value}}"
        done
    fi

    # PASS 1.5: Process provider-conditional blocks
    # Strip blocks for the inactive provider, unwrap blocks for the active provider
    if [[ "$_provider" == "claude" ]]; then
        # Remove {{#IF_CODEX}}...{{/IF_CODEX}} blocks (including tags and content)
        while [[ "$content" == *'{{#IF_CODEX}}'* ]]; do
            local before="${content%%\{\{#IF_CODEX\}\}*}"
            local after="${content#*\{\{/IF_CODEX\}\}}"
            content="${before}${after}"
        done
        # Unwrap {{#IF_CLAUDE}}...{{/IF_CLAUDE}} blocks (remove tags, keep content)
        content="${content//\{\{#IF_CLAUDE\}\}/}"
        content="${content//\{\{\/IF_CLAUDE\}\}/}"
    elif [[ "$_provider" == "codex" ]]; then
        # Remove {{#IF_CLAUDE}}...{{/IF_CLAUDE}} blocks (including tags and content)
        while [[ "$content" == *'{{#IF_CLAUDE}}'* ]]; do
            local before="${content%%\{\{#IF_CLAUDE\}\}*}"
            local after="${content#*\{\{/IF_CLAUDE\}\}}"
            content="${before}${after}"
        done
        # Unwrap {{#IF_CODEX}}...{{/IF_CODEX}} blocks (remove tags, keep content)
        content="${content//\{\{#IF_CODEX\}\}/}"
        content="${content//\{\{\/IF_CODEX\}\}/}"
    fi

    # PASS 2: Auto-inject standard variables (resolves all remaining {{PLACEHOLDER}} tokens)
    # Extract REPO_TYPE from explicit args for repo-type-aware agent selection
    local _repo_type=""
    if [[ ${#capped_args[@]} -gt 0 ]]; then
        for pair in "${capped_args[@]}"; do
            if [[ "${pair%%=*}" == "REPO_TYPE" ]]; then
                _repo_type="${pair#*=}"
                break
            fi
        done
    fi
    read_agents_conf "" "$_repo_type" 2>/dev/null || true
    local repo_map
    repo_map=$(_generate_repo_map)
    local compliance_rules
    compliance_rules=$(_generate_compliance_rules)
    local project_context
    project_context=$(load_project_context "")

    content="${content//\{\{REPO_MAP\}\}/${repo_map}}"
    content="${content//\{\{BUILDER_AGENT\}\}/${BUILDER_AGENT:-engineer}}"
    content="${content//\{\{SECURITY_AGENT\}\}/${SECURITY_AGENT:-security-reviewer}}"
    content="${content//\{\{PRODUCT_AGENT\}\}/${PRODUCT_AGENT:-product-manager}}"
    content="${content//\{\{UX_AGENT\}\}/${UX_AGENT:-ux-reviewer}}"
    content="${content//\{\{ORG_NAME\}\}/${GITHUB_ORG:-}}"
    content="${content//\{\{COMPLIANCE_RULES\}\}/${compliance_rules}}"
    content="${content//\{\{PROJECT_CONTEXT\}\}/${project_context}}"
    content="${content//\{\{PROJECT_NAME\}\}/${CURRENT_PROJECT:-default}}"
    content="${content//\{\{SUBAGENT_MODEL\}\}/${_subagent_model}}"
    content="${content//\{\{REPO_TYPE\}\}/${_repo_type}}"
    content="${content//\{\{PROVIDER\}\}/${_provider}}"

    echo "$content"
}

# --- Complexity Classification ---

# Classify task complexity to determine team sizing.
# Returns: "solo" | "duo" | "full"
#
# Heuristics:
#   solo: files_changed <= 2 AND additions+deletions <= 100 AND no security-sensitive paths
#   duo:  files_changed <= 5 AND additions+deletions <= 300 AND no cross-service indicators
#   full: everything else, OR security/auth/migration keywords, OR 3+ top-level directories
#
# Usage: classify_complexity FILES_CHANGED ADDITIONS DELETIONS FILE_LIST [ISSUE_BODY]
classify_complexity() {
    local files_changed="${1:-0}"
    local additions="${2:-0}"
    local deletions="${3:-0}"
    local file_list="${4:-}"
    local issue_body="${5:-}"

    # Validate numeric inputs defensively
    [[ "$files_changed" =~ ^[0-9]+$ ]] || files_changed=0
    [[ "$additions" =~ ^[0-9]+$ ]] || additions=0
    [[ "$deletions" =~ ^[0-9]+$ ]] || deletions=0

    local total_changes=$((additions + deletions))

    # Check for security-sensitive directory paths in file list
    local has_security=false
    if [[ -n "$file_list" ]] && echo "$file_list" | grep -qiE '(^|/)(auth|middleware|security|crypto|session|token|password|oauth|secrets|credentials|creds|keys|ssl|tls|certs|permissions|rbac|acl|migrations?|migrate)/'; then
        has_security=true
    fi

    # Check for security-sensitive file patterns (not just directories)
    if [[ "$has_security" == "false" && -n "$file_list" ]]; then
        if echo "$file_list" | grep -qiE '(\.env|\.key|\.pem|\.p12|\.cert|\.github/workflows/)'; then
            has_security=true
        fi
    fi

    # Check for keywords in issue/PR body that indicate full review
    local has_keywords=false
    if [[ -n "$issue_body" ]] && echo "$issue_body" | grep -qiE '\b(security|authenticat|authoriz|migration|breaking.change|vulnerability|CVE|exploit|injection|XSS|CSRF|SSRF|encryption|decrypt|privilege|escalation|credential|secret|api.key)'; then
        has_keywords=true
    fi

    # Count unique top-level directories from file list
    local top_dirs=0
    if [[ -n "$file_list" ]]; then
        top_dirs=$(echo "$file_list" | sed 's|/.*||' | sort -u | wc -l | tr -d ' ')
    fi

    # Full: security concerns, large scope, or cross-service changes
    if $has_security || $has_keywords || [[ "$top_dirs" -ge 3 ]] || \
       [[ "$files_changed" -gt 5 ]] || [[ "$total_changes" -gt 300 ]]; then
        echo "full"
        return 0
    fi

    # Unknown scope: all metrics are zero and no file list — floor at duo
    # This prevents issues (where diff is unavailable) from bypassing security review
    if [[ "$files_changed" -eq 0 ]] && [[ "$total_changes" -eq 0 ]] && [[ -z "$file_list" ]]; then
        echo "duo"
        return 0
    fi

    # Solo: small, contained changes
    if [[ "$files_changed" -le 2 ]] && [[ "$total_changes" -le 100 ]]; then
        echo "solo"
        return 0
    fi

    # Duo: medium scope
    echo "duo"
    return 0
}

# Generate a task assessment with recommendations for team composition and model assignment.
# The lead agent has full authority to adjust team size and per-agent models.
# Usage: generate_task_assessment COMPLEXITY JOB_TYPE
#   COMPLEXITY: "solo" | "duo" | "full"
#   JOB_TYPE: "implement" | "review" | "rework"
#
# NOTE: The output contains {{PLACEHOLDER}} tokens (e.g. {{BUILDER_AGENT}},
# {{SUBAGENT_MODEL}}). These are intentional — they will be resolved downstream
# by substitute_prompt() PASS 2 when the full prompt is assembled.
generate_task_assessment() {
    local complexity="${1:-full}"
    local job_type="${2:-implement}"

    # --- Section A: Leadership Principles ---
    cat <<'PRINCIPLES'
## Decision Framework — Leadership Principles

You are the engineering lead. Use these principles to guide every decision about team composition, model assignment, and quality trade-offs:

1. **Customer obsession** — The end user's experience comes first. Code quality, reliability, and correctness are non-negotiable.
2. **Deliver results** — Ship working code that meets acceptance criteria. Don't over-optimize process at the cost of delivery.
3. **Earn trust** — Produce code that's safe, secure, and well-tested. When unsure, escalate to a human rather than guessing.
4. **Insist on high standards** — Never cut corners on security, testing, or code quality. The complexity classification determines your minimum team — never go below it. Use specialist reviewers; self-review is not a substitute.
5. **Deep dive** — Understand the problem before writing code. Read surrounding code, check for existing patterns, verify assumptions. Go beyond the diff — check callers in unmodified files, trace data flows end-to-end.
6. **Invent and simplify** — Prefer the simplest correct solution. Don't over-engineer.
7. **Bias for action** — Make team/model decisions quickly based on available signals. Don't wait for perfect information.
8. **Quality over speed** — Spawn the team the complexity warrants. A missed security issue or incorrect implementation costs far more to fix after merge than spawning an extra reviewer costs upfront.

PRINCIPLES

    # --- Section B: Complexity Assessment ---
    printf '## Complexity Assessment\n\n'
    case "$complexity" in
        solo) printf '**Classification: Solo** — Small, contained changes (≤2 files, ≤100 LOC, no security-sensitive paths).\n\n' ;;
        duo)  printf '**Classification: Duo** — Moderate scope (≤5 files, ≤300 LOC) or unknown scope requiring at least a security check.\n\n' ;;
        full) printf '**Classification: Full** — Large scope, security-sensitive, cross-service, or 3+ top-level directories.\n\n' ;;
        *)    printf '**Classification: Full** (unknown complexity "%s" defaulted to full).\n\n' "$complexity" ;;
    esac

    # --- Section C: Recommended Team ---
    printf '## Recommended Team\n\n'
    case "$job_type" in
        implement)
            case "$complexity" in
                solo) cat <<'REC_SOLO_IMPL'
**Recommendation: Work solo.** Small scope — no team needed, but a rigorous security self-check is mandatory before creating the PR.
- Lead implements, writes tests, commits, and creates PR.
- Skip team creation and team shutdown steps in the workflow below.
- **Mandatory pre-PR security checklist (do not skip):**
  - [ ] No hardcoded secrets, API keys, tokens, or credentials
  - [ ] No user-controlled input used in shell commands, SQL queries, or file paths without sanitization
  - [ ] No sensitive data (PHI, PII, credentials) logged or included in error responses
  - [ ] Auth checks are present wherever data is accessed or modified
  - [ ] All callers of any modified function have been checked — including in unmodified files

REC_SOLO_IMPL
                    ;;
                duo) cat <<'REC_DUO_IMPL'
**Recommendation: Core team (3 agents).**
- **builder** (`subagent_type: {{BUILDER_AGENT}}`): Implements code changes. Only teammate that writes code.
- **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`): Reviews for hardcoded secrets, insecure storage, missing auth, OWASP vulnerabilities. Also checks all callers of modified functions in unmodified files.
- **product-manager** (`subagent_type: {{PRODUCT_AGENT}}`): Validates the implementation meets the issue's acceptance criteria. Ensures nothing is over-engineered or under-scoped.

REC_DUO_IMPL
                    ;;
                full|*) cat <<'REC_FULL_IMPL'
**Recommendation: Full team (4 agents).**
- **builder** (`subagent_type: {{BUILDER_AGENT}}`): Implements code changes. Only teammate that writes code.
- **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`): Reviews for hardcoded secrets, insecure storage, missing auth, OWASP vulnerabilities.
- **ux-reviewer** (`subagent_type: {{UX_AGENT}}`): Reviews UI/UX for usability, accessibility, friction. If no UI changes, focuses on API ergonomics.
- **product-manager** (`subagent_type: {{PRODUCT_AGENT}}`): Validates implementation meets requirements. Ensures nothing is over-engineered or under-scoped.

REC_FULL_IMPL
                    ;;
            esac
            ;;
        review)
            case "$complexity" in
                solo) cat <<'REC_SOLO_REVIEW'
**Recommendation: Minimum review team (2 agents).** Even small PRs require a security reviewer — do not review alone.
- **platform-engineer** (`subagent_type: {{BUILDER_AGENT}}`): Reviews code quality, correctness, and tests. Checks all callers of modified functions, including in unmodified files.
- **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`): Reviews for hardcoded secrets, insecure storage, missing auth, OWASP vulnerabilities.

REC_SOLO_REVIEW
                    ;;
                duo) cat <<'REC_DUO_REVIEW'
**Recommendation: Small review team (2 agents).**
- **platform-engineer** (`subagent_type: {{BUILDER_AGENT}}`): Reviews code quality, architecture, patterns, performance, correctness. Must read surrounding source files — not just the diff. Must check all callers of modified functions across the entire codebase, including unmodified files.
- **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`): Reviews for hardcoded secrets, insecure storage, missing auth, OWASP vulnerabilities.

REC_DUO_REVIEW
                    ;;
                full|*) cat <<'REC_FULL_REVIEW'
**Recommendation: Full review team (3 agents). Platform-engineer is REQUIRED — do not go solo on full-complexity PRs.**
- **platform-engineer** (`subagent_type: {{BUILDER_AGENT}}`): Reviews code quality, architecture, patterns, performance, correctness. Must read surrounding source files — not just the diff. Must check all callers of modified functions across the entire codebase, including unmodified files.
- **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`): Reviews for hardcoded secrets, insecure storage, missing auth, OWASP vulnerabilities.
- **ux-reviewer** (`subagent_type: {{UX_AGENT}}`): Reviews UI/UX changes for usability, accessibility, friction, consistency. Skip if no UI files in PR.

REC_FULL_REVIEW
                    ;;
            esac
            ;;
        rework)
            cat <<'REC_REWORK'
**Recommendation: Always spawn at minimum builder + security-reviewer.**
A security reviewer is required after every rework — fixes to blocking issues can introduce new vulnerabilities, and a re-check after pushing is mandatory.

Read the review feedback, then decide on additional roles:
- **Any blocking issues present** → Spawn **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`). Required — not optional.
- **Security concerns mentioned** → Spawn **security-reviewer** (`subagent_type: {{SECURITY_AGENT}}`). Required.
- **Scope/requirements questioned** → Also spawn **product-manager** (`subagent_type: {{PRODUCT_AGENT}}`).
- **Mixed feedback** → Spawn both security-reviewer and product-manager.
- **Style/formatting nits only (no blocking issues)** → Builder works solo, but must run the mandatory security self-check before pushing.

Announce your classification before spawning: "Feedback classification: [blocking-issues|security-concern|scope-question|style-only]. Team: [+security|+security+product|solo-with-checklist]."

REC_REWORK
            ;;
    esac

    # --- Section D: Model Budget Guide ---
    cat <<'MODEL_GUIDE'
## Model Budget Guide

| Agent Role | Default Model | When to Upgrade |
|------------|---------------|-----------------|
| builder | `model: "{{SUBAGENT_MODEL}}"` | Use opus for complex multi-file refactors |
| security-reviewer | `model: "{{SUBAGENT_MODEL}}"` | Use opus for auth/crypto/injection-sensitive code |
| ux-reviewer | `model: "{{SUBAGENT_MODEL}}"` | Rarely needs upgrade |
| product-manager | `model: "{{SUBAGENT_MODEL}}"` | Rarely needs upgrade |

Spawn each teammate using `model: "{{SUBAGENT_MODEL}}"` and `mode: "bypassPermissions"` in the Task tool call unless you have a specific reason to upgrade. The lead agent (you) already runs on the model specified by `CLAUDE_MODEL`.

**CRITICAL**: You MUST pass `mode: "bypassPermissions"` on every Task tool call when spawning teammates. Without this, teammates will get stuck on "Waiting for team lead approval" for every Bash command and the entire job will stall.

MODEL_GUIDE

    # --- Section E: Available Roles ---
    cat <<'ROLES'
## Available Roles

All agent personas available for team composition:
- `{{BUILDER_AGENT}}` — Engineering/implementation (select based on repo type)
- `{{SECURITY_AGENT}}` — Security review
- `{{PRODUCT_AGENT}}` — Product management / requirements validation
- `{{UX_AGENT}}` — UX/accessibility review

ROLES

    # --- Section F: Lead's Authority ---
    cat <<'AUTHORITY'
## Your Authority as Lead

The complexity classification sets the **minimum** team — you may always add agents, never remove required ones. Your authority:
- **Upgrade team size** — Always allowed. If you see auth code in a "solo" PR, spawn a security reviewer.
- **Upgrade model assignments** — Upgrade subagents to opus for security-critical, auth-sensitive, or cryptographic code. The default is sonnet.
- **Skip the UX reviewer only** — The UX reviewer may be skipped if there are genuinely no UI files in the PR (*.tsx, *.jsx, *.swift, *.kt, *.html, *.css, etc.). All other required roles must be spawned.
- **Add agents** — If the task touches compliance-sensitive areas, add a compliance reviewer even if not recommended.

Ground your decisions in the Leadership Principles above. If you lack sufficient information to make a confident decision, add a comment asking for human guidance rather than guessing.
AUTHORITY
}
