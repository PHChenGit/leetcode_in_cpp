#!/bin/bash
#
# coverage.sh - Analyze LeetCode problem coverage and update README.md
#
# Usage: bash scripts/coverage.sh
#
# This script:
#   1. Queries LeetCode GraphQL API for total problem counts
#   2. Parses README.md to extract solved problem stats
#   3. Updates README.md with a coverage summary (including Mermaid pie chart)
#
set -e

# Resolve paths
pushd "$(dirname "$0")" > /dev/null
SCRIPT_PATH="$(pwd -P)"
popd > /dev/null

ROOT_DIR="${SCRIPT_PATH}/.."
README_FILE="${ROOT_DIR}/README.md"

if [ ! -f "${README_FILE}" ]; then
    echo "ERROR: README.md not found at ${README_FILE}"
    exit 1
fi

# ─── Query LeetCode API for total problem counts ────────────────────────────
echo "Fetching total problem count from LeetCode API..."

LEETCODE_API_RESPONSE=$(curl -sf 'https://leetcode.com/graphql' \
    -H 'content-type: application/json' \
    --data-binary '{"query":"query { allQuestionsCount { difficulty count } }"}' \
    2>/dev/null || echo "")

if [ -n "${LEETCODE_API_RESPONSE}" ] && echo "${LEETCODE_API_RESPONSE}" | grep -q '"data"'; then
    TOTAL_LC_ALL=$(echo "${LEETCODE_API_RESPONSE}" | grep -o '"difficulty":"All","count":[0-9]*' | grep -o '[0-9]*$')
    TOTAL_LC_EASY=$(echo "${LEETCODE_API_RESPONSE}" | grep -o '"difficulty":"Easy","count":[0-9]*' | grep -o '[0-9]*$')
    TOTAL_LC_MEDIUM=$(echo "${LEETCODE_API_RESPONSE}" | grep -o '"difficulty":"Medium","count":[0-9]*' | grep -o '[0-9]*$')
    TOTAL_LC_HARD=$(echo "${LEETCODE_API_RESPONSE}" | grep -o '"difficulty":"Hard","count":[0-9]*' | grep -o '[0-9]*$')
    echo "  LeetCode total: ${TOTAL_LC_ALL} (Easy: ${TOTAL_LC_EASY}, Medium: ${TOTAL_LC_MEDIUM}, Hard: ${TOTAL_LC_HARD})"
else
    echo "  WARNING: Could not fetch from LeetCode API, using fallback"
    TOTAL_LC_ALL="N/A"
    TOTAL_LC_EASY="N/A"
    TOTAL_LC_MEDIUM="N/A"
    TOTAL_LC_HARD="N/A"
fi

# ─── Parse the Algorithm table ───────────────────────────────────────────────
EASY=0
MEDIUM=0
HARD=0
TOTAL=0

CPP=0
JAVA=0
PYTHON=0
GOLANG=0

declare -A SEEN_PROBLEMS

while IFS= read -r line; do
    # Skip header / separator lines
    if [[ "$line" =~ ^\|---\| ]] || [[ "$line" =~ ^\|\ \#\  ]]; then
        continue
    fi

    # Extract problem number and difficulty
    prob_num=$(echo "$line" | awk -F'|' '{print $2}' | tr -d ' ')
    difficulty=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$NF); for(i=NF;i>=1;i--) if($i ~ /Easy|Medium|Hard/) {print $i; exit}}')
    difficulty=$(echo "$difficulty" | tr -d ' ')

    # Skip if not a valid problem row
    if ! [[ "$prob_num" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # Count unique problems
    if [ -z "${SEEN_PROBLEMS[$prob_num]}" ]; then
        SEEN_PROBLEMS[$prob_num]=1
        TOTAL=$((TOTAL + 1))

        case "$difficulty" in
            Easy)   EASY=$((EASY + 1)) ;;
            Medium) MEDIUM=$((MEDIUM + 1)) ;;
            Hard)   HARD=$((HARD + 1)) ;;
        esac
    fi

    # Count languages in this row
    solution_col=$(echo "$line" | awk -F'|' '{print $4}')
    if echo "$solution_col" | grep -q '\[C++\]'; then
        CPP=$((CPP + 1))
    fi
    if echo "$solution_col" | grep -q '\[Java\]'; then
        JAVA=$((JAVA + 1))
    fi
    if echo "$solution_col" | grep -q '\[Python\]'; then
        PYTHON=$((PYTHON + 1))
    fi
    if echo "$solution_col" | grep -q '\[Go\]'; then
        GOLANG=$((GOLANG + 1))
    fi

done < <(grep '^|[0-9]' "${README_FILE}")

# ─── Count Shell & Database problems ─────────────────────────────────────────
SHELL_COUNT=$(find "${ROOT_DIR}/shell" -name "*.sh" ! -name "README.md" 2>/dev/null | wc -l | tr -d ' ')
DB_COUNT=$(find "${ROOT_DIR}/database" -name "*.sql" 2>/dev/null | wc -l | tr -d ' ')

