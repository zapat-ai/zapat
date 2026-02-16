#!/usr/bin/env bash
# Zapat — GitHub Project V2 Setup
# Creates the project, custom fields, and views.
#
# Prerequisites:
#   gh auth refresh -s read:project,project
#
# Usage:
#   ./setup-project.sh              # Create project + fields + views
#   ./setup-project.sh --dry-run    # Preview commands without executing

set -euo pipefail

ORG="${GITHUB_ORG:-your-org}"
PROJECT_TITLE="${PROJECT_TITLE:-My Project}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE ==="
    echo ""
fi

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] $*"
    else
        echo "[exec] $*"
        eval "$@"
    fi
}

echo "=== Step 0.2: Create GitHub Project V2 ==="
echo ""

# Create the project
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] gh project create --title \"$PROJECT_TITLE\" --owner $ORG --format json"
    PROJECT_NUMBER="1"
else
    # Check if project already exists
    EXISTING=$(gh project list --owner "$ORG" --format json 2>/dev/null | \
        python3 -c "import json,sys; projects = json.loads(sys.stdin.read()).get('projects',[]); matches = [p for p in projects if p.get('title') == '$PROJECT_TITLE']; print(matches[0]['number'] if matches else '')" 2>/dev/null || echo "")

    if [[ -n "$EXISTING" ]]; then
        echo "Project '$PROJECT_TITLE' already exists (number: $EXISTING)"
        PROJECT_NUMBER="$EXISTING"
    else
        PROJECT_JSON=$(gh project create --title "$PROJECT_TITLE" --owner "$ORG" --format json)
        PROJECT_NUMBER=$(echo "$PROJECT_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['number'])")
        echo "Created project #$PROJECT_NUMBER: $PROJECT_TITLE"
    fi
fi

echo ""
echo "Project number: $PROJECT_NUMBER"
echo ""

# --- Custom Fields ---
echo "=== Adding custom fields ==="
echo ""

# Priority field (Single select)
run_cmd "gh project field-create $PROJECT_NUMBER --owner $ORG \
    --name Priority --data-type SINGLE_SELECT \
    --single-select-options 'P0-Critical,P1-High,P2-Medium,P3-Low'"

# Sprint field (Single select)
run_cmd "gh project field-create $PROJECT_NUMBER --owner $ORG \
    --name Sprint --data-type SINGLE_SELECT \
    --single-select-options 'Sprint 1,Sprint 2,Sprint 3,Sprint 4,Sprint 5,Sprint 6'"

# Category field (Single select)
run_cmd "gh project field-create $PROJECT_NUMBER --owner $ORG \
    --name Category --data-type SINGLE_SELECT \
    --single-select-options 'Feature,Bug,Tech-Debt,Security,Infrastructure,Analytics'"

# Platform field (Single select)
run_cmd "gh project field-create $PROJECT_NUMBER --owner $ORG \
    --name Platform --data-type SINGLE_SELECT \
    --single-select-options 'Frontend,Backend,Mobile,Extension,Cross-Platform'"

echo ""
echo "=== Step 0.3: Create project views ==="
echo ""

# Note: gh project view-create is not available in all gh versions.
# Views may need to be created via the GitHub web UI or GraphQL API.
# The commands below use the GraphQL API approach.

create_view() {
    local name="$1"
    local layout="$2"  # BOARD_LAYOUT or TABLE_LAYOUT
    local filter="${3:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] Create view: $name (layout=$layout, filter=$filter)"
    else
        # Use GraphQL to create views
        local project_id
        project_id=$(gh project view "$PROJECT_NUMBER" --owner "$ORG" --format json 2>/dev/null | \
            python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])" 2>/dev/null || echo "")

        if [[ -z "$project_id" ]]; then
            echo "Warning: Could not get project ID for view creation. Create views manually."
            return
        fi

        # Create view via GraphQL
        gh api graphql -f query="
            mutation {
                createProjectV2View(input: {
                    projectId: \"$project_id\"
                    name: \"$name\"
                    layout: $layout
                }) {
                    projectV2View {
                        id
                        name
                    }
                }
            }
        " 2>/dev/null && echo "Created view: $name" || echo "Warning: Could not create view '$name' (may need manual setup)"
    fi
}

create_view "Sprint Board" "BOARD_LAYOUT"
create_view "Frontend Roadmap" "TABLE_LAYOUT"
create_view "Backend Roadmap" "TABLE_LAYOUT"
create_view "Mobile Roadmap" "TABLE_LAYOUT"
create_view "Agent Queue" "TABLE_LAYOUT"
create_view "Feature Map" "TABLE_LAYOUT"
create_view "Priority View" "BOARD_LAYOUT"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Project: $PROJECT_TITLE (#$PROJECT_NUMBER)"
echo "Custom fields: Priority, Sprint, Category, Platform"
echo "Views: 7 created"
echo ""
echo "Note: View filters and grouping must be configured in the GitHub web UI."
echo "Suggested filters:"
echo "  Sprint Board:      Group by Status, Filter by Sprint = current"
echo "  Frontend Roadmap:  Group by Sprint, Filter by Platform = Frontend"
echo "  Backend Roadmap:   Group by Sprint, Filter by Platform = Backend"
echo "  Mobile Roadmap:    Group by Sprint, Filter by Platform = Mobile"
echo "  Agent Queue:       Filter by Label = agent"
echo "  Feature Map:       Group by Category"
echo "  Priority View:     Group by Priority, Filter by Status != Done"
echo ""
