#!/bin/bash
set -euo pipefail

# Sync all open issues from non-archived org repos into the Global project (#6)
# and into any Ontocratic project whose name matches the repo name exactly.
#
# Convention: if a project exists with the same name as a repo (case-sensitive),
# issues from that repo are added to both that project AND Global.
# Projects without Purpose/Intention/Action status options are skipped.
#
# For each issue:
#   - addProjectV2ItemById is idempotent: returns existing item if already present.
#   - If the returned item has no Status → set it to Inbox.
#
# Runs daily (see sync-global-project.yml).

ORG="${ORG:-metatrom-ag}"
GLOBAL_PROJECT_NUMBER=6
GLOBAL_PROJECT_ID="PVT_kwDOClH7Bc4BMpnU"
GLOBAL_STATUS_FIELD_ID="PVTSSF_lADOClH7Bc4BMpnUzg732gA"
GLOBAL_INBOX_OPTION_ID="a42bb87b"

echo "=== Sync Projects by Name Convention ==="
echo "Org: $ORG  Global: #$GLOBAL_PROJECT_NUMBER"
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
' -f org="$ORG" --paginate -q '.data.organization.repositories.nodes[].name' | sort)

REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
echo "Found $REPO_COUNT non-archived repos"
echo ""

# --- Step 2: Fetch all org projects and build name→project map ---
# Only index Ontocratic projects (have Purpose, Intention, AND Action status options).

echo "Fetching org projects..."

ALL_PROJECTS_QUERY='
query($org: String!, $cursor: String) {
  organization(login: $org) {
    projectsV2(first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        number
        title
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
}
'

ALL_PROJECTS_RAW=$(gh api graphql \
  -f query="$ALL_PROJECTS_QUERY" \
  -f org="$ORG" \
  --paginate)

ALL_PROJECTS_JSON=$(echo "$ALL_PROJECTS_RAW" | jq -s '[.[].data.organization.projectsV2.nodes[]]')

# Build associative maps:
#   PROJECT_BY_NAME[title]        → project node ID
#   PROJECT_STATUS_FIELD[proj_id] → status field ID
#   PROJECT_INBOX_OPT[proj_id]    → inbox option ID
declare -A PROJECT_BY_NAME
declare -A PROJECT_STATUS_FIELD
declare -A PROJECT_INBOX_OPT

while IFS=$'\t' read -r proj_id proj_num proj_title field_id options_json; do
  [ -z "$proj_id" ] && continue
  [ -z "$field_id" ] && continue

  has_purpose=$(echo "$options_json" | jq 'map(.name) | contains(["Purpose"])' 2>/dev/null || echo "false")
  has_intention=$(echo "$options_json" | jq 'map(.name) | contains(["Intention"])' 2>/dev/null || echo "false")
  has_action=$(echo "$options_json" | jq 'map(.name) | contains(["Action"])' 2>/dev/null || echo "false")

  if [ "$has_purpose" != "true" ] || [ "$has_intention" != "true" ] || [ "$has_action" != "true" ]; then
    continue
  fi

  inbox_opt=$(echo "$options_json" | jq -r '.[] | select(.name == "Inbox") | .id' 2>/dev/null)
  [ -z "$inbox_opt" ] && continue

  PROJECT_BY_NAME["$proj_title"]="$proj_id"
  PROJECT_STATUS_FIELD["$proj_id"]="$field_id"
  PROJECT_INBOX_OPT["$proj_id"]="$inbox_opt"

  echo "  Ontocratic: #$proj_num \"$proj_title\" (inbox=$inbox_opt)"
done < <(echo "$ALL_PROJECTS_JSON" | jq -r '.[] | [
  .id,
  (.number | tostring),
  .title,
  (if .field then .field.id else "" end),
  (if .field then (.field.options | tostring) else "[]" end)
] | @tsv')

echo ""
echo "Ontocratic projects indexed: ${#PROJECT_BY_NAME[@]}"
echo ""

# --- Step 3: For each repo, add open issues to target projects ---
#
# addProjectV2ItemById is idempotent: if the issue is already in the project it
# returns the existing item — no duplicate is created. The mutation also returns
# the item's current Status, so we can set Inbox in one extra call only when
# needed. This replaces the previous approach of pre-fetching all project items,
# which scaled poorly and caused multi-minute timeouts on large projects.

INBOX_SET=0
ALREADY_TRACKED=0
ERRORS=0

# Mutation returns item ID + current Status in one round trip.
ADD_ITEM_QUERY='
mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: {
    projectId: $projectId
    contentId: $contentId
  }) {
    item {
      id
      fieldValueByName(name: "Status") {
        ... on ProjectV2ItemFieldSingleSelectValue { optionId }
      }
    }
  }
}'