# ─── Compute coverage percentages ───────────────────────────────────────────
UNSOLVED=0
if [[ "${TOTAL_LC_ALL}" =~ ^[0-9]+$ ]]; then
    TOTAL_COVERAGE_PCT=$(awk "BEGIN {printf \"%.1f\", ($TOTAL / $TOTAL_LC_ALL) * 100}")
    CPP_COVERAGE_PCT=$(awk "BEGIN {printf \"%.1f\", ($CPP / $TOTAL_LC_ALL) * 100}")
    UNSOLVED=$((TOTAL_LC_ALL - TOTAL))
    TOTAL_DISPLAY="${TOTAL} / ${TOTAL_LC_ALL}"
    CPP_DISPLAY="${CPP} / ${TOTAL_LC_ALL}"
else
    TOTAL_COVERAGE_PCT="N/A"
    CPP_COVERAGE_PCT="N/A"
    UNSOLVED=0
    TOTAL_DISPLAY="${TOTAL}"
    CPP_DISPLAY="${CPP}"
fi

# ─── Get current date ────────────────────────────────────────────────────────
CURRENT_DATE=$(date +%Y-%m-%d)

# ─── Generate the coverage section ──────────────────────────────────────────
COVERAGE_SECTION=$(cat <<EOF
<!-- COVERAGE_START -->
## 📊 Coverage Summary

> Last updated: ${CURRENT_DATE}

| Metric | Solved | Total (LeetCode) | Coverage |
|--------|--------|-------------------|----------|
| **All Problems** | ${TOTAL} | ${TOTAL_LC_ALL} | ${TOTAL_COVERAGE_PCT}% |
| **C++ Solutions** | ${CPP} | ${TOTAL_LC_ALL} | ${CPP_COVERAGE_PCT}% |

| Difficulty | Solved | Total (LeetCode) |
|------------|--------|-------------------|
| 🟢 Easy | ${EASY} | ${TOTAL_LC_EASY} |
| 🟡 Medium | ${MEDIUM} | ${TOTAL_LC_MEDIUM} |
| 🔴 Hard | ${HARD} | ${TOTAL_LC_HARD} |

### Solved vs Unsolved

\`\`\`mermaid
pie title LeetCode Progress (${TOTAL} / ${TOTAL_LC_ALL})
    "Solved" : ${TOTAL}
    "Unsolved" : ${UNSOLVED}
\`\`\`

### Difficulty Distribution (Solved)

\`\`\`mermaid
pie title Solved Problems by Difficulty
    "Easy" : ${EASY}
    "Medium" : ${MEDIUM}
    "Hard" : ${HARD}
\`\`\`

### Solutions by Language

| Language | Solutions |
|----------|-----------|
| C++ | ${CPP} |
| Java | ${JAVA} |
| Python | ${PYTHON} |
| Go | ${GOLANG} |
| Shell | ${SHELL_COUNT} |
| SQL | ${DB_COUNT} |

<!-- COVERAGE_END -->
EOF
)

# ─── Update README.md ────────────────────────────────────────────────────────
if grep -q '<!-- COVERAGE_START -->' "${README_FILE}" && grep -q '<!-- COVERAGE_END -->' "${README_FILE}"; then
    # Replace existing coverage section (idempotent update)
    awk -v replacement="${COVERAGE_SECTION}" '
        /<!-- COVERAGE_START -->/ { printing=0; print replacement; next }
        /<!-- COVERAGE_END -->/ { printing=1; next }
        printing!=0 { print }
        BEGIN { printing=1 }
    ' "${README_FILE}" > "${README_FILE}.tmp"
    mv "${README_FILE}.tmp" "${README_FILE}"
    echo "✅ Updated existing coverage section in README.md"
else
    # Insert coverage section after the title (line 3 = after "========")
    awk -v replacement="${COVERAGE_SECTION}" '
        NR==4 { print replacement; print "" }
        { print }
    ' "${README_FILE}" > "${README_FILE}.tmp"
    mv "${README_FILE}.tmp" "${README_FILE}"
    echo "✅ Inserted new coverage section into README.md"
fi

# ─── Print summary to stdout ─────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  LeetCode Coverage Report"
echo "═══════════════════════════════════════════"
echo ""
echo "  Total LeetCode Problems : ${TOTAL_LC_ALL}"
echo "  Total Solved            : ${TOTAL} (${TOTAL_COVERAGE_PCT}%)"
echo "  C++ Solutions           : ${CPP} (${CPP_COVERAGE_PCT}%)"
echo ""
echo "  Easy                    : ${EASY} / ${TOTAL_LC_EASY}"
echo "  Medium                  : ${MEDIUM} / ${TOTAL_LC_MEDIUM}"
echo "  Hard                    : ${HARD} / ${TOTAL_LC_HARD}"
echo ""
echo "  Java Solutions          : ${JAVA}"
echo "  Python Solutions        : ${PYTHON}"
echo "  Go Solutions            : ${GOLANG}"
echo "  Shell Solutions         : ${SHELL_COUNT}"
echo "  SQL Solutions           : ${DB_COUNT}"
echo "═══════════════════════════════════════════"
