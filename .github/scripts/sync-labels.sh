#!/bin/bash
set -euo pipefail

# Sync Labels from .github to all org repos
# ==========================================
# Reads the label definitions from the .github repo and ensures every
# non-archived org repo has the same labels (name, color, description).
# Labels that don't exist are created; existing ones are updated if they differ.
# Labels in target repos that are not in .github are left untouched.

ORG="${ORG:-metatrom-ag}"
SOURCE_REPO="${SOURCE_REPO:-.github}"

echo "=== Sync Labels ==="
echo "Org: $ORG  Source: $SOURCE_REPO"
echo ""

# --- Step 1: Fetch canonical labels from source repo ---

echo "Fetching labels from $ORG/$SOURCE_REPO..."
SOURCE_LABELS=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      labels(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { name color description }
      }
    }
  }
' -f owner="$ORG" -f repo="$SOURCE_REPO" --paginate -q \
  '[.data.repository.labels.nodes[]]' | jq -s '[.[][]]')

LABEL_COUNT=$(echo "$SOURCE_LABELS" | jq 'length')
echo "Found $LABEL_COUNT canonical labels"
echo ""

# --- Step 2: Fetch all non-archived org repos ---

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

echo ""

# --- Step 3: For each repo, ensure canonical labels exist and are up to date ---

CREATED=0
UPDATED=0
SKIPPED=0
ERRORS=0

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  [ "$repo" = "$SOURCE_REPO" ] && continue  # skip source repo itself

  echo "Repo: $repo"

  # Fetch existing labels for this repo
  EXISTING=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        labels(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { name color description }
        }
      }
    }
  ' -f owner="$ORG" -f repo="$repo" --paginate -q \
    '[.data.repository.labels.nodes[]]' 2>/dev/null | jq -s '[.[][]]' 2>/dev/null || echo "[]")

  # For each canonical label, create or update in this repo
  while IFS=$'\t' read -r name color description; do
    # Check if label exists in this repo
    existing_color=$(echo "$EXISTING" | jq -r --arg n "$name" '.[] | select(.name == $n) | .color' 2>/dev/null || echo "")
    existing_desc=$(echo "$EXISTING" | jq -r --arg n "$name" '.[] | select(.name == $n) | .description' 2>/dev/null || echo "")

    if [ -z "$existing_color" ]; then
      # Create
      if gh api repos/"$ORG"/"$repo"/labels \
        -X POST \
        -f name="$name" \
        -f color="$color" \
        -f description="$description" \
        > /dev/null 2>&1; then
        echo "  + created: $name"
        CREATED=$((CREATED + 1))
      else
        echo "  ! error creating: $name"
        ERRORS=$((ERRORS + 1))
      fi
    elif [ "$existing_color" != "$color" ] || [ "$existing_desc" != "$description" ]; then
      # Update
      ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$name'''))" 2>/dev/null || echo "$name")
      if gh api "repos/$ORG/$repo/labels/$ENCODED_NAME" \
        -X PATCH \
        -f color="$color" \
        -f description="$description" \
        > /dev/null 2>&1; then
        echo "  ~ updated: $name"
        UPDATED=$((UPDATED + 1))
      else
        echo "  ! error updating: $name"
        ERRORS=$((ERRORS + 1))
      fi
    else
      SKIPPED=$((SKIPPED + 1))
    fi
  done < <(echo "$SOURCE_LABELS" | jq -r '.[] | [.name, .color, .description] | @tsv')

done <<< "$REPOS"

echo ""
echo "=== Done ==="
echo "Created: $CREATED | Updated: $UPDATED | Unchanged: $SKIPPED | Errors: $ERRORS"
