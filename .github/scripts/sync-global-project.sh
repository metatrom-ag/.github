#!/bin/bash
set -euo pipefail

# Sync all open issues from non-archived org repos into the Global project (#6).
#
# For each open issue across the org:
#   - If not yet in the Global project → add it and set Status to Inbox
#   - If already in Global project but has no Status → set Status to Inbox
#
# Runs daily (see sync-global-project.yml).

ORG="${ORG:-metatrom-ag}"
GLOBAL_PROJECT_NUMBER=6
GLOBAL_PROJECT_ID="PVT_kwDOClH7Bc4BMpnU"
STATUS_FIELD_ID="PVTSSF_lADOClH7Bc4BMpnUzg732gA"
INBOX_OPTION_ID="a42bb87b"

echo "=== Sync Global Project ==="
echo "Org: $ORG  Project: #$GLOBAL_PROJECT_NUMBER"
echo ""

# --- Step 1: Fetch all non-archived org repos ---

echo "Fetching non-archived repos..."
REPOS=$(gh api graphql -f query='
  query($org: String!, $cursor: String) {
    organization(login: $org) {
      repositories(first: 100, after: $cursor, isArchived: false) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
    }
  }
' -f org="$ORG" --paginate -q '.data.organization.repositories.nodes[].name' 2>/dev/null | sort)

REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
echo "Found $REPO_COUNT non-archived repos"
echo ""

# --- Step 2: Fetch all items currently in Global project (issue node IDs + status) ---

echo "Fetching current Global project items..."

GLOBAL_ITEMS_QUERY='
query($proj: Int!, $org: String!, $cursor: String) {
  organization(login: $org) {
    projectV2(number: $proj) {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { optionId }
          }
          content {
            ... on Issue { id }
          }
        }
      }
    }
  }
}
'

GLOBAL_ITEMS=$(gh api graphql \
  -f query="$GLOBAL_ITEMS_QUERY" \
  -f org="$ORG" \
  -F proj="$GLOBAL_PROJECT_NUMBER" \
  --paginate 2>/dev/null)

# Build lookup: issue_node_id → project_item_id (for all items already in global project)
# Also collect item IDs with no status set
IN_GLOBAL_JSON=$(echo "$GLOBAL_ITEMS" | jq -s '
  [.[].data.organization.projectV2.items.nodes[] | select(.content.id != null)] |
  map({ key: .content.id, value: { itemId: .id, optionId: (.fieldValueByName.optionId // "") } }) |
  from_entries
')

echo "Items already in Global project: $(echo "$IN_GLOBAL_JSON" | jq 'length')"
echo ""

# --- Step 3: Set Inbox on existing items with no status ---

NO_STATUS_ITEMS=$(echo "$GLOBAL_ITEMS" | jq -rs '
  [.[].data.organization.projectV2.items.nodes[] |
    select(.content.id != null) |
    select(.fieldValueByName.optionId == null or .fieldValueByName == null) |
    .id
  ][]
' 2>/dev/null || true)

NO_STATUS_COUNT=$(echo "$NO_STATUS_ITEMS" | grep -c . 2>/dev/null || echo 0)
echo "--- Setting Inbox on $NO_STATUS_COUNT existing items with no status ---"

while IFS= read -r item_id; do
  [ -z "$item_id" ] && continue
  if gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$GLOBAL_PROJECT_ID\"
        itemId: \"$item_id\"
        fieldId: \"$STATUS_FIELD_ID\"
        value: { singleSelectOptionId: \"$INBOX_OPTION_ID\" }
      }) { projectV2Item { id } }
    }" > /dev/null 2>&1; then
    echo "  Set Inbox: $item_id"
  fi
done <<< "$NO_STATUS_ITEMS"
echo ""

# --- Step 4: For each repo, fetch open issues and add missing ones to Global project ---

ADDED=0
SKIPPED=0
ERRORS=0

ISSUES_QUERY='
query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    issues(first: 100, after: $cursor, states: [OPEN]) {
      pageInfo { hasNextPage endCursor }
      nodes { id number title }
    }
  }
}
'

echo "--- Adding missing issues to Global project ---"
echo ""

while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  ISSUES=$(gh api graphql \
    -f query="$ISSUES_QUERY" \
    -f owner="$ORG" \
    -f repo="$repo" \
    --paginate 2>/dev/null || true)

  [ -z "$ISSUES" ] && continue

  ISSUE_NODES=$(echo "$ISSUES" | jq -rs '[.[].data.repository.issues.nodes[] | select(.id != null)]' 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUE_NODES" | jq 'length')

  [ "$ISSUE_COUNT" -eq 0 ] && continue

  echo "Repo: $repo ($ISSUE_COUNT open issues)"

  while IFS= read -r issue; do
    ISSUE_ID=$(echo "$issue" | jq -r '.id')
    ISSUE_NUM=$(echo "$issue" | jq -r '.number')

    # Check if already in Global project
    ALREADY_IN=$(echo "$IN_GLOBAL_JSON" | jq -r --arg id "$ISSUE_ID" '.[$id].itemId // ""')
    if [ -n "$ALREADY_IN" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Add to Global project
    ADD_RESULT=$(gh api graphql -f query="
      mutation {
        addProjectV2ItemById(input: {
          projectId: \"$GLOBAL_PROJECT_ID\"
          contentId: \"$ISSUE_ID\"
        }) { item { id } }
      }" 2>/dev/null || true)

    NEW_ITEM_ID=$(echo "$ADD_RESULT" | jq -r '.data.addProjectV2ItemById.item.id // ""')

    if [ -z "$NEW_ITEM_ID" ]; then
      echo "  ERROR adding #$ISSUE_NUM"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Set Status to Inbox
    if gh api graphql -f query="
      mutation {
        updateProjectV2ItemFieldValue(input: {
          projectId: \"$GLOBAL_PROJECT_ID\"
          itemId: \"$NEW_ITEM_ID\"
          fieldId: \"$STATUS_FIELD_ID\"
          value: { singleSelectOptionId: \"$INBOX_OPTION_ID\" }
        }) { projectV2Item { id } }
      }" > /dev/null 2>&1; then
      echo "  Added #$ISSUE_NUM → Inbox"
      ADDED=$((ADDED + 1))
    else
      echo "  Added #$ISSUE_NUM (status set failed)"
      ADDED=$((ADDED + 1))
    fi

  done < <(echo "$ISSUE_NODES" | jq -c '.[]')

done <<< "$REPOS"

echo ""
echo "=== Done ==="
echo "Added: $ADDED | Already present: $SKIPPED | Errors: $ERRORS"
