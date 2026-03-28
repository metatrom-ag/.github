#!/bin/bash
set -euo pipefail

# Sync Issue Fields to Project Items
# ====================================
# Phase 1 — Body-sourced fields: reads Priority and Story Points from the issue
#   body (Metatrom idea template) and writes Priority, Size, and Estimate to
#   every project item for that issue.
#
# Phase 2 — Cross-project field sync: for any other custom field (Iteration,
#   Quarter, or any future single-select/number/iteration field), takes the
#   first non-null value found across all project items for the same issue and
#   copies it to every other project item that has the same field.
#   Fields managed by GitHub (Status, Labels, Title, Assignees, etc.) and
#   fields already handled in Phase 1 are skipped.
#
# Template detection: only projects whose Status field contains Purpose,
#   Intention, and Action participate (same as sync-project-status.sh).

ORG="${ORG:-metatrom-ag}"

REQUIRED_STATUSES=("Purpose" "Intention" "Action")

# Fields managed elsewhere — skip from cross-project sync
SKIP_FIELDS=("Status" "Priority" "Size" "Estimate" "Labels" "Title" "Assignees" "Repository" "Milestone" "Linked pull requests")

echo "=== Sync Issue Fields ==="
echo "Org: $ORG"
echo ""

# --- Step 1: Get all org projects with fields, items, issue bodies, and current field values ---

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
        fields(first: 30) {
          nodes {
            __typename
            ... on ProjectV2SingleSelectField { id name options { id name } }
            ... on ProjectV2Field { id name dataType }
            ... on ProjectV2IterationField {
              id name
              configuration {
                iterations { id title startDate duration }
                completedIterations { id title startDate duration }
              }
            }
          }
        }
        items(first: 100) {
          nodes {
            id
            fieldValues(first: 30) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name optionId
                  field { ... on ProjectV2SingleSelectField { id name } }
                }
                ... on ProjectV2ItemFieldNumberValue {
                  number
                  field { ... on ProjectV2Field { id name } }
                }
                ... on ProjectV2ItemFieldIterationValue {
                  iterationId title
                  field { ... on ProjectV2IterationField { id name } }
                }
              }
            }
            content {
              __typename
              ... on Issue {
                id
                number
                title
                body
                labels(first: 20) {
                  nodes { name }
                }
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

REQUIRED_JQ=$(printf '"%s",' "${REQUIRED_STATUSES[@]}")
REQUIRED_JQ="[${REQUIRED_JQ%,}]"

ELIGIBLE_PROJECTS=$(echo "$PROJECTS_DATA" | jq --argjson req "$REQUIRED_JQ" '
  [.data.organization.projectsV2.nodes[] |
    . as $proj |
    ($proj.field.options // [] | map(.name)) as $opts |
    if ($req | all(. as $r | $opts | any(. == $r))) then . else empty end
  ]
')

ELIGIBLE_COUNT=$(echo "$ELIGIBLE_PROJECTS" | jq 'length')
echo "Found $ELIGIBLE_COUNT Ontocratic template-compatible projects:"
echo "$ELIGIBLE_PROJECTS" | jq -r '.[] | "  #\(.number) \(.title)"'
echo ""

if [ "$ELIGIBLE_COUNT" -lt 1 ]; then
  echo "No eligible projects found. Nothing to do."
  exit 0
fi

# --- Step 3: Collect all items across eligible projects ---

ALL_ITEMS=$(echo "$ELIGIBLE_PROJECTS" | jq '
  [.[] |
    . as $proj |
    ($proj.fields.nodes | map(select(.name == "Priority")) | first) as $pf |
    ($proj.fields.nodes | map(select(.name == "Size"))     | first) as $sf |
    ($proj.fields.nodes | map(select(.name == "Estimate" and .dataType == "NUMBER")) | first) as $ef |
    .items.nodes[] |
    select(.content.__typename == "Issue") |
    select(.content.id != null) |
    . as $item |
    {
      item_id: .id,
      content_id: .content.id,
      title: .content.title,
      body: (.content.body // ""),
      labels: [.content.labels.nodes[].name],
      project_id: $proj.id,
      project_title: $proj.title,
      project_number: $proj.number,
      priority_field_id: ($pf.id // null),
      priority_options: ($pf.options // []),
      size_field_id: ($sf.id // null),
      size_options: ($sf.options // []),
      estimate_field_id: ($ef.id // null),
      proj_fields: [
        $proj.fields.nodes[] |
        if .__typename == "ProjectV2SingleSelectField" then
          {name: .name, id: .id, type: "singleSelect", options: (.options // [])}
        elif .__typename == "ProjectV2IterationField" then
          {name: .name, id: .id, type: "iteration",
           iterations: ((.configuration.iterations // []) + (.configuration.completedIterations // []))}
        elif .__typename == "ProjectV2Field" and .dataType == "NUMBER" then
          {name: .name, id: .id, type: "number"}
        else empty end
      ],
      field_values: [
        $item.fieldValues.nodes[] |
        if .__typename == "ProjectV2ItemFieldSingleSelectValue" and .field.name != null then
          {name: .field.name, type: "singleSelect", value: .optionId, option_name: .name}
        elif .__typename == "ProjectV2ItemFieldNumberValue" and .field.name != null then
          {name: .field.name, type: "number", value: (.number | tostring), option_name: (.number | tostring)}
        elif .__typename == "ProjectV2ItemFieldIterationValue" and .field.name != null then
          {name: .field.name, type: "iteration", value: .iterationId, option_name: .title}
        else empty end
      ]
    }
  ]
')

TOTAL=$(echo "$ALL_ITEMS" | jq 'length')
echo "Found $TOTAL issue items across eligible projects"
echo ""

# --- Helper: get first non-empty line after a section header ---
after_header() {
  local body="$1" header="$2"
  echo "$body" | awk "/^${header}/{found=1; next} found && /^[^[:space:]]/{print; exit} found && /^[[:space:]]*$/{next}" | head -1
}

# --- Helper: parse story points from issue body ---
# Extracts the leading number from "### Story Points\n\n13 - Epic..."
parse_story_points() {
  local body="$1"
  after_header "$body" "### Story Points" | grep -oE '^[0-9]+' || echo ""
}

# --- Helper: derive Size option name from story points ---
derive_size() {
  local pts="$1"
  if   [ -z "$pts" ]; then echo ""
  elif [ "$pts" -le 1 ]; then echo "XS"
  elif [ "$pts" -le 3 ]; then echo "S"
  elif [ "$pts" -le 5 ]; then echo "M"
  elif [ "$pts" -le 8 ]; then echo "L"
  else echo "XL"
  fi
}

# --- Helper: parse priority from issue body ---
# Extracts the value after "### Priority\n\n" — matches project option name directly
parse_priority() {
  local body="$1"
  after_header "$body" "### Priority" | \
    grep -oE "(High - Must have|Medium - Should have|Low - Nice to have)" || echo ""
}

# --- Helper: check if a field name should be skipped from cross-project sync ---
should_skip_field() {
  local field_name="$1"
  for sf in "${SKIP_FIELDS[@]}"; do
    [ "$sf" = "$field_name" ] && return 0
  done
  return 1
}

UNIQUE_ISSUES=$(echo "$ALL_ITEMS" | jq '[.[].content_id] | unique | .[]' -r)

COUNTER_FILE=$(mktemp)
echo "0 0 0" > "$COUNTER_FILE"

# --- Step 4: Phase 1 — sync body-sourced fields (Priority, Size, Estimate) ---

echo "--- Phase 1: Body-sourced fields ---"
echo ""

while IFS= read -r content_id; do
  ISSUE_ITEMS=$(echo "$ALL_ITEMS" | jq --arg cid "$content_id" '[.[] | select(.content_id == $cid)]')
  TITLE=$(echo "$ISSUE_ITEMS" | jq -r '.[0].title')
  BODY=$(echo "$ISSUE_ITEMS" | jq -r '.[0].body')
  LABELS=$(echo "$ISSUE_ITEMS" | jq -r '.[0].labels | join(", ")')

  STORY_POINTS=$(parse_story_points "$BODY")
  PRIORITY=$(parse_priority "$BODY")
  SIZE=$(derive_size "$STORY_POINTS")

  echo "Issue: $TITLE"
  [ -n "$PRIORITY" ]      && echo "  Priority: $PRIORITY"
  [ -n "$STORY_POINTS" ]  && echo "  Story Points: $STORY_POINTS → Size: $SIZE"
  [ -n "$LABELS" ]        && echo "  Labels: $LABELS"

  if [ -z "$PRIORITY" ] && [ -z "$STORY_POINTS" ]; then
    echo "  No Priority or Story Points found in body, skipping"
    echo ""
    continue
  fi

  while IFS= read -r item; do
    ITEM_ID=$(echo "$item" | jq -r '.item_id')
    PROJECT_ID=$(echo "$item" | jq -r '.project_id')
    PROJECT_TITLE=$(echo "$item" | jq -r '.project_title')
    PRIORITY_FIELD_ID=$(echo "$item" | jq -r '.priority_field_id // empty')
    SIZE_FIELD_ID=$(echo "$item" | jq -r '.size_field_id // empty')
    ESTIMATE_FIELD_ID=$(echo "$item" | jq -r '.estimate_field_id // empty')

    UPDATED=false

    # Sync Priority
    if [ -n "$PRIORITY" ] && [ -n "$PRIORITY_FIELD_ID" ]; then
      OPTION_ID=$(echo "$item" | jq -r --arg p "$PRIORITY" \
        '.priority_options[] | select(.name == $p) | .id')
      if [ -n "$OPTION_ID" ]; then
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
              fieldId: \"$PRIORITY_FIELD_ID\"
              value: { singleSelectOptionId: \"$OPTION_ID\" }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          echo "  [$PROJECT_TITLE] Priority → $PRIORITY"
          UPDATED=true
        fi
      fi
    fi

    # Sync Size
    if [ -n "$SIZE" ] && [ -n "$SIZE_FIELD_ID" ]; then
      SIZE_OPTION_ID=$(echo "$item" | jq -r --arg s "$SIZE" \
        '.size_options[] | select(.name == $s) | .id')
      if [ -n "$SIZE_OPTION_ID" ]; then
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
              fieldId: \"$SIZE_FIELD_ID\"
              value: { singleSelectOptionId: \"$SIZE_OPTION_ID\" }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          echo "  [$PROJECT_TITLE] Size → $SIZE"
          UPDATED=true
        fi
      fi
    fi

    # Sync Estimate (story points as number)
    if [ -n "$STORY_POINTS" ] && [ -n "$ESTIMATE_FIELD_ID" ]; then
      if gh api graphql -f query="
        mutation {
          updateProjectV2ItemFieldValue(input: {
            projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
            fieldId: \"$ESTIMATE_FIELD_ID\"
            value: { number: $STORY_POINTS }
          }) { projectV2Item { id } }
        }" > /dev/null 2>&1; then
        echo "  [$PROJECT_TITLE] Estimate → $STORY_POINTS"
        UPDATED=true
      fi
    fi

    if $UPDATED; then
      read -r s sk e < "$COUNTER_FILE"; echo "$((s + 1)) $sk $e" > "$COUNTER_FILE"
    else
      read -r s sk e < "$COUNTER_FILE"; echo "$s $((sk + 1)) $e" > "$COUNTER_FILE"
    fi

  done < <(echo "$ISSUE_ITEMS" | jq -c '.[]')

  echo ""
done <<< "$UNIQUE_ISSUES"

# --- Step 5: Phase 2 — cross-project field sync (Iteration, Quarter, any other fields) ---
# For each issue in multiple projects: find all unique field names with values,
# skip body-sourced and system fields, then copy the first non-null value to
# every other project item that has the same field. Matches options/iterations by name.

echo "--- Phase 2: Cross-project field sync ---"
echo ""

while IFS= read -r content_id; do
  ISSUE_ITEMS=$(echo "$ALL_ITEMS" | jq --arg cid "$content_id" '[.[] | select(.content_id == $cid)]')
  TITLE=$(echo "$ISSUE_ITEMS" | jq -r '.[0].title')

  # Only worth syncing if the issue appears in more than one project
  PROJ_COUNT=$(echo "$ISSUE_ITEMS" | jq 'map(.project_id) | unique | length')
  if [ "$PROJ_COUNT" -lt 2 ]; then
    continue
  fi

  # Collect all field names that have a value set on any item
  FIELD_NAMES=$(echo "$ISSUE_ITEMS" | jq -r '[.[].field_values[] | select(.value != null and .value != "") | .name] | unique[]')

  [ -z "$FIELD_NAMES" ] && continue

  HEADER_PRINTED=false

  while IFS= read -r field_name; do
    should_skip_field "$field_name" && continue

    # Find first item that has a value for this field
    SOURCE_JSON=$(echo "$ISSUE_ITEMS" | jq -c --arg fn "$field_name" \
      'first(.[] | .field_values[] | select(.name == $fn and .value != null and .value != "")) // empty')

    [ -z "$SOURCE_JSON" ] && continue

    FIELD_TYPE=$(echo "$SOURCE_JSON" | jq -r '.type')
    OPTION_NAME=$(echo "$SOURCE_JSON" | jq -r '.option_name // ""')
    VALUE=$(echo "$SOURCE_JSON" | jq -r '.value')

    # Apply to all project items
    while IFS= read -r item; do
      ITEM_ID=$(echo "$item" | jq -r '.item_id')
      PROJECT_ID=$(echo "$item" | jq -r '.project_id')
      PROJECT_TITLE=$(echo "$item" | jq -r '.project_title')

      # Find this field in the target project by name
      TARGET_FIELD=$(echo "$item" | jq -c --arg fn "$field_name" \
        '.proj_fields[] | select(.name == $fn)')

      [ -z "$TARGET_FIELD" ] && continue

      TARGET_FIELD_ID=$(echo "$TARGET_FIELD" | jq -r '.id')
      TARGET_TYPE=$(echo "$TARGET_FIELD" | jq -r '.type')

      MUTATION_OK=false

      if [ "$TARGET_TYPE" = "singleSelect" ]; then
        TARGET_OPTION_ID=$(echo "$TARGET_FIELD" | jq -r --arg on "$OPTION_NAME" \
          '.options[] | select(.name == $on) | .id')
        [ -z "$TARGET_OPTION_ID" ] && continue
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
              fieldId: \"$TARGET_FIELD_ID\"
              value: { singleSelectOptionId: \"$TARGET_OPTION_ID\" }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          MUTATION_OK=true
        fi

      elif [ "$TARGET_TYPE" = "iteration" ]; then
        TARGET_ITER_ID=$(echo "$TARGET_FIELD" | jq -r --arg on "$OPTION_NAME" \
          '.iterations[] | select(.title == $on) | .id')
        [ -z "$TARGET_ITER_ID" ] && continue
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
              fieldId: \"$TARGET_FIELD_ID\"
              value: { iterationId: \"$TARGET_ITER_ID\" }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          MUTATION_OK=true
        fi

      elif [ "$TARGET_TYPE" = "number" ]; then
        if gh api graphql -f query="
          mutation {
            updateProjectV2ItemFieldValue(input: {
              projectId: \"$PROJECT_ID\" itemId: \"$ITEM_ID\"
              fieldId: \"$TARGET_FIELD_ID\"
              value: { number: $VALUE }
            }) { projectV2Item { id } }
          }" > /dev/null 2>&1; then
          MUTATION_OK=true
        fi
      fi

      if $MUTATION_OK; then
        if ! $HEADER_PRINTED; then
          echo "Issue: $TITLE"
          HEADER_PRINTED=true
        fi
        echo "  [$PROJECT_TITLE] $field_name → $OPTION_NAME"
        read -r s sk e < "$COUNTER_FILE"; echo "$((s + 1)) $sk $e" > "$COUNTER_FILE"
      fi

    done < <(echo "$ISSUE_ITEMS" | jq -c '.[]')

  done <<< "$FIELD_NAMES"

  $HEADER_PRINTED && echo ""

done <<< "$UNIQUE_ISSUES"

read -r SYNCED SKIPPED ERRORS < "$COUNTER_FILE"
rm -f "$COUNTER_FILE"

echo "=== Done ==="
echo "Synced: $SYNCED | Skipped: $SKIPPED | Errors: $ERRORS"
