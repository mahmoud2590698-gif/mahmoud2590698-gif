#!/usr/bin/env bash
# cursor-governance-managed:1.0.0
# Enforcement script. Policy text lives in ~/.cursor/governance/POLICY.md.
set -u

MODE="${1:-start}"
shift || true
TASK=""
USER_REQUESTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      TASK="${2:-}"
      shift 2
      ;;
    --user-requested)
      USER_REQUESTED=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

BRANCH="unknown"
BASE="unknown"
BEHIND="unknown"
AHEAD="unknown"
ADDED="unknown"
EXISTING="skipped"
OPEN_PR="skipped"
WORKFLOW_RESOLVED="unknown"
FETCH_NOTE=""

block() {
  printf '%s\n' "PREFLIGHT_BLOCK" "reason=$1" "branch=$BRANCH" "base=$BASE" "behind=$BEHIND" "ahead=$AHEAD" "added_lines=$ADDED" "existing_equivalent=$EXISTING" "open_equivalent_pr=$OPEN_PR" "workflow=$WORKFLOW_RESOLVED"
  exit 1
}

ok() {
  printf '%s\n' "PREFLIGHT_OK" "branch=$BRANCH" "base=$BASE" "behind=$BEHIND" "ahead=$AHEAD" "added_lines=$ADDED" "existing_equivalent=$EXISTING" "open_equivalent_pr=$OPEN_PR" "workflow=$WORKFLOW_RESOLVED"
  [[ -n "$FETCH_NOTE" ]] && printf '%s\n' "$FETCH_NOTE"
  exit 0
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || block NOT_A_GIT_REPO
cd "$ROOT" || block NOT_A_GIT_REPO

CONFIG="$ROOT/.cursor/governance.json"
mkdir -p "$ROOT/.cursor/context"

cfg() {
  local key="$1" line
  [[ -f "$CONFIG" ]] || return 0
  line=$(grep -E "^[[:space:]]*\"${key}\"[[:space:]]*:" "$CONFIG" | head -n 1 || true)
  [[ -n "$line" ]] || return 0
  line=${line#*:}
  line=${line%%#*}
  line=${line%,}
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
  printf '%s' "$line"
}

if [[ ! -f "$CONFIG" ]]; then
  if [[ "$MODE" == "snapshot" ]]; then
    :
  else
    block GOVERNANCE_CONFIG_MISSING
  fi
fi

ENABLED=$(cfg enabled)
SCHEMA=$(cfg schema_version)
if [[ "$MODE" != "snapshot" ]]; then
  if [[ -n "$SCHEMA" && "$SCHEMA" != "1" ]]; then
    block INVALID_GOVERNANCE_CONFIG
  fi
  if [[ "$ENABLED" == "false" ]]; then
    WORKFLOW_RESOLVED="disabled"
    BEHIND=0
    AHEAD=0
    ADDED=0
    ok
  fi
fi

WORKFLOW=$(cfg workflow)
[[ -n "$WORKFLOW" ]] || WORKFLOW="auto"
DIFF_LIMIT=$(cfg diff_limit_added_lines)
[[ -n "$DIFF_LIMIT" ]] || DIFF_LIMIT="300"
ENFORCEMENT=$(cfg diff_limit_enforcement)
[[ -n "$ENFORCEMENT" ]] || ENFORCEMENT="hard"
FETCH_TTL=$(cfg fetch_ttl_seconds)
[[ -n "$FETCH_TTL" ]] || FETCH_TTL="600"
BLOCK_BEHIND=$(cfg block_push_when_behind_main)
[[ -n "$BLOCK_BEHIND" ]] || BLOCK_BEHIND="true"
BLOCK_CONFLICTS=$(cfg block_unresolved_conflicts)
[[ -n "$BLOCK_CONFLICTS" ]] || BLOCK_CONFLICTS="true"
BLOCK_DEFAULT=$(cfg block_push_to_default_branch)
[[ -n "$BLOCK_DEFAULT" ]] || BLOCK_DEFAULT="true"
CHECK_DUP=$(cfg check_duplicate_implementation)
[[ -n "$CHECK_DUP" ]] || CHECK_DUP="true"
CHECK_PR=$(cfg check_existing_pr)
[[ -n "$CHECK_PR" ]] || CHECK_PR="true"
REQUIRE_FETCH=$(cfg require_fetch_before_substantial_work)
[[ -n "$REQUIRE_FETCH" ]] || REQUIRE_FETCH="true"
REQUIRE_TESTS=$(cfg require_tests_before_recording)
[[ -n "$REQUIRE_TESTS" ]] || REQUIRE_TESTS="true"
MIGRATION_GUARD=$(cfg allow_migrations_only_when_required)
[[ -n "$MIGRATION_GUARD" ]] || MIGRATION_GUARD="true"
GLOBS=$(cfg generated_globs)
[[ -n "$GLOBS" ]] || GLOBS="package-lock.json pnpm-lock.yaml yarn.lock composer.lock Cargo.lock *.min.js *.min.css *.map"
TEST_COMMANDS=$(cfg test_commands)
BUILD_COMMANDS=$(cfg build_commands)

count_added() {
  git diff --numstat "$@" 2>/dev/null | awk -v globs="$GLOBS .cursor/* scripts/preflight.sh scripts/guard-push.sh scripts/enable-hooks.sh .githooks/*" '
    BEGIN { n = split(globs, g, " ") }
    function match_glob(text, pat, regex) {
      regex = pat
      gsub(/\./, "\\.", regex)
      gsub(/\*/, ".*", regex)
      return (text ~ ("^" regex "$"))
    }
    {
      add = $1
      path = $3
      if (add ~ /^[0-9]+$/) {
        base = path
        sub(/^.*\//, "", base)
        skip = 0
        for (i = 1; i <= n; i++) {
          if (g[i] != "" && (match_glob(path, g[i]) || match_glob(base, g[i]))) skip = 1
        }
        if (!skip) total += add
      }
    }
    END { print total + 0 }
  '
}

SHORT_BRANCH=$(git symbolic-ref --quiet --short HEAD || true)
if [[ -z "$SHORT_BRANCH" ]]; then
  BRANCH="DETACHED"
  DETACHED=1
else
  BRANCH="$SHORT_BRANCH"
  DETACHED=0
fi

HAS_ORIGIN=0
if git remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
fi

detect_base() {
  local ref
  BASE=""
  if [[ "$HAS_ORIGIN" == "1" ]]; then
    ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$ref" ]]; then
      BASE=${ref#refs/remotes/}
      return
    fi
    if git show-ref --verify --quiet refs/remotes/origin/main; then BASE="origin/main"; return; fi
    if git show-ref --verify --quiet refs/remotes/origin/master; then BASE="origin/master"; return; fi
  fi
  if git show-ref --verify --quiet refs/heads/main; then BASE="main"; return; fi
  if git show-ref --verify --quiet refs/heads/master; then BASE="master"; return; fi
}

detect_base

if [[ "$MODE" != "snapshot" && "$REQUIRE_FETCH" == "true" && "$HAS_ORIGIN" == "1" && "${GOVERNANCE_SKIP_FETCH:-}" != "1" ]]; then
  STAMP="$ROOT/.cursor/context/.fetch-stamp"
  NOW=$(date +%s)
  if git fetch --prune --quiet origin >/dev/null 2>&1; then
    printf '%s\n' "$NOW" > "$STAMP"
    FETCH_NOTE="fetch=ok"
    detect_base
  else
    if [[ "$MODE" == "start" && -f "$STAMP" ]]; then
      FETCH_NOTE="fetch=stale"
    else
      block FETCH_FAILED
    fi
  fi
fi

if [[ -z "$BASE" ]]; then
  BEHIND=0
  AHEAD=0
else
  COUNTS=$(git rev-list --left-right --count "${BASE}...HEAD" 2>/dev/null || true)
  if [[ "$COUNTS" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    BEHIND="${BASH_REMATCH[1]}"
    AHEAD="${BASH_REMATCH[2]}"
  else
    BEHIND=0
    AHEAD=0
  fi
fi

PHASE=""
if [[ "$BRANCH" =~ (phase|stage)[/-]([0-9]+) ]]; then
  PHASE="${BASH_REMATCH[2]}"
fi

WORKFLOW_RESOLVED="$WORKFLOW"
if [[ "$WORKFLOW" == "auto" ]]; then
  WORKFLOW_RESOLVED="standard"
  for candidate in ROADMAP.md ROADMAP.txt docs/ROADMAP.md docs/roadmap.md; do
    if [[ -f "$candidate" ]] && head -n 120 "$candidate" | grep -E -q -i 'phase[[:space:]/#:-]*[0-9]|مرحلة[[:space:]]*[0-9]|المرحلة'; then
      WORKFLOW_RESOLVED="phased"
      break
    fi
  done
fi

ADDED_COMMITTED=0
ADDED_UNCOMMITTED=0
ADDED_UNTRACKED=0
if [[ -n "$BASE" ]] && git rev-parse --verify --quiet "$BASE" >/dev/null; then
  ADDED_COMMITTED=$(count_added "${BASE}...HEAD")
fi
if git rev-parse --verify --quiet HEAD >/dev/null; then
  ADDED_UNCOMMITTED=$(count_added HEAD)
fi
while IFS= read -r untracked; do
  [[ -f "$untracked" ]] || continue
  case "$untracked" in
    .cursor/*|.cursor|scripts/preflight.sh|scripts/guard-push.sh|scripts/enable-hooks.sh|.githooks/*|.githooks) continue ;;
  esac
  skipped=0
  base_name=${untracked##*/}
  for pat in $GLOBS; do
    case "$untracked" in $pat) skipped=1 ;; esac
    case "$base_name" in $pat) skipped=1 ;; esac
  done
  [[ "$skipped" == "1" ]] && continue
  if LC_ALL=C grep -q $'\0' "$untracked" 2>/dev/null; then
    continue
  fi
  lines=$(wc -l < "$untracked" | tr -d '[:space:]')
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
  ADDED_UNTRACKED=$((ADDED_UNTRACKED + lines))
done < <(git ls-files --others --exclude-standard)

TOTAL_ADDED=$((ADDED_COMMITTED + ADDED_UNCOMMITTED + ADDED_UNTRACKED))
ADDED=$TOTAL_ADDED
BASELINE="$ROOT/.cursor/governance-baseline.json"
if [[ -f "$BASELINE" ]]; then
  B_BRANCH=$(grep -E '^[[:space:]]*"branch"[[:space:]]*:' "$BASELINE" | head -n 1 | sed 's/.*: *"//; s/".*//')
  B_COMMIT=$(grep -E '^[[:space:]]*"baseline_commit"[[:space:]]*:' "$BASELINE" | head -n 1 | sed 's/.*: *"//; s/".*//')
  B_EXEMPT=$(grep -E '^[[:space:]]*"exempt_added_lines"[[:space:]]*:' "$BASELINE" | head -n 1 | sed 's/.*: *//; s/,.*//; s/[^0-9].*//')
  if [[ ! "$B_EXEMPT" =~ ^[0-9]+$ ]]; then
    B_COMMITTED=$(grep -E '^[[:space:]]*"committed_added_lines"[[:space:]]*:' "$BASELINE" | head -n 1 | sed 's/.*: *//; s/,.*//; s/[^0-9].*//')
    B_UNCOMMITTED=$(grep -E '^[[:space:]]*"uncommitted_added_lines"[[:space:]]*:' "$BASELINE" | head -n 1 | sed 's/.*: *//; s/,.*//; s/[^0-9].*//')
    [[ "$B_COMMITTED" =~ ^[0-9]+$ ]] || B_COMMITTED=0
    [[ "$B_UNCOMMITTED" =~ ^[0-9]+$ ]] || B_UNCOMMITTED=0
    B_EXEMPT=$((B_COMMITTED + B_UNCOMMITTED))
  fi
  if [[ "$B_BRANCH" == "$BRANCH" && -n "$B_COMMIT" ]] && git merge-base --is-ancestor "$B_COMMIT" HEAD 2>/dev/null; then
    ADDED=$((TOTAL_ADDED - B_EXEMPT))
    (( ADDED < 0 )) && ADDED=0
  fi
fi

if [[ "$MODE" == "snapshot" ]]; then
  SHA=$(git rev-parse HEAD 2>/dev/null || echo none)
  printf '%s\n' "SNAPSHOT_OK" "branch=$BRANCH" "commit=$SHA" "committed_added=$ADDED_COMMITTED" "uncommitted_added=$ADDED_UNCOMMITTED" "untracked_added=$ADDED_UNTRACKED" "total_added=$TOTAL_ADDED" "base=$BASE"
  exit 0
fi

GIT_DIR=$(git rev-parse --git-dir)
if [[ -f "$GIT_DIR/MERGE_HEAD" || -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" || -f "$GIT_DIR/CHERRY_PICK_HEAD" ]]; then
  block GIT_OPERATION_IN_PROGRESS
fi
if [[ "$BLOCK_CONFLICTS" == "true" && -n "$(git diff --name-only --diff-filter=U 2>/dev/null || true)" ]]; then
  block UNRESOLVED_CONFLICTS
fi
if [[ "$DETACHED" == "1" ]]; then
  block DETACHED_HEAD
fi

DEFAULT_NAME="${BASE#origin/}"
ON_DEFAULT=0
if [[ "$BRANCH" == "$DEFAULT_NAME" ]]; then
  ON_DEFAULT=1
fi

if [[ "$BLOCK_BEHIND" == "true" && "$BEHIND" =~ ^[0-9]+$ && "$BEHIND" -gt 0 ]]; then
  block BRANCH_BEHIND_MAIN
fi

if [[ "$MODE" == "push" || "$MODE" == "pr" ]]; then
  if [[ "$ON_DEFAULT" == "1" && "$BLOCK_DEFAULT" == "true" && "$HAS_ORIGIN" == "1" ]]; then
    block PUSH_TO_DEFAULT_BRANCH
  fi
fi

if [[ "$WORKFLOW_RESOLVED" == "phased" && -n "$PHASE" && -n "$BASE" ]]; then
  ROADMAP_TEXT=""
  for candidate in ROADMAP.md ROADMAP.txt docs/ROADMAP.md docs/roadmap.md; do
    if git cat-file -e "${BASE}:${candidate}" 2>/dev/null; then
      ROADMAP_TEXT=$(git show "${BASE}:${candidate}" 2>/dev/null | head -n 200 || true)
      break
    fi
  done
  if [[ -n "$ROADMAP_TEXT" ]] && printf '%s\n' "$ROADMAP_TEXT" | grep -E -i "(phase|stage|مرحلة)[[:space:]#/:-]*0*${PHASE}([^0-9]|$)" | grep -E -q -i 'done|complete|merged|مكتمل|✅'; then
    EXISTING="EXACT_MATCH"
    block PHASE_ALREADY_MERGED
  fi
fi

if [[ "$CHECK_DUP" == "true" && -n "$TASK" && ${#TASK} -ge 8 && -n "$BASE" ]]; then
  HITS=$(git log "$BASE" --format=%s -n 80 --fixed-strings --grep="$TASK" 2>/dev/null || true)
  if [[ -n "$HITS" ]]; then
    if [[ ${#TASK} -ge 20 ]]; then
      EXISTING="EXACT_MATCH"
      block DUPLICATE_IMPLEMENTATION
    else
      EXISTING="POSSIBLE_MATCH"
    fi
  else
    EXISTING="NONE"
  fi
fi

if [[ "$CHECK_PR" == "true" && -n "$PHASE" && "$HAS_ORIGIN" == "1" ]] && command -v gh >/dev/null 2>&1; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
  case "$REMOTE_URL" in
    *github.com*)
      CACHE="$ROOT/.cursor/context/pr-cache.tsv"
      NOW=$(date +%s)
      USE_CACHE=0
      if [[ -f "$CACHE" ]]; then
        OLD=$(head -n 1 "$CACHE" || echo 0)
        if [[ "$OLD" =~ ^[0-9]+$ ]] && (( NOW - OLD < FETCH_TTL )); then
          USE_CACHE=1
        fi
      fi
      if [[ "$USE_CACHE" == "0" ]]; then
        {
          printf '%s\n' "$NOW"
          GH_PROMPT_DISABLED=1 gh pr list --state open --limit 30 --json number,title,headRefName --jq '.[] | [.number, .headRefName, .title] | @tsv' 2>/dev/null || true
        } > "$CACHE"
      fi
      OPEN_PR="NONE"
      while IFS="$(printf '\t')" read -r num head title; do
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        if [[ "$head" == "$BRANCH" ]]; then
          continue
        fi
        if printf '%s %s\n' "$head" "$title" | grep -E -q -i "(phase|stage)[ /#-]*0*${PHASE}([^0-9]|$)"; then
          OPEN_PR="EXACT_MATCH"
          break
        fi
      done < <(tail -n +2 "$CACHE")
      if [[ "$OPEN_PR" == "EXACT_MATCH" ]]; then
        block DUPLICATE_PHASE_PR
      fi
      ;;
  esac
fi

if [[ "$DIFF_LIMIT" =~ ^[0-9]+$ && "$ADDED" =~ ^[0-9]+$ && "$ADDED" -gt "$DIFF_LIMIT" ]]; then
  if [[ "$ENFORCEMENT" == "hard" ]]; then
    block DIFF_LIMIT_EXCEEDED
  fi
  FETCH_NOTE="${FETCH_NOTE} diff_warning=DIFF_LIMIT_EXCEEDED"
fi

if [[ "$MODE" == "migrate" && "$MIGRATION_GUARD" == "true" && "${GOVERNANCE_MIGRATION_REQUIRED:-}" != "1" ]]; then
  block MIGRATION_NOT_EXPLICITLY_REQUIRED
fi

if [[ "$MODE" == "record" ]]; then
  if [[ "$USER_REQUESTED" != "1" && "${GOVERNANCE_USER_REQUESTED_RECORDING:-}" != "1" ]]; then
    block RECORDING_NOT_EXPLICITLY_REQUESTED
  fi
  if [[ "$REQUIRE_TESTS" == "true" && -z "$TEST_COMMANDS" ]]; then
    block TESTS_NOT_CONFIGURED
  fi
  if [[ -n "$TEST_COMMANDS" ]] && ! bash -c "$TEST_COMMANDS"; then
    block TESTS_FAILED
  fi
  if [[ -n "$BUILD_COMMANDS" ]] && ! bash -c "$BUILD_COMMANDS"; then
    block BUILD_FAILED
  fi
fi

ok
