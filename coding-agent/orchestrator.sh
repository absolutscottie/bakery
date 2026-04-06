#!/bin/bash
# ~/coding-agent/orchestrator.sh
# Autonomous coding agent — advances a JSON state machine one step per cron run.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
ZEROCLAW_DIR="$HOME/.zeroclaw/workspace"
AGENT_DIR="$HOME/coding-agent"
REPOS_FILE="$AGENT_DIR/repos.json"
STATE_FILE="$AGENT_DIR/state.json"
LOG_FILE="$AGENT_DIR/agent.log"
WORKDIR_ROOT="$ZEROCLAW_DIR/workdir"

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"
}

# ─── Notifications (via ZeroClaw) ─────────────────────────────────────────────
notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  zeroclaw channel send "$msg" --channel-id telegram --recipient 8608375766 || true
}

ask() {
  # Sends a question via ZeroClaw and writes the reply to the given file.
  # Blocks until a reply is received.
  local question="$1"
  local answer_file="$2"
  log "ASK: $question"
  zeroclaw channel send "$question (write the answer to $answer_file)" --channel-id telegram --recipient 8608375766 || true
}

# ─── State file helpers ───────────────────────────────────────────────────────
state_read() {
  jq -r ".$1 // empty" "$STATE_FILE" 2>/dev/null || true
}

state_write() {
  # Usage: state_write field value [field value ...]
  # Merges key/value pairs into the existing state file atomically.
  local tmp
  tmp=$(mktemp)
  cp "$STATE_FILE" "$tmp"
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"
    shift 2
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$tmp" > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg pid "$$" \
     '. + {updated_at: $ts, pid: $pid}' "$tmp" > "$STATE_FILE"
  rm -f "$tmp"
}

