#!/bin/bash
#
# auto_readme.sh - Auto-detect new solution files and add README table entries
#
# Usage:
#   bash scripts/auto_readme.sh                    # auto-detect from git diff
#   bash scripts/auto_readme.sh file1.cpp file2.py # process specific files
#
# For each new solution file, the script:
#   1. Extracts the LeetCode URL from the "// Source :" comment in the file
#   2. Falls back to converting the folder name (camelCase → kebab-case slug)
#   3. Queries LeetCode GraphQL API for problem number, title, difficulty
#   4. Inserts a new row into the README.md table (sorted descending by number)
#
set -e

# ─── Resolve paths ───────────────────────────────────────────────────────────
pushd "$(dirname "$0")" > /dev/null
SCRIPT_PATH="$(pwd -P)"
popd > /dev/null

ROOT_DIR="${SCRIPT_PATH}/.."
README_FILE="${ROOT_DIR}/README.md"

if [ ! -f "${README_FILE}" ]; then
    echo "ERROR: README.md not found at ${README_FILE}"
    exit 1
fi

# ─── Helper: convert camelCase/PascalCase folder name to kebab-case slug ─────
# Handles edge cases: twoSum → two-sum, 3Sum → 3-sum, LRUCache → lru-cache
# UTF8Validation → utf-8-validation, eggDropWith2EggsAndNFloors → egg-drop-with-2-eggs-and-n-floors
function folder_to_slug() {
    local name="$1"
    echo "$name" \
        | sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' \
        | sed 's/\([A-Z]\+\)\([A-Z][a-z]\)/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]'
}

# ─── Helper: extract slug from source file's "// Source :" comment ───────────
function extract_slug_from_source() {
    local file="$1"
    local url=""

    # Try // Source : ... or # Source : ...
    url=$(grep -m1 -oP '(?:\/\/|#)\s*Source\s*:\s*\Khttps?://\S+' "$file" 2>/dev/null || echo "")

    if [ -n "$url" ]; then
        # Normalize: strip trailing slash and extract the slug
        url=$(echo "$url" | sed 's:/*$::')
        echo "$url" | grep -oP '(?<=problems/)[^/]+' || echo ""
    fi
}

# ─── Helper: query LeetCode API for problem metadata ────────────────────────
function query_leetcode() {
    local slug="$1"
    curl -sf 'https://leetcode.com/graphql' \
        -H 'content-type: application/json' \
        --data-binary "{\"operationName\":\"questionData\",\"variables\":{\"titleSlug\":\"${slug}\"},\"query\":\"query questionData(\$titleSlug: String!) { question(titleSlug: \$titleSlug) { questionFrontendId title difficulty titleSlug } }\"}" \
        2>/dev/null || echo ""
}

# ─── Helper: detect language from file extension ─────────────────────────────
function detect_language() {
    local file="$1"
    case "${file##*.}" in
        cpp|cc|c)  echo "C++"    ;;
        java)      echo "Java"   ;;
        py)        echo "Python" ;;
        go)        echo "Go"     ;;
        *)         echo ""       ;;
    esac
}

# ─── Helper: compute relative path from repo root ───────────────────────────
function relative_path() {
    local file="$1"
    local abs_root
    abs_root=$(cd "${ROOT_DIR}" && pwd -P)
    local abs_file
    abs_file=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
    echo ".${abs_file#${abs_root}}"
}

# ─── Collect files to process ────────────────────────────────────────────────
FILES=()

