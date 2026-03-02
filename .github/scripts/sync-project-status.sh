#!/bin/bash
set -euo pipefail

# Sync Project Status
# ====================
# When the Status field changes on a project item, this script finds all
# other projects that contain the same issue and updates their Status to match.
#
# Loop prevention: skips if target already has the same status.
# Only syncs the "Status" field — other fields are left alone.

# --- Validate inputs ---

if [ -z "${CONTENT_NODE_ID:-}" ]; then
  echo "No content node ID (draft issue?), skipping"
  exit 0
fi

if [ -z "${FIELD_NODE_ID:-}" ]; then
  echo "No field node ID, skipping"
  exit 0
fi

# --- Check if the changed field is "Status" ---

FIELD_NAME=$(gh api graphql -f query='
  query($fieldId: ID!) {
    node(id: $fieldId) {
      ... on ProjectV2SingleSelectField {
        name
      }
    }
  }
' -f fieldId="$FIELD_NODE_ID" --jq '.data.node.name // empty')

if [ "$FIELD_NAME" != "Status" ]; then
  echo "Field changed: '${FIELD_NAME:-unknown}' (not Status), skipping"
  exit 0
fi

echo "Status field changed, syncing..."

# --- Get current status from source project item ---

STATUS_NAME=$(gh api graphql -f query='
  query($itemId: ID!) {
    node(id: $itemId) {
      ... on ProjectV2Item {
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue {
            name
          }
        }
      }
    }
  }
' -f itemId="$ITEM_NODE_ID" --jq '.data.node.fieldValueByName.name // empty')

if [ -z "$STATUS_NAME" ]; then
  echo "Could not read status value, skipping"
  exit 0
fi

echo "New status: $STATUS_NAME"

# --- Find all projects this issue/PR belongs to ---

CONTENT_TYPE_QUERY='
  query($contentId: ID!) {
    node(id: $contentId) {
      __typename
      ... on Issue {
        title
        projectItems(first: 20) {
          nodes {
            id
            project {
              id
              title
            }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
              }
            }
          }
        }
      }
      ... on PullRequest {
        title
        projectItems(first: 20) {
          nodes {
            id
            project {
              id
              title
            }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
              }
            }
          }
        }
      }
    }
  }
'

CONTENT_DATA=$(gh api graphql -f query="$CONTENT_TYPE_QUERY" -f contentId="$CONTENT_NODE_ID")

CONTENT_TITLE=$(echo "$CONTENT_DATA" | jq -r '.data.node.title // "unknown"')
echo "Issue: $CONTENT_TITLE"

# --- Sync to each other project ---

ITEMS=$(echo "$CONTENT_DATA" | jq -c '.data.node.projectItems.nodes[]')
SYNCED=0
SKIPPED=0

echo "$ITEMS" | while IFS= read -r item; do
  item_id=$(echo "$item" | jq -r '.id')
  project_id=$(echo "$item" | jq -r '.project.id')
  project_title=$(echo "$item" | jq -r '.project.title')
  current_status=$(echo "$item" | jq -r '.fieldValueByName.name // empty')

  # Skip source project
  if [ "$project_id" = "$PROJECT_NODE_ID" ]; then
    echo "  [$project_title] source project, skipping"
    continue
  fi

  # Skip if already in sync (prevents loops)
  if [ "$current_status" = "$STATUS_NAME" ]; then
    echo "  [$project_title] already '$STATUS_NAME', skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  [$project_title] '$current_status' -> '$STATUS_NAME'"

  # Get the Status field ID and matching option ID for target project
  TARGET_FIELD=$(gh api graphql -f query='
    query($projectId: ID!) {
      node(id: $projectId) {
        ... on ProjectV2 {
          field(name: "Status") {
            ... on ProjectV2SingleSelectField {
              id
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  ' -f projectId="$project_id")

  TARGET_FIELD_ID=$(echo "$TARGET_FIELD" | jq -r '.data.node.field.id // empty')
  TARGET_OPTION_ID=$(echo "$TARGET_FIELD" | jq -r --arg status "$STATUS_NAME" '.data.node.field.options[] | select(.name == $status) | .id // empty')

  if [ -z "$TARGET_FIELD_ID" ] || [ -z "$TARGET_OPTION_ID" ]; then
    echo "  [$project_title] status '$STATUS_NAME' not found in this project, skipping"
    continue
  fi

  # Update the status
  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: { singleSelectOptionId: $optionId }
      }) {
        projectV2Item {
          id
        }
      }
    }
  ' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$TARGET_FIELD_ID" -f optionId="$TARGET_OPTION_ID" > /dev/null

  echo "  [$project_title] updated successfully"
  SYNCED=$((SYNCED + 1))
done

echo "Done. Synced: $SYNCED, Skipped: $SKIPPED"