state_init() {
  mkdir -p "$AGENT_DIR" "$WORKDIR_ROOT"
  cat > "$STATE_FILE" <<EOF
{
  "state": "unlocked",
  "pid": "",
  "goal": "looking_for_work",
  "repo": "",
  "issue_number": "",
  "issue_title": "",
  "branch": "",
  "model": "",
  "run_id": "",
  "attempt": "0",
  "max_attempts": "3",
  "has_ci": "true",
  "default_branch": "main",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  log "State file initialised"
}

# ─── Repo config helpers ──────────────────────────────────────────────────────
repo_slug() {
  # e.g. absolutscottie/plural -> absolutscottie-plural
  echo "$1" | tr '/' '-'
}

repo_field() {
  local repo="$1" field="$2"
  jq -r --arg r "$repo" --arg f "$field" \
    '.[] | select(.repo == $r) | .[$f] // empty' "$REPOS_FILE"
}

enabled_repos() {
  jq -r '.[] | select(.enabled == true) | .repo' "$REPOS_FILE"
}

# ─── Lock management ──────────────────────────────────────────────────────────
acquire_lock() {
  state_write "state" "locked"
  log "Lock acquired (PID $$)"
}

release_lock() {
  state_write "state" "unlocked"
  log "Lock released"
}

check_lock() {
  local lock_state pid goal repo issue_number updated_at
  lock_state=$(state_read "state")
  pid=$(state_read "pid")
  goal=$(state_read "goal")
  repo=$(state_read "repo")
  issue_number=$(state_read "issue_number")
  updated_at=$(state_read "updated_at")

  if [[ "$lock_state" != "locked" ]]; then
    return 0
  fi

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "Locked by live PID $pid (goal: $goal). Exiting."
    exit 0
  fi

  # PID is dead but lock is held — something fell over
  log "Dead PID $pid held lock (goal: $goal, repo: $repo, issue: #$issue_number, since: $updated_at)"
  notify "a dead lock was found. Goal was '$goal' on $repo issue #$issue_number (PID $pid, locked since $updated_at). Manual intervention required — run agent-reset on the Pi."
  state_write "goal" "intervention_required" "state" "unlocked"
  exit 1
}

# ─── Goal: looking_for_work ───────────────────────────────────────────────────
do_find_issue() {
  log "Looking for open issues across enabled repos..."

  local found_repo="" found_issue="" oldest_date=""

  while IFS= read -r repo; do
    local label
    label=$(repo_field "$repo" "in_progress_label")
    label="${label:-in-progress}"

    local issue
    issue=$(gh issue list \
      --repo "$repo" \
      --state open \
      --json number,title,body,createdAt,labels \
      --jq "[.[] | select(.labels | map(.name) | contains([\"$label\"]) | not)] | sort_by(.createdAt) | first // empty" 2>/dev/null || true)

    [[ -z "$issue" ]] && continue

    local created_at
    created_at=$(echo "$issue" | jq -r '.createdAt')

    if [[ -z "$oldest_date" || "$created_at" < "$oldest_date" ]]; then
      oldest_date="$created_at"
      found_repo="$repo"
      found_issue="$issue"
    fi
  done < <(enabled_repos)

  if [[ -z "$found_issue" ]]; then
    log "No open issues found across any enabled repo. Nothing to do."
    release_lock
    exit 0
  fi

  local num title body branch slug has_ci max_attempts label
  num=$(echo "$found_issue"   | jq -r '.number')
  title=$(echo "$found_issue" | jq -r '.title')
  body=$(echo "$found_issue"  | jq -r '.body')
  branch="issue-${num}"
  slug=$(repo_slug "$found_repo")
  has_ci=$(repo_field "$found_repo" "has_ci")
  max_attempts=$(repo_field "$found_repo" "max_attempts")
  max_attempts="${max_attempts:-3}"
  label=$(repo_field "$found_repo" "in_progress_label")
  label="${label:-in-progress}"

  local default_branch
  default_branch=$(repo_field "$found_repo" "default_branch")
  default_branch="${default_branch:-main}"

  log "Picked issue #$num from $found_repo: $title (default branch: $default_branch)"

  gh issue edit "$num" --repo "$found_repo" --add-label "$label"

  # Clone or update workdir for this repo
  local workdir="$WORKDIR_ROOT/$slug"
  if [[ ! -d "$workdir/.git" ]]; then
    gh repo clone "$found_repo" "$workdir"
  fi
  cd "$workdir"
  git fetch origin
  git checkout -B "$branch" "origin/$default_branch"

  model=$(echo "$found_issue" | jq -r '
    .labels[]?.name
    | select(startswith("model:"))
    | split(":")[1]
    | "claude-" + . + "-4-5"
  ' | head -1)
  model="${model:-claude-haiku-4-5-20251001}"

  state_write \
    "goal"           "waiting_for_claude" \
    "repo"           "$found_repo" \
    "issue_number"   "$num" \
    "issue_title"    "$title" \
    "branch"         "$branch" \
    "default_branch" "$default_branch" \
    "run_id"         "" \
    "attempt"        "1" \
    "max_attempts"   "$max_attempts" \
    "has_ci"         "${has_ci:-true}" \
    "model"          "$model"

  # Write prompt file — all dynamic, no hardcoded repo names
  local slug_path="workdir/$slug"
  cat > "$workdir/AGENT_PROMPT.md" <<PROMPT
You are an autonomous coding agent.
Repository: $found_repo
Location: $slug_path (relative to your workspace root)

## Your objective
Issue #$num: $title

$body

## Instructions
- Start by reading CLAUDE.md in the repo root — it contains project
  conventions you must follow.
- Before writing any code, identify the specific files relevant to the
  issue using find, grep, or content_search. Read only those files.
- Make the smallest change that accomplishes the goal. Do not read or
  modify files unrelated to the issue.
- When your changes are complete, stage and commit them:
    git add -A
    git commit -m "Fix #$num: <brief description>"
  Run these from within the repo directory: $slug_path
- Do not push — the orchestrator handles that.
- Do not open a PR — the orchestrator handles that.
- If you are genuinely blocked and cannot proceed, post a comment on
  the issue using the gh tool:
    gh issue comment $num --repo "$found_repo" --body "[AGENT QUESTION] your question here"
  Then stop immediately. Do not write any files to signal this.
  Do not ask questions you could answer by reading the codebase.
- Do not ask questions you could answer by reading the codebase.

## Build verification
You do not have a local build environment for this project. After
committing your changes you are done. The orchestrator will push your
branch and GitHub Actions will verify the build on a macOS runner. If
the build fails you will be given the compiler errors and asked to fix
them.

## Token efficiency — follow these rules strictly
- Always prefer local search over fetching remote URLs.
  The repo is already cloned locally — use grep, find, and
  content_search instead of web_fetch or web_search wherever possible.
- Never read an entire file speculatively. Use grep or content_search
  to locate relevant sections first, then read only what you need.
- Keep your responses between tool calls brief — do not narrate your
  findings at length. Decide your next action and take it immediately.
- Only explore files directly relevant to the issue. Do not read the
  entire codebase to build general familiarity.
- For third party library APIs, search local files before going to
  the web. If a library is not available locally, clone it to
  workdir/deps/<library-name> for searching, then remove it when done.
  Only fall back to web search if a local search is not possible.
PROMPT

  notify "starting work on $found_repo issue #$num: $title"

  do_invoke_claude
}

# ─── Goal: waiting_for_claude ─────────────────────────────────────────────────
do_invoke_claude() {
  local repo num branch attempt slug workdir model issue_title
  repo=$(state_read "repo")
  num=$(state_read "issue_number")
  branch=$(state_read "branch")
  attempt=$(state_read "attempt")
  slug=$(repo_slug "$repo")
  workdir="$WORKDIR_ROOT/$slug"
  model=$(state_read "model")
  model="${model:-claude-haiku-4-5-20251001}"
  issue_title=$(state_read "issue_title")

  log "Invoking ZeroClaw on $repo issue #$num (attempt $attempt, model $model)..."

  cd "$workdir"
  git checkout "$branch"

  zeroclaw agent \
    --model "$model" \
    -m "$(cat "$workdir/AGENT_PROMPT.md")" \
    >> "$LOG_FILE" 2>&1 || true

  # Check if agent posted a question on the issue
  local agent_question
  agent_question=$(gh issue view "$num" \
    --repo "$repo" \
    --comments \
    --json comments \
    --jq '[.comments[] | select(.body | startswith("[AGENT QUESTION]"))] | last | .body // empty' \
    2>/dev/null || true)

  if [[ -n "$agent_question" ]]; then
    local issue_url="https://github.com/$repo/issues/$num"
    log "Agent posted a question on issue #$num"
    state_write "goal" "waiting_for_answer"
    release_lock
    notify "the agent has a question on $repo issue #$num. Please reply at $issue_url"
    exit 0
  fi

  # Check if agent actually committed anything
  local default_branch commits_ahead
  default_branch=$(state_read "default_branch")
  default_branch="${default_branch:-main}"
  commits_ahead=$(git rev-list --count "origin/$default_branch..HEAD")

  if [[ "$commits_ahead" -eq 0 ]]; then
    log "No commits on branch $branch — agent did not make changes"
    notify "the agent finished on $repo issue #$num but made no commits. The issue may need a clearer description or manual attention."
    local label
    label=$(repo_field "$repo" "in_progress_label")
    label="${label:-in-progress}"
    gh issue edit "$num" --repo "$repo" --remove-label "$label"
    state_write \
      "goal"         "looking_for_work" \
      "issue_number" "" \
      "repo"         "" \
      "branch"       "" \
      "run_id"       ""
    release_lock
    exit 0
  fi

  git push --force origin "$branch"

  local pr_exists
  pr_exists=$(gh pr list \
    --repo "$repo" \
    --head "$branch" \
    --json number \
    --jq 'length')

  if [[ "$pr_exists" -eq 0 ]]; then
    gh pr create \
      --repo "$repo" \
      --title "Fix #$num: $issue_title" \
      --body "Automated fix for issue #$num by coding-agent (attempt $attempt)." \
      --head "$branch" \
      --base "$default_branch"
    log "PR created for $repo branch $branch"
  else
    log "PR already exists — force push triggered a new Actions run"
  fi

  local has_ci
  has_ci=$(state_read "has_ci")

  if [[ "$has_ci" == "true" ]]; then
    state_write "goal" "waiting_on_build"
    do_poll_build
  else
    do_build_passed
  fi
}
# ─── Goal: waiting_for_answer ─────────────────────────────────────────────────
do_resume_after_answer() {
  local repo num slug workdir label model branch
  repo=$(state_read "repo")
  num=$(state_read "issue_number")
  slug=$(repo_slug "$repo")
  workdir="$WORKDIR_ROOT/$slug"
  label=$(repo_field "$repo" "in_progress_label")
  label="${label:-in-progress}"
  model=$(state_read "model")
  model="${model:-claude-haiku-4-5-20251001}"
  branch=$(state_read "branch")

  log "Checking for answer on $repo issue #$num..."

  # Fetch all comments
  local comments
  comments=$(gh issue view "$num" \
    --repo "$repo" \
    --comments \
    --json comments \
    --jq '.comments' \
    2>/dev/null || true)

  if [[ -z "$comments" || "$comments" == "null" || "$comments" == "[]" ]]; then
    log "No comments found yet. Waiting."
    release_lock
    exit 0
  fi

  # Find last agent question, check for human replies, build Q&A thread — all in one pass
  local qa_result
  qa_result=$(echo "$comments" | jq -r '
    . as $all
    | (to_entries
       | map(select(.value.body | startswith("[AGENT QUESTION]")))
       | last
       | .key) as $idx
    | if $idx == null then "NO_QUESTION"
      else
        $all[$idx+1:]
        | map(select(.body | startswith("[AGENT QUESTION]") | not))
        | if length == 0 then "NO_ANSWER"
          else
            $all[$idx:]
            | map(
                if .body | startswith("[AGENT QUESTION]") then
                  "AGENT QUESTION:\n" + (.body | ltrimstr("[AGENT QUESTION] "))
                else
                  "HUMAN ANSWER:\n" + .body
                end
              )
            | join("\n\n")
          end
      end
  ')

  case "$qa_result" in
    NO_QUESTION)
      log "No agent question found in comments. Resetting to looking_for_work."
      state_write "goal" "looking_for_work"
      release_lock
      exit 0
      ;;
    NO_ANSWER)
      log "No human reply yet on issue #$num. Waiting."
      release_lock
      exit 0
      ;;
  esac

  # We have a Q&A thread — build resume prompt
  log "Answer received on issue #$num — building resume prompt"

  local original_prompt
  original_prompt=$(cat "$workdir/AGENT_PROMPT.md")

  cat > "$workdir/RESUME_PROMPT.md" <<PROMPT
$original_prompt

---

## Questions and answers

The following exchange took place on the GitHub issue while you were
working. Please continue your work taking these answers into account.

$qa_result

Please continue implementing the fix for issue #$num.
PROMPT

  state_write "goal" "waiting_for_claude"
  notify "resuming work on $repo issue #$num after receiving an answer. Check the issue for context: https://github.com/$repo/issues/$num"

  zeroclaw agent \
    --model "$model" \
    -m "$(cat "$workdir/RESUME_PROMPT.md")" \
    >> "$LOG_FILE" 2>&1 || true

  # Check for commits
  local default_branch commits_ahead
  default_branch=$(state_read "default_branch")
  default_branch="${default_branch:-main}"
  commits_ahead=$(git -C "$workdir" rev-list --count "origin/$default_branch..HEAD")

  if [[ "$commits_ahead" -eq 0 ]]; then
    log "No commits after resume on $repo issue #$num"
    notify "the agent resumed on $repo issue #$num but made no commits. Manual attention needed."
    gh issue edit "$num" --repo "$repo" --remove-label "$label"
    state_write \
      "goal"         "intervention_required" \
      "issue_number" "" \
      "repo"         "" \
      "branch"       "" \
      "run_id"       ""
    release_lock
    exit 1
  fi

  git -C "$workdir" push --force origin "$branch"

  local pr_exists
  pr_exists=$(gh pr list \
    --repo "$repo" \
    --head "$branch" \
    --json number \
    --jq 'length')

  if [[ "$pr_exists" -eq 0 ]]; then
    gh pr create \
      --repo "$repo" \
      --title "Fix #$num: $(state_read 'issue_title')" \
      --body "Automated fix for issue #$num by coding-agent." \
      --head "$branch" \
      --base "$default_branch"
    log "PR created for $repo branch $branch"
  else
    log "PR already exists — force push triggered a new Actions run"
  fi

  local has_ci
  has_ci=$(state_read "has_ci")

  if [[ "$has_ci" == "true" ]]; then
    state_write "goal" "waiting_on_build"
    do_poll_build
  else
    do_build_passed
  fi
}
# ─── Goal: waiting_on_build ───────────────────────────────────────────────────
do_poll_build() {
  local repo branch num run_id
  repo=$(state_read "repo")
  branch=$(state_read "branch")
  num=$(state_read "issue_number")
  run_id=$(state_read "run_id")

  log "Checking Actions build for $repo branch $branch..."
  sleep 10

  # Find run ID if we don't have one yet
  if [[ -z "$run_id" ]]; then
    run_id=$(gh run list \
      --repo "$repo" \
      --branch "$branch" \
      --json databaseId,createdAt \
      --jq 'sort_by(.createdAt) | last | .databaseId // empty' 2>/dev/null || true)

    if [[ -z "$run_id" ]]; then
      log "No Actions run found yet for $repo branch $branch. Will retry next cron."
      state_write "goal" "waiting_on_build"
      release_lock
      exit 0
    fi

    state_write "run_id" "$run_id"
  fi

  log "Checking run ID $run_id..."

  local conclusion
  conclusion=$(gh run view "$run_id" \
    --repo "$repo" \
    --json conclusion \
    --jq '.conclusion // empty' 2>/dev/null || true)

  if [[ -z "$conclusion" || "$conclusion" == "null" ]]; then
    log "Run $run_id still in progress. Will check again next cron."
    state_write "goal" "waiting_on_build"
    release_lock
    exit 0
  fi

  log "Run $run_id concluded: $conclusion"

  if [[ "$conclusion" == "success" ]]; then
    do_build_passed
  else
    do_build_failed
  fi
}
# ─── Build passed ─────────────────────────────────────────────────────────────
do_build_passed() {
  local repo num branch pr_url
  repo=$(state_read "repo")
  num=$(state_read "issue_number")
  branch=$(state_read "branch")

  pr_url=$(gh pr list \
    --repo "$repo" \
    --head "$branch" \
    --json url \
    --jq 'first | .url // empty' 2>/dev/null || true)

  log "Build passed for $repo issue #$num"
  notify "the build passed for $repo issue #$num: $(state_read 'issue_title'). The PR is ready for your review: $pr_url"

  state_write "goal" "waiting_on_approval"
  release_lock
}

# ─── Build failed ─────────────────────────────────────────────────────────────
do_build_failed() {
  local repo num attempt max_attempts run_id slug workdir label
  repo=$(state_read "repo")
  num=$(state_read "issue_number")
  attempt=$(state_read "attempt")
  max_attempts=$(state_read "max_attempts")
  run_id=$(state_read "run_id")
  slug=$(repo_slug "$repo")
  workdir="$WORKDIR_ROOT/$slug"

  log "Build failed on attempt $attempt of $max_attempts for $repo issue #$num"

  if [[ "$attempt" -ge "$max_attempts" ]]; then
    log "Max attempts reached. Giving up on $repo issue #$num."
    notify "the build failed $max_attempts times on $repo issue #$num: $(state_read 'issue_title'). Giving up — manual intervention required. Failed run: https://github.com/$repo/actions/runs/$run_id"
    label=$(repo_field "$repo" "in_progress_label")
    label="${label:-in-progress}"
    gh issue edit "$num" --repo "$repo" --remove-label "$label"
    state_write \
      "goal"         "intervention_required" \
      "issue_number" "" \
      "repo"         "" \
      "branch"       "" \
      "run_id"       ""
    release_lock
    exit 1
  fi

  log "Fetching failed build log..."
  local build_log
  build_log=$(gh run view "$run_id" \
    --repo "$repo" \
    --log-failed 2>/dev/null \
    | grep -A 10 "error:" \
    | head -100 \
    || echo "(could not retrieve build log)")

  cat >> "$workdir/AGENT_PROMPT.md" <<FIXPROMPT

---

## Build failure — attempt $attempt

Your previous changes caused a build failure. Compiler errors:

\`\`\`
$build_log
\`\`\`

Fix these errors and amend your commit.
FIXPROMPT

  local next_attempt=$((attempt + 1))
  state_write \
    "goal"    "waiting_for_claude" \
    "attempt" "$next_attempt" \
    "run_id"  ""

  notify "the build failed on $repo issue #$num (attempt $attempt of $max_attempts). Retrying with compiler errors as context."

  do_invoke_claude
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  log "─── Cron fired (PID $$) ───────────────────────────────"

  if [[ ! -f "$STATE_FILE" ]]; then
    log "No state file found — initialising"
    state_init
  fi

  check_lock

  local goal
  goal=$(state_read "goal")
  log "State: unlocked | Goal: $goal"

  acquire_lock

  case "$goal" in
    looking_for_work)
      do_find_issue
      ;;
    waiting_for_claude)
      do_invoke_claude
      ;;
    waiting_for_answer)
      do_resume_after_answer
      ;;
    waiting_on_build)
      do_poll_build
      ;;
    waiting_on_approval)
      local repo branch issue_number label
      repo=$(state_read "repo")
      branch=$(state_read "branch")
      issue_number=$(state_read "issue_number")
      label=$(repo_field "$repo" "in_progress_label")
      label="${label:-in-progress}"

      local pr_state
      pr_state=$(gh pr list \
        --repo "$repo" \
        --head "$branch" \
        --state all \
        --json state,mergedAt \
        --jq 'first | .state // empty' 2>/dev/null || true)

      if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
        log "PR for issue #$issue_number was $pr_state — resetting to looking_for_work"
        gh issue edit "$issue_number" --repo "$repo" --remove-label "$label" 2>/dev/null || true
        gh issue close "$issue_number" --repo "$repo" 2>/dev/null || true
        state_write \
          "goal"         "looking_for_work" \
          "repo"         "" \
          "issue_number" "" \
          "issue_title"  "" \
          "branch"       "" \
          "run_id"       "" \
          "attempt"      "0"
        notify "PR for $repo issue #$issue_number was $pr_state — moving on to next issue."
      else
        log "PR for issue #$issue_number still open. Waiting for merge or close."
      fi
      release_lock
      ;;
    intervention_required)
      log "Manual intervention required. Run agent-reset to clear."
      notify "the agent is still in intervention_required state. Run agent-reset on the Pi to clear."
      release_lock
      ;;
    *)
      log "Unknown goal '$goal' — resetting to looking_for_work"
      state_write "goal" "looking_for_work"
      release_lock
      ;;
  esac

  log "─── Done ───────────────────────────────────────────────"
}

main "$@"