if [ $# -gt 0 ]; then
    # Files passed as arguments
    for f in "$@"; do
        if [ -f "$f" ]; then
            FILES+=("$f")
        elif [ -f "${ROOT_DIR}/$f" ]; then
            FILES+=("${ROOT_DIR}/$f")
        fi
    done
else
    # Auto-detect from git: new/modified files under algorithms/
    echo "Auto-detecting changed files from git..."
    while IFS= read -r f; do
        if [ -f "${ROOT_DIR}/$f" ]; then
            FILES+=("${ROOT_DIR}/$f")
        fi
    done < <(cd "${ROOT_DIR}" && git diff --name-only HEAD~1 HEAD -- 'algorithms/' 2>/dev/null || \
             git diff --name-only --cached -- 'algorithms/' 2>/dev/null || \
             echo "")
fi

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No new solution files detected."
    exit 0
fi

echo "Found ${#FILES[@]} file(s) to process."

# ─── Track which problems we've already processed ───────────────────────────
declare -A PROCESSED_SLUGS
CHANGES_MADE=0

for file in "${FILES[@]}"; do
    echo ""
    echo "Processing: $file"

    # Skip non-source files
    lang=$(detect_language "$file")
    if [ -z "$lang" ]; then
        echo "  Skipping (not a recognized source file)"
        continue
    fi

    # ── Step 1: Extract slug ─────────────────────────────────────────────
    slug=""

    # Strategy A: Read // Source : URL from the file
    slug=$(extract_slug_from_source "$file")
    if [ -n "$slug" ]; then
        echo "  Slug from source comment: $slug"
    fi

    # Strategy B: Convert folder name to slug
    if [ -z "$slug" ]; then
        folder_name=$(basename "$(dirname "$file")")
        slug=$(folder_to_slug "$folder_name")
        echo "  Slug from folder name: $folder_name → $slug"
    fi

    if [ -z "$slug" ]; then
        echo "  ERROR: Could not determine slug, skipping"
        continue
    fi

    # Skip if already processed this slug
    if [ -n "${PROCESSED_SLUGS[$slug]}" ]; then
        echo "  Already processed this slug, skipping"
        continue
    fi
    PROCESSED_SLUGS[$slug]=1

    # ── Step 2: Query LeetCode API ───────────────────────────────────────
    echo "  Querying LeetCode API for: $slug"
    response=$(query_leetcode "$slug")

    if [ -z "$response" ] || ! echo "$response" | grep -q '"questionFrontendId"'; then
        echo "  WARNING: API query failed for slug '$slug', skipping"
        continue
    fi

    prob_id=$(echo "$response" | grep -o '"questionFrontendId":"[^"]*"' | head -1 | cut -d'"' -f4)
    prob_title=$(echo "$response" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4)
    prob_difficulty=$(echo "$response" | grep -o '"difficulty":"[^"]*"' | head -1 | cut -d'"' -f4)
    prob_url="https://leetcode.com/problems/${slug}/"

    echo "  Found: #${prob_id} - ${prob_title} (${prob_difficulty})"

    # ── Step 3: Check if already in README ───────────────────────────────
    if grep -qP "^\|${prob_id}\|" "${README_FILE}"; then
        # Problem exists — check if this specific language link is present
        existing_line=$(grep -P "^\|${prob_id}\|" "${README_FILE}" | head -1)
        if echo "$existing_line" | grep -q "\[${lang}\]"; then
            echo "  Already in README with ${lang} solution, skipping"
            continue
        else
            # Add this language to the existing row
            rel_path=$(relative_path "$file")
            new_link=", [${lang}](${rel_path})"
            # Insert the new language link before the closing |Difficulty|
            updated_line=$(echo "$existing_line" | sed "s/|${prob_difficulty}|/${new_link}|${prob_difficulty}|/")
            # Use exact line replacement with a temp file
            escaped_existing=$(printf '%s\n' "$existing_line" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
            escaped_updated=$(printf '%s\n' "$updated_line" | sed 's/[&/\\]/\\&/g')
            sed -i "s|${escaped_existing}|${escaped_updated}|" "${README_FILE}"
            echo "  ✅ Added ${lang} link to existing entry #${prob_id}"
            CHANGES_MADE=$((CHANGES_MADE + 1))
            continue
        fi
    fi

    # ── Step 4: Build the new README row ─────────────────────────────────
    rel_path=$(relative_path "$file")
    new_row="|${prob_id}|[${prob_title}](${prob_url}) | [${lang}](${rel_path})|${prob_difficulty}|"

    echo "  New row: $new_row"

    # ── Step 5: Insert into README in sorted position (descending by #) ──
    # Find the correct position: after the header, before the first row
    # with a smaller problem number
    inserted=false
    tmp_file="${README_FILE}.tmp"

    awk -v new_row="$new_row" -v new_id="$prob_id" '
    BEGIN { inserted=0; in_algo_table=0 }
    /^### LeetCode Algorithm/ { in_algo_table=1 }
    /^### LeetCode Shell/ { in_algo_table=0 }
    {
        if (in_algo_table && !inserted && match($0, /^\|([0-9]+)\|/, arr)) {
            current_id = arr[1] + 0
            new_id_num = new_id + 0
            if (new_id_num > current_id) {
                print new_row
                inserted=1
            }
        }
        print
    }
    END {
        if (!inserted) print new_row
    }
    ' "${README_FILE}" > "${tmp_file}"

    mv "${tmp_file}" "${README_FILE}"
    echo "  ✅ Inserted #${prob_id} into README"
    CHANGES_MADE=$((CHANGES_MADE + 1))
done

echo ""
if [ "$CHANGES_MADE" -gt 0 ]; then
    echo "═══════════════════════════════════════════"
    echo "  ${CHANGES_MADE} change(s) made to README.md"
    echo "═══════════════════════════════════════════"
else
    echo "No changes needed."
fi
