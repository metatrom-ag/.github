#!/bin/bash
set -euo pipefail

# Sync Project Status (Polling)
# ==============================
# Scans org projects for issues that exist in multiple Ontocratic projects
# with mismatched Status values. When a mismatch is found, the most
# recently updated value wins and gets synced to all other projects.
#
# Template detection: Only syncs between projects whose Status field
# contains the core Ontocratic statuses (Purpose, Intention, Action).
# Projects without these statuses are ignored entirely.

ORG="${ORG:-metatrom-ag}"

# Core Ontocratic statuses that identify a template-compatible project.
# A project must have ALL of these to participate in sync.
REQUIRED_STATUSES=("Purpose" "Intention" "Action")

echo "=== Sync Project Status ==="
echo "Org: $ORG"
echo ""

# --- Step 1: Get all org projects with their Status field options ---

PROJECTS_QUERY='
query($org: String!) {
  organization(login: $org) {
    projectsV2(first: 20) {
      nodes {
        id
        title
        number
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            options { name }
          }
        }
        items(first: 100) {
          nodes {
            id
            updatedAt
            content {
              __typename
              ... on Issue { id title number }
              ... on PullRequest { id title number }
            }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                updatedAt
              }
            }
          }
        }
      }
    }
  }
}
'

echo "Fetching all projects and items..."
PROJECTS_DATA=$(gh api graphql -f query="$PROJECTS_QUERY" -f org="$ORG")

# --- Step 2: Filter to Ontocratic template-compatible projects ---

# Build a jq filter for required statuses
REQUIRED_JQ=$(printf '"%s",' "${REQUIRED_STATUSES[@]}")
REQUIRED_JQ="[${REQUIRED_JQ%,}]"

