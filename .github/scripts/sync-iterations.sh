#!/bin/bash
set -euo pipefail

# Sync Iteration and Quarter field values from Global (#6) to all Ontocratic
# repo-specific projects (matched by name convention).
#
# For each item in Global that has an Iteration or Quarter set:
#   - Find the same issue in the matching repo project
#   - Look up the iteration by title in that project's field
#   - Set it if not already matching
#
# Title matching is used (not ID) so iterations must have identical titles
# across all projects.

ORG="${ORG:-metatrom-ag}"
GLOBAL_PROJECT_NUMBER=6
GLOBAL_PROJECT_ID="PVT_kwDOClH7Bc4BMpnU"

echo "=== Sync Iterations & Quarters from Global to Repo Projects ==="
echo "Org: $ORG  Global: #$GLOBAL_PROJECT_NUMBER"
echo ""

# --- Step 1: Fetch all Ontocratic projects with Iteration + Quarter fields ---

echo "Fetching org projects and iteration fields..."

ALL_PROJECTS_RAW=$(gh api graphql -f query='
query($org: String!, $cursor: String) {
  organization(login: $org) {
    projectsV2(first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        number
        title
        fields(first: 30) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
            ... on ProjectV2IterationField {
              id
              name
              configuration {
                iterations { id title }
              }
            }
          }
        }
      }
    }
  }
}
' -f org="$ORG" --paginate 2>/dev/null)

ALL_PROJECTS_JSON=$(echo "$ALL_PROJECTS_RAW" | jq -s '[.[].data.organization.projectsV2.nodes[]]')

# Build maps per project:
#   PROJECT_BY_NAME[title]           → project node ID
#   ITER_FIELD_ID[proj_id]           → Iteration field ID
#   QUARTER_FIELD_ID[proj_id]        → Quarter field ID
#   ITER_TITLE_TO_ID[proj_id:title]  → iteration ID in that project
#   QUARTER_TITLE_TO_ID[proj_id:title] → quarter ID in that project

declare -A PROJECT_BY_NAME
declare -A ITER_FIELD_ID
declare -A QUARTER_FIELD_ID
declare -A ITER_TITLE_TO_ID
declare -A QUARTER_TITLE_TO_ID

while IFS=$'\t' read -r proj_id proj_num proj_title status_options_json; do
  [ -z "$proj_id" ] && continue

  # Only Ontocratic projects (have Purpose, Intention, Action)
  has_purpose=$(echo "$status_options_json" | jq 'map(.name) | contains(["Purpose"])' 2>/dev/null || echo "false")
  has_intention=$(echo "$status_options_json" | jq 'map(.name) | contains(["Intention"])' 2>/dev/null || echo "false")
  has_action=$(echo "$status_options_json" | jq 'map(.name) | contains(["Action"])' 2>/dev/null || echo "false")

  if [ "$has_purpose" != "true" ] || [ "$has_intention" != "true" ] || [ "$has_action" != "true" ]; then
    continue
  fi

  PROJECT_BY_NAME["$proj_title"]="$proj_id"

