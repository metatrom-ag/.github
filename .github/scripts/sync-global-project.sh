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
#   - If not yet in a target project → add it and set Status to Inbox
#   - If already in a target project but has no Status → set Status to Inbox
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
' -f org="$ORG" --paginate -q '.data.organization.repositories.nodes[].name' 2>/dev/null | sort)

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
  --paginate 2>/dev/null)

# Parse into JSON array of all projects
ALL_PROJECTS_JSON=$(echo "$ALL_PROJECTS_RAW" | jq -s '[.[].data.organization.projectsV2.nodes[]]')

# Build associative maps:
#   PROJECT_BY_NAME[title]        → project node ID
#   PROJECT_STATUS_FIELD[proj_id] → status field ID
#   PROJECT_INBOX_OPT[proj_id]    → inbox option ID
declare -A PROJECT_BY_NAME
declare -A PROJECT_STATUS_FIELD
declare -A PROJECT_INBOX_OPT

# Parse each project: only keep Ontocratic ones (have Purpose AND Intention AND Action)
while IFS=$'\t' read -r proj_id proj_num proj_title field_id options_json; do
  [ -z "$proj_id" ] && continue
  [ -z "$field_id" ] && continue

  # Check for Purpose, Intention, Action
  has_purpose=$(echo "$options_json" | jq 'map(.name) | contains(["Purpose"])' 2>/dev/null || echo "false")
  has_intention=$(echo "$options_json" | jq 'map(.name) | contains(["Intention"])' 2>/dev/null || echo "false")
  has_action=$(echo "$options_json" | jq 'map(.name) | contains(["Action"])' 2>/dev/null || echo "false")

  if [ "$has_purpose" != "true" ] || [ "$has_intention" != "true" ] || [ "$has_action" != "true" ]; then
    continue
  fi

  # Find Inbox option ID
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

# --- Step 3: Build "already in project" lookup for all relevant projects ---
# Key: "proj_id:issue_node_id" → project item ID
declare -A IN_PROJECT

ITEMS_QUERY='
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

# Collect unique project numbers to fetch: always Global + any name-matched projects
declare -A PROJ_NUM_TO_ID
PROJ_NUM_TO_ID["$GLOBAL_PROJECT_NUMBER"]="$GLOBAL_PROJECT_ID"

for proj_name in "${!PROJECT_BY_NAME[@]}"; do
  proj_id="${PROJECT_BY_NAME[$proj_name]}"
  proj_num=$(echo "$ALL_PROJECTS_JSON" | jq -r --arg id "$proj_id" '.[] | select(.id == $id) | .number')
  [ -n "$proj_num" ] && PROJ_NUM_TO_ID["$proj_num"]="$proj_id"
done

echo "Fetching existing items from ${#PROJ_NUM_TO_ID[@]} projects..."

NO_STATUS_BY_PROJECT=()  # "proj_id:item_id" pairs needing Inbox