ISSUES_QUERY='
query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    issues(first: 100, after: $cursor, states: [OPEN]) {
      pageInfo { hasNextPage endCursor }
      nodes { id number }
    }
  }
}'

echo "--- Syncing issues to projects ---"
echo ""

while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  # Determine target projects for this repo
  target_proj_ids=("$GLOBAL_PROJECT_ID")
  has_named_project=false
  if [[ -v "PROJECT_BY_NAME[$repo]" ]]; then
    named_proj_id="${PROJECT_BY_NAME[$repo]}"
    if [ "$named_proj_id" != "$GLOBAL_PROJECT_ID" ]; then
      target_proj_ids+=("$named_proj_id")
      has_named_project=true
    fi
  fi

  ISSUES=$(gh api graphql \
    -f query="$ISSUES_QUERY" \
    -f owner="$ORG" \
    -f repo="$repo" \
    --paginate 2>/dev/null || true)

  [ -z "$ISSUES" ] && continue

  ISSUE_NODES=$(echo "$ISSUES" | \
    jq -rs '[.[].data.repository.issues.nodes[] | select(.id != null)]' 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUE_NODES" | jq 'length')
  [ "$ISSUE_COUNT" -eq 0 ] && continue

  if [ "$has_named_project" = true ]; then
    echo "Repo: $repo ($ISSUE_COUNT open issues → Global + named project)"
  else
    echo "Repo: $repo ($ISSUE_COUNT open issues → Global only)"
  fi

  while IFS=$'\t' read -r issue_id issue_num; do
    for proj_id in "${target_proj_ids[@]}"; do

      # Add item (idempotent) — also retrieves current Status in the same call
      ADD_RESULT=$(gh api graphql \
        -f query="$ADD_ITEM_QUERY" \
        -f projectId="$proj_id" \
        -f contentId="$issue_id" 2>/dev/null || echo '{}')

      ITEM_ID=$(echo "$ADD_RESULT" | jq -r '.data.addProjectV2ItemById.item.id // ""')

      if [ -z "$ITEM_ID" ]; then
        echo "  ERROR: could not add #$issue_num to project $proj_id"
        ERRORS=$((ERRORS + 1))
        continue
      fi

      CURRENT_OPTION=$(echo "$ADD_RESULT" | \
        jq -r '.data.addProjectV2ItemById.item.fieldValueByName.optionId // ""')

      # Status already set — nothing to do
      if [ -n "$CURRENT_OPTION" ]; then
        ALREADY_TRACKED=$((ALREADY_TRACKED + 1))
        continue
      fi

      # No status — set Inbox
      if [ "$proj_id" = "$GLOBAL_PROJECT_ID" ]; then
        field_id="$GLOBAL_STATUS_FIELD_ID"
        inbox_opt="$GLOBAL_INBOX_OPTION_ID"
      else
        field_id="${PROJECT_STATUS_FIELD[$proj_id]:-}"
        inbox_opt="${PROJECT_INBOX_OPT[$proj_id]:-}"
      fi

      if [ -z "$field_id" ] || [ -z "$inbox_opt" ]; then
        echo "  #$issue_num: no status field configured for $proj_id"
        continue
      fi

      if gh api graphql -f query="
        mutation {
          updateProjectV2ItemFieldValue(input: {
            projectId: \"$proj_id\"
            itemId: \"$ITEM_ID\"
            fieldId: \"$field_id\"
            value: { singleSelectOptionId: \"$inbox_opt\" }
          }) { projectV2Item { id } }
        }" > /dev/null 2>&1; then
        echo "  #$issue_num → Inbox"
        INBOX_SET=$((INBOX_SET + 1))
      else
        echo "  #$issue_num: added but failed to set Inbox ($proj_id)"
        ERRORS=$((ERRORS + 1))
      fi

    done
  done < <(echo "$ISSUE_NODES" | jq -r '.[] | [.id, (.number | tostring)] | @tsv')

done <<< "$REPOS"

echo ""
echo "=== Done ==="
echo "Inbox set: $INBOX_SET | Already tracked: $ALREADY_TRACKED | Errors: $ERRORS"