done < <(echo "$ALL_PROJECTS_JSON" | jq -r '.[] | [
  .id,
  (.number | tostring),
  .title,
  ([ .fields.nodes[] | select(.options != null) | select(.name == "Status") | .options ] | first // [] | tostring)
] | @tsv')

# Now extract Iteration and Quarter fields for each known Ontocratic project
for proj_title in "${!PROJECT_BY_NAME[@]}"; do
  proj_id="${PROJECT_BY_NAME[$proj_title]}"

  # Iteration field
  iter_data=$(echo "$ALL_PROJECTS_JSON" | jq -r --arg id "$proj_id" '
    .[] | select(.id == $id) |
    .fields.nodes[] |
    select(.name == "Iteration" and .configuration != null) |
    [.id, (.configuration.iterations[] | .id + "|||" + .title)] |
    @tsv
  ' 2>/dev/null || true)

  if [ -n "$iter_data" ]; then
    field_id=$(echo "$iter_data" | head -1 | cut -f1)
    ITER_FIELD_ID["$proj_id"]="$field_id"
    while IFS=$'\t' read -r fid entry; do
      iter_id="${entry%%|||*}"
      iter_title="${entry##*|||}"
      ITER_TITLE_TO_ID["${proj_id}:${iter_title}"]="$iter_id"
    done <<< "$iter_data"
  fi

  # Quarter field
  quarter_data=$(echo "$ALL_PROJECTS_JSON" | jq -r --arg id "$proj_id" '
    .[] | select(.id == $id) |
    .fields.nodes[] |
    select(.name == "Quarter" and .configuration != null) |
    [.id, (.configuration.iterations[] | .id + "|||" + .title)] |
    @tsv
  ' 2>/dev/null || true)

  if [ -n "$quarter_data" ]; then
    field_id=$(echo "$quarter_data" | head -1 | cut -f1)
    QUARTER_FIELD_ID["$proj_id"]="$field_id"
    while IFS=$'\t' read -r fid entry; do
      qid="${entry%%|||*}"
      qtitle="${entry##*|||}"
      QUARTER_TITLE_TO_ID["${proj_id}:${qtitle}"]="$qid"
    done <<< "$quarter_data"
  fi

done

echo "Ontocratic projects with iteration fields:"
for proj_title in "${!PROJECT_BY_NAME[@]}"; do
  proj_id="${PROJECT_BY_NAME[$proj_title]}"
  has_iter="${ITER_FIELD_ID[$proj_id]:+yes}"
  has_quarter="${QUARTER_FIELD_ID[$proj_id]:+yes}"
  echo "  \"$proj_title\" iter=${has_iter:-no} quarter=${has_quarter:-no}"
done
echo ""

# --- Step 2: Fetch all items from Global with their Iteration + Quarter values ---

echo "Fetching Global project items..."

GLOBAL_ITEMS_RAW=$(gh api graphql -f query='
query($org: String!, $proj: Int!, $cursor: String) {
  organization(login: $org) {
    projectV2(number: $proj) {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content { ... on Issue { id } }
          iteration: fieldValueByName(name: "Iteration") {
            ... on ProjectV2ItemFieldIterationValue { title iterationId }
          }
          quarter: fieldValueByName(name: "Quarter") {
            ... on ProjectV2ItemFieldIterationValue { title iterationId }
          }
        }
      }
    }
  }
}
' -f org="$ORG" -F proj="$GLOBAL_PROJECT_NUMBER" --paginate 2>/dev/null)

# Parse: issue_id → iter_title, quarter_title
declare -A GLOBAL_ITER_TITLE    # issue_node_id → iteration title
declare -A GLOBAL_QUARTER_TITLE # issue_node_id → quarter title

while IFS=$'\t' read -r issue_id iter_title quarter_title; do
  [ -z "$issue_id" ] && continue
  [ "$issue_id" = "null" ] && continue
  [ -n "$iter_title" ] && [ "$iter_title" != "null" ] && GLOBAL_ITER_TITLE["$issue_id"]="$iter_title"
  [ -n "$quarter_title" ] && [ "$quarter_title" != "null" ] && GLOBAL_QUARTER_TITLE["$issue_id"]="$quarter_title"
done < <(echo "$GLOBAL_ITEMS_RAW" | jq -rs '
  [.[].data.organization.projectV2.items.nodes[] | select(.content.id != null)] |
  .[] | [
    .content.id,
    (.iteration.title // ""),
    (.quarter.title // "")
  ] | @tsv
' 2>/dev/null)

echo "Global items with Iteration set: $(echo "${!GLOBAL_ITER_TITLE[@]}" | wc -w | tr -d ' ')"
echo "Global items with Quarter set:   $(echo "${!GLOBAL_QUARTER_TITLE[@]}" | wc -w | tr -d ' ')"
echo ""

# --- Step 3: For each repo project, fetch items and sync Iteration + Quarter ---

ITER_SET=0
ITER_SKIP=0
QUARTER_SET=0
QUARTER_SKIP=0
ERRORS=0

REPO_ITEMS_QUERY='
query($org: String!, $proj: Int!, $cursor: String) {
  organization(login: $org) {
    projectV2(number: $proj) {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content { ... on Issue { id } }
          iteration: fieldValueByName(name: "Iteration") {
            ... on ProjectV2ItemFieldIterationValue { title }
          }
          quarter: fieldValueByName(name: "Quarter") {
            ... on ProjectV2ItemFieldIterationValue { title }
          }
        }
      }
    }
  }
}
'

for proj_title in "${!PROJECT_BY_NAME[@]}"; do
  proj_id="${PROJECT_BY_NAME[$proj_title]}"

  [ "$proj_id" = "$GLOBAL_PROJECT_ID" ] && continue

  proj_num=$(echo "$ALL_PROJECTS_JSON" | jq -r --arg id "$proj_id" '.[] | select(.id == $id) | .number')

  echo "--- Project: \"$proj_title\" (#$proj_num) ---"

  RAW=$(gh api graphql \
    -f query="$REPO_ITEMS_QUERY" \
    -f org="$ORG" \
    -F proj="$proj_num" \
    --paginate 2>/dev/null)

  while IFS=$'\t' read -r item_id issue_id cur_iter cur_quarter; do
    [ -z "$item_id" ] && continue
    [ -z "$issue_id" ] || [ "$issue_id" = "null" ] && continue

    # --- Sync Iteration ---
    if [[ -v "ITER_FIELD_ID[$proj_id]" ]]; then
      global_iter="${GLOBAL_ITER_TITLE[$issue_id]:-}"
      if [ -n "$global_iter" ]; then
        if [ "$cur_iter" = "$global_iter" ]; then
          ITER_SKIP=$((ITER_SKIP + 1))
        else
          lookup_key="${proj_id}:${global_iter}"
          target_iter_id="${ITER_TITLE_TO_ID[$lookup_key]:-}"
          if [ -z "$target_iter_id" ]; then
            echo "  WARN: Iteration \"$global_iter\" not found in project $proj_title"
            ERRORS=$((ERRORS + 1))
          else
            if gh api graphql -f query="
              mutation {
                updateProjectV2ItemFieldValue(input: {
                  projectId: \"$proj_id\"
                  itemId: \"$item_id\"
                  fieldId: \"${ITER_FIELD_ID[$proj_id]}\"
                  value: { iterationId: \"$target_iter_id\" }
                }) { projectV2Item { id } }
              }" > /dev/null 2>&1; then
              echo "  Iteration → \"$global_iter\" (item $item_id)"
              ITER_SET=$((ITER_SET + 1))
            else
              echo "  ERROR setting Iteration on $item_id"
              ERRORS=$((ERRORS + 1))
            fi
          fi
        fi
      fi
    fi

    # --- Sync Quarter ---
    if [[ -v "QUARTER_FIELD_ID[$proj_id]" ]]; then
      global_quarter="${GLOBAL_QUARTER_TITLE[$issue_id]:-}"
      if [ -n "$global_quarter" ]; then
        if [ "$cur_quarter" = "$global_quarter" ]; then
          QUARTER_SKIP=$((QUARTER_SKIP + 1))
        else
          lookup_key="${proj_id}:${global_quarter}"
          target_quarter_id="${QUARTER_TITLE_TO_ID[$lookup_key]:-}"
          if [ -z "$target_quarter_id" ]; then
            echo "  WARN: Quarter \"$global_quarter\" not found in project $proj_title"
            ERRORS=$((ERRORS + 1))
          else
            if gh api graphql -f query="
              mutation {
                updateProjectV2ItemFieldValue(input: {
                  projectId: \"$proj_id\"
                  itemId: \"$item_id\"
                  fieldId: \"${QUARTER_FIELD_ID[$proj_id]}\"
                  value: { iterationId: \"$target_quarter_id\" }
                }) { projectV2Item { id } }
              }" > /dev/null 2>&1; then
              echo "  Quarter → \"$global_quarter\" (item $item_id)"
              QUARTER_SET=$((QUARTER_SET + 1))
            else
              echo "  ERROR setting Quarter on $item_id"
              ERRORS=$((ERRORS + 1))
            fi
          fi
        fi
      fi
    fi

  done < <(echo "$RAW" | jq -rs '
    [.[].data.organization.projectV2.items.nodes[] | select(.content.id != null)] |
    .[] | [
      .id,
      .content.id,
      (.iteration.title // ""),
      (.quarter.title // "")
    ] | @tsv
  ' 2>/dev/null)

done

echo ""
echo "=== Done ==="
echo "Iteration set: $ITER_SET | skipped: $ITER_SKIP"
echo "Quarter set:   $QUARTER_SET | skipped: $QUARTER_SKIP"
echo "Errors: $ERRORS"