for proj_num in "${!PROJ_NUM_TO_ID[@]}"; do
  proj_id="${PROJ_NUM_TO_ID[$proj_num]}"

  RAW=$(gh api graphql \
    -f query="$ITEMS_QUERY" \
    -f org="$ORG" \
    -F proj="$proj_num" \
    --paginate 2>/dev/null)

  item_count=0

  while IFS=$'\t' read -r item_id issue_id option_id; do
    [ -z "$item_id" ] && continue
    [ -z "$issue_id" ] && continue
    IN_PROJECT["${proj_id}:${issue_id}"]="$item_id"
    item_count=$((item_count + 1))
    if [ -z "$option_id" ] || [ "$option_id" = "null" ]; then
      NO_STATUS_BY_PROJECT+=("${proj_id}:${item_id}")
    fi
  done < <(echo "$RAW" | jq -rs '
    [.[].data.organization.projectV2.items.nodes[] | select(.content.id != null)] |
    .[] | [.id, .content.id, (.fieldValueByName.optionId // "")] | @tsv
  ' 2>/dev/null)

  echo "  Project #$proj_num: $item_count items"
done
echo ""

# --- Step 4: Set Inbox on existing items with no status ---

NO_STATUS_COUNT=${#NO_STATUS_BY_PROJECT[@]}
echo "--- Setting Inbox on $NO_STATUS_COUNT existing items with no status ---"

for entry in "${NO_STATUS_BY_PROJECT[@]}"; do
  proj_id="${entry%%:*}"
  item_id="${entry##*:}"

  if [ "$proj_id" = "$GLOBAL_PROJECT_ID" ]; then
    field_id="$GLOBAL_STATUS_FIELD_ID"
    inbox_opt="$GLOBAL_INBOX_OPTION_ID"
  else
    field_id="${PROJECT_STATUS_FIELD[$proj_id]:-}"
    inbox_opt="${PROJECT_INBOX_OPT[$proj_id]:-}"
  fi

  [ -z "$field_id" ] && continue
  [ -z "$inbox_opt" ] && continue

  if gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$proj_id\"
        itemId: \"$item_id\"
        fieldId: \"$field_id\"
        value: { singleSelectOptionId: \"$inbox_opt\" }
      }) { projectV2Item { id } }
    }" > /dev/null 2>&1; then
    echo "  Set Inbox: $item_id (project $proj_id)"
  fi
done
echo ""

# --- Step 5: For each repo, fetch open issues and add missing ones ---

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

echo "--- Adding missing issues to projects ---"
echo ""

while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  # Build list of target projects for this repo
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

  ISSUE_NODES=$(echo "$ISSUES" | jq -rs '[.[].data.repository.issues.nodes[] | select(.id != null)]' 2>/dev/null || echo "[]")
  ISSUE_COUNT=$(echo "$ISSUE_NODES" | jq 'length')

  [ "$ISSUE_COUNT" -eq 0 ] && continue

  if [ "$has_named_project" = true ]; then
    echo "Repo: $repo ($ISSUE_COUNT open issues → Global + named project)"
  else
    echo "Repo: $repo ($ISSUE_COUNT open issues → Global only)"
  fi

  while IFS= read -r issue; do
    ISSUE_ID=$(echo "$issue" | jq -r '.id')
    ISSUE_NUM=$(echo "$issue" | jq -r '.number')

    for proj_id in "${target_proj_ids[@]}"; do
      lookup_key="${proj_id}:${ISSUE_ID}"
      if [ -n "${IN_PROJECT[$lookup_key]:-}" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi

      ADD_RESULT=$(gh api graphql -f query="
        mutation {
          addProjectV2ItemById(input: {
            projectId: \"$proj_id\"
            contentId: \"$ISSUE_ID\"
          }) { item { id } }
        }" 2>/dev/null || true)

      NEW_ITEM_ID=$(echo "$ADD_RESULT" | jq -r '.data.addProjectV2ItemById.item.id // ""')

      if [ -z "$NEW_ITEM_ID" ]; then
        echo "  ERROR adding #$ISSUE_NUM to $proj_id"
        ERRORS=$((ERRORS + 1))
        continue
      fi

      IN_PROJECT["$lookup_key"]="$NEW_ITEM_ID"

      if [ "$proj_id" = "$GLOBAL_PROJECT_ID" ]; then
        field_id="$GLOBAL_STATUS_FIELD_ID"
        inbox_opt="$GLOBAL_INBOX_OPTION_ID"
      else
        field_id="${PROJECT_STATUS_FIELD[$proj_id]:-}"
        inbox_opt="${PROJECT_INBOX_OPT[$proj_id]:-}"
      fi

      if [ -n "${field_id:-}" ] && [ -n "${inbox_opt:-}" ]; then
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$proj_id\"
              itemId: \"$NEW_ITEM_ID\"
              fieldId: \"$field_id\"
              value: { singleSelectOptionId: \"$inbox_opt\" }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          echo "  Added #$ISSUE_NUM → Inbox ($proj_id)"
          ADDED=$((ADDED + 1))
        else
          echo "  Added #$ISSUE_NUM (status set failed, $proj_id)"
          ADDED=$((ADDED + 1))
        fi
      else
        echo "  Added #$ISSUE_NUM (no status field for $proj_id)"
        ADDED=$((ADDED + 1))
      fi
    done

  done < <(echo "$ISSUE_NODES" | jq -c '.[]')

done <<< "$REPOS"

echo ""
echo "=== Done ==="
echo "Added: $ADDED | Already present: $SKIPPED | Errors: $ERRORS"