ELIGIBLE_PROJECTS=$(echo "$PROJECTS_DATA" | jq --argjson req "$REQUIRED_JQ" '
  [.data.organization.projectsV2.nodes[] |
    . as $proj |
    ($proj.field.options // [] | map(.name)) as $opts |
    # Check all required statuses exist in this project
    if ($req | all(. as $r | $opts | any(. == $r))) then
      { id: $proj.id, title: $proj.title, number: $proj.number }
    else empty end
  ]
')

ELIGIBLE_COUNT=$(echo "$ELIGIBLE_PROJECTS" | jq 'length')
ELIGIBLE_IDS=$(echo "$ELIGIBLE_PROJECTS" | jq '[.[].id]')
echo "Found $ELIGIBLE_COUNT Ontocratic template-compatible projects:"
echo "$ELIGIBLE_PROJECTS" | jq -r '.[] | "  #\(.number) \(.title)"'
echo ""

if [ "$ELIGIBLE_COUNT" -lt 2 ]; then
  echo "Need at least 2 eligible projects to sync. Nothing to do."
  exit 0
fi

# --- Step 3: Extract items only from eligible projects ---

ITEMS_JSON=$(echo "$PROJECTS_DATA" | jq --argjson eligible "$ELIGIBLE_IDS" '
  [.data.organization.projectsV2.nodes[] |
    select(.id as $pid | $eligible | any(. == $pid)) |
    .id as $pid | .title as $ptitle | .number as $pnum |
    .items.nodes[] |
    select(.content.__typename == "Issue" or .content.__typename == "PullRequest") |
    select(.content.id != null) |
    {
      content_id: .content.id,
      content_title: .content.title,
      project_id: $pid,
      project_title: $ptitle,
      project_number: $pnum,
      item_id: .id,
      status: (.fieldValueByName.name // null),
      updated_at: (.fieldValueByName.updatedAt // .updatedAt)
    }
  ]
')

# --- Diagnostic: item counts per project ---
TOTAL_ITEMS=$(echo "$ITEMS_JSON" | jq 'length')
echo "Extracted $TOTAL_ITEMS items across eligible projects:"
echo "$ITEMS_JSON" | jq -r 'group_by(.project_number) | .[] | "  #\(.[0].project_number) \(.[0].project_title): \(length) items"'
if [ "$TOTAL_ITEMS" = "0" ]; then
  echo ""
  echo "WARNING: Zero items extracted. The PAT likely lacks repository-level"
  echo "read access (Issues: Read, Pull requests: Read) needed to resolve"
  echo "issue/PR content inside project items."
  exit 0
fi
echo ""

# Group by content_id and find items in multiple eligible projects
MULTI_PROJECT=$(echo "$ITEMS_JSON" | jq '
  group_by(.content_id) |
  map(select(length > 1)) |
  map({
    content_id: .[0].content_id,
    content_title: .[0].content_title,
    items: .
  }) |
  # Only keep groups where statuses differ
  map(
    .items as $items |
    ($items | map(.status) | unique) as $statuses |
    select(($statuses | length) > 1 or ($statuses | any(. == null)))
  )
')

# --- Diagnostic: multi-project group count ---
SHARED_COUNT=$(echo "$ITEMS_JSON" | jq 'group_by(.content_id) | map(select(length > 1)) | length')
MISMATCH_COUNT=$(echo "$MULTI_PROJECT" | jq 'length')
echo "Found $SHARED_COUNT issues shared across projects, $MISMATCH_COUNT with mismatched statuses"
echo ""

if [ "$MISMATCH_COUNT" = "0" ]; then
  echo "All in sync. Nothing to do."
  exit 0
fi

# --- Step 4: For each mismatch, sync to the most recently updated status ---

# Use temp file for counters (avoids subshell pipe problem)
COUNTER_FILE=$(mktemp)
echo "0 0 0" > "$COUNTER_FILE"

while IFS= read -r group; do
  TITLE=$(echo "$group" | jq -r '.content_title')

  # Find the most recently updated status (the "winner")
  WINNER=$(echo "$group" | jq -r '
    [.items[] | select(.status != null)] |
    sort_by(.updated_at) |
    last
  ')

  if [ "$WINNER" = "null" ] || [ -z "$WINNER" ]; then
    echo "Issue: $TITLE"
    echo "  No item has a status set, skipping"
    echo ""
    continue
  fi

  WINNER_STATUS=$(echo "$WINNER" | jq -r '.status')
  WINNER_PROJECT=$(echo "$WINNER" | jq -r '.project_title')

  echo "Issue: $TITLE"
  echo "  Winner: '$WINNER_STATUS' (from $WINNER_PROJECT)"

  while IFS= read -r item; do
    ITEM_ID=$(echo "$item" | jq -r '.item_id')
    PROJECT_ID=$(echo "$item" | jq -r '.project_id')
    PROJECT_TITLE=$(echo "$item" | jq -r '.project_title')
    CURRENT_STATUS=$(echo "$item" | jq -r '.status // empty')

    # Skip if already matches
    if [ "$CURRENT_STATUS" = "$WINNER_STATUS" ]; then
      continue
    fi

    # Get the Status field and option ID for the target project
    TARGET_FIELD=$(gh api graphql -f query="
      { node(id: \"$PROJECT_ID\") {
          ... on ProjectV2 {
            field(name: \"Status\") {
              ... on ProjectV2SingleSelectField {
                id
                options { id name }
              }
            }
          }
        }
      }" 2>/dev/null || echo '{}')

    TARGET_FIELD_ID=$(echo "$TARGET_FIELD" | jq -r '.data.node.field.id // empty')
    TARGET_OPTION_ID=$(echo "$TARGET_FIELD" | jq -r --arg s "$WINNER_STATUS" \
      '.data.node.field.options[] | select(.name == $s) | .id' 2>/dev/null || echo "")

    if [ -z "$TARGET_FIELD_ID" ] || [ -z "$TARGET_OPTION_ID" ]; then
      echo "  [$PROJECT_TITLE] '$WINNER_STATUS' not available, skipping"
      read -r s sk e < "$COUNTER_FILE"; echo "$s $((sk + 1)) $e" > "$COUNTER_FILE"
      continue
    fi

    # Update the status
    if gh api graphql -f query="
      mutation {
        updateProjectV2ItemFieldValue(input: {
          projectId: \"$PROJECT_ID\"
          itemId: \"$ITEM_ID\"
          fieldId: \"$TARGET_FIELD_ID\"
          value: { singleSelectOptionId: \"$TARGET_OPTION_ID\" }
        }) { projectV2Item { id } }
      }" > /dev/null 2>&1; then
      echo "  [$PROJECT_TITLE] '${CURRENT_STATUS:-none}' -> '$WINNER_STATUS'"
      read -r s sk e < "$COUNTER_FILE"; echo "$((s + 1)) $sk $e" > "$COUNTER_FILE"
    else
      echo "  [$PROJECT_TITLE] FAILED to update"
      read -r s sk e < "$COUNTER_FILE"; echo "$s $sk $((e + 1))" > "$COUNTER_FILE"
    fi
  done < <(echo "$group" | jq -c '.items[]')

  echo ""
done < <(echo "$MULTI_PROJECT" | jq -c '.[]')

read -r SYNCED SKIPPED ERRORS < "$COUNTER_FILE"
rm -f "$COUNTER_FILE"

echo "=== Done ==="
echo "Synced: $SYNCED | Skipped: $SKIPPED | Errors: $ERRORS"
