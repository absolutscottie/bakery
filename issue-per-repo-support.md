# Plan: Issue-Per-Repo Support

## Overview

Enable the coding agent to work on multiple issues concurrently while maintaining the constraint that each repository can only have one open PR at a time. This allows the agent to remain productive while waiting for human feedback or PR approval on completed work.

## Current Architecture Limitations

The current state machine is designed around a single global workflow:
- Single `state.json` tracks one issue at a time
- States like `waiting_on_approval` block all progress until the current PR is merged/closed
- The agent polls the same PR repeatedly instead of moving to other work
- Session state is stored per-issue but only one session is active at a time

## Proposed Architecture Changes

### 1. Per-Repo State Tracking

**Current:** Single global `state.json` with one active issue across all repos.

**Proposed:** Maintain per-repo state files that track independent workflows.

```json
// state/<repo-slug>.json
{
  "repo": "absolutscottie/bakery",
  "state": "locked|unlocked",
  "goal": "looking_for_work|waiting_for_claude|waiting_on_build|waiting_on_approval|waiting_for_answer|intervention_required",
  "issue_number": "4",
  "issue_title": "Improve agent productivity",
  "branch": "issue-4",
  "default_branch": "main",
  "model": "claude-sonnet-4-5",
  "run_id": "",
  "attempt": "1",
  "max_attempts": "3",
  "has_ci": "true",
  "pr_number": "5",
  "updated_at": "2026-04-06T22:00:00Z",
  "pid": ""
}
```

**Benefits:**
- Each repo progresses independently
- Agent can work on repo A while waiting for approval on repo B
- Natural parallelism without complex coordination

### 2. Modified State Machine Flow

**Current flow:**
```
looking_for_work → waiting_for_claude → waiting_on_build → waiting_on_approval
     ↑                                                              |
     └──────────────────────────────────────────────────────────────┘
```

**New flow per repo:**
```
looking_for_work → waiting_for_claude → waiting_on_build → waiting_on_approval
     ↑                    ↓                   ↓                      |
     |            waiting_for_answer    (build failures)             |
     |                    ↓                   ↓                      |
     └────────────────────┴───────────────────┴──────────────────────┘
```

**Key change:** `waiting_on_approval` is now a terminal state for that repo until the PR is acted upon. The orchestrator doesn't block on it — it moves to other repos.

### 3. Orchestrator Main Loop Changes

**Current:**
1. Read global state
2. Execute one action for current goal
3. Update global state
4. Exit

**Proposed:**
1. Iterate through all enabled repos
2. For each repo:
   - Read repo-specific state file
   - Check lock (per-repo)
   - Execute one action based on repo's goal
   - Update repo-specific state
3. Exit

**Constraint enforcement:**
- Before transitioning to `looking_for_work`, check if repo already has an open PR
- If PR exists, remain in `waiting_on_approval` (or skip that repo in the main loop)
- Only search for new issues in repos without active PRs

### 4. Session Management

**Current:** `sessions/issue-{number}.json`

**Proposed:** `sessions/{repo-slug}-issue-{number}.json`

This prevents session file collisions when multiple repos have issues with the same number.

### 5. Lock Management

**Current:** Global lock prevents any concurrent orchestrator runs.

**Proposed:** Per-repo locks allow parallel processing of different repos.

**Implementation:**
- Lock file per repo: `locks/{repo-slug}.lock`
- Check/acquire/release locks per repo
- Dead lock detection remains the same but scoped per repo
- Main orchestrator can work on repo A while repo B is locked by a previous run

### 6. PR State Checking

**New function:** `has_open_pr(repo)`
- Returns true if repo has any open PR created by the agent
- Used before `looking_for_work` to enforce one-PR-per-repo constraint
- Checks PR author matches the GitHub PAT user

### 7. Notification Strategy

**Current:** Notifications are sent for each state transition.

**Proposed:** Batch notifications or use priority levels:
- **High priority:** Build failures, agent questions, intervention required
- **Normal priority:** PR ready for review
- **Low priority:** Started work on issue
- Consider daily digest for low-priority events

## Implementation Tasks

The following GitHub issues should be created to implement this plan:

### Issue 1: Refactor state management to per-repo files
**Description:**
- Create `state/` directory for per-repo state files
- Modify `state_read()` and `state_write()` functions to accept repo parameter
- Update `state_init()` to create per-repo state files
- Migrate existing `state.json` to new format (migration script)
- Update all state reads/writes throughout orchestrator to use new functions

**Success criteria:**
- Each enabled repo has its own state file
- State transitions work independently per repo
- Backward compatibility maintained during migration

### Issue 2: Implement per-repo locking mechanism
**Description:**
- Create `locks/` directory for lock files
- Modify `acquire_lock()`, `release_lock()`, and `check_lock()` to be repo-scoped
- Update dead lock detection to work per repo
- Ensure orchestrator can process multiple repos in single run if unlocked

**Success criteria:**
- Locks prevent concurrent work on same repo
- Locks don't block work on different repos
- Dead lock detection works per repo

### Issue 3: Add PR existence check to looking_for_work
**Description:**
- Implement `has_open_pr(repo)` function using `gh pr list`
- Filter PR list to only agent-created PRs (by author)
- Modify `do_find_issue()` to skip repos with open PRs
- Add logging for skipped repos

**Success criteria:**
- Agent never picks up new issue if repo has open PR
- Repos without PRs are still eligible for work
- Clear logging when repos are skipped

### Issue 4: Update orchestrator main loop for multi-repo processing
**Description:**
- Modify `main()` function to iterate through all enabled repos
- Process each repo's state independently
- Handle per-repo locks correctly
- Ensure proper error isolation (one repo failure doesn't stop others)

**Success criteria:**
- Orchestrator processes all repos in single run
- Each repo advances independently
- Failures in one repo don't affect others

### Issue 5: Refactor session file naming to include repo slug
**Description:**
- Change session file pattern from `issue-{number}.json` to `{repo-slug}-issue-{number}.json`
- Update all session file references in orchestrator
- Add migration for existing session files
- Clean up old session files when PRs are merged/closed

**Success criteria:**
- No session file collisions between repos
- Existing sessions continue to work
- Session cleanup works correctly

### Issue 6: Update notification strategy for multi-repo context
**Description:**
- Add repo context to all notifications
- Implement notification batching or priority levels
- Consider daily digest for low-priority events
- Update notification messages to be clear about which repo/issue

**Success criteria:**
- Notifications clearly identify repo and issue
- No notification spam when working on multiple repos
- Critical notifications still sent immediately

### Issue 7: Add waiting_on_approval polling optimization
**Description:**
- Modify `waiting_on_approval` to check for `[FEEDBACK]` comments
- If feedback found, transition back to `waiting_for_claude` with feedback context
- Otherwise, check PR state (merged/closed) and transition to `looking_for_work`
- Ensure this doesn't block other repos from being processed

**Success criteria:**
- Agent responds to feedback comments
- Agent detects merged/closed PRs and moves on
- Polling doesn't block work on other repos

### Issue 8: Add integration tests for multi-repo scenarios
**Description:**
- Create test scenarios with multiple repos
- Test concurrent issue processing
- Test PR constraint enforcement
- Test state isolation between repos
- Test recovery from failures

**Success criteria:**
- All multi-repo scenarios pass
- No race conditions detected
- State isolation verified

### Issue 9: Update documentation for multi-repo support
**Description:**
- Update README.md with new architecture
- Document per-repo state files
- Update operational procedures
- Add troubleshooting section for multi-repo issues
- Update file structure documentation

**Success criteria:**
- Documentation reflects new architecture
- Clear operational guidance provided
- Troubleshooting covers common scenarios

## Future Enhancements (Not in Scope)

These are potential future improvements that build on this foundation:

1. **Issue dependency tracking:** Parse issue descriptions for "depends on #X" and respect dependencies
2. **Priority-based issue selection:** Allow labeling issues with priority levels
3. **Parallel builds:** If CI allows, work on multiple issues in same repo on different branches
4. **Smart model selection:** Automatically upgrade to more capable models after failures
5. **Feedback learning:** Track which types of issues succeed/fail and adjust strategy

## Migration Strategy

1. Deploy issues 1-2 first (state and locking refactor) — these are foundational
2. Test with single repo to ensure backward compatibility
3. Deploy issue 3 (PR check) to enforce constraint
4. Deploy issue 4 (main loop) to enable multi-repo processing
5. Deploy issues 5-7 (session naming, notifications, polling) for polish
6. Deploy issues 8-9 (tests and docs) to validate and document

## Rollback Plan

If issues arise after deployment:
- Per-repo state files can be consolidated back to single `state.json`
- Lock mechanism can be reverted to global lock
- Main loop can be simplified to process single repo per run
- Session files can be renamed back to original format

## Success Metrics

After implementation, the agent should:
- Work on multiple repos concurrently (observable in logs)
- Maintain one-PR-per-repo constraint (verifiable via GitHub API)
- Reduce idle time when waiting for PR approval (measurable via state transitions)
- Complete more issues per day (tracked via closed issues)
- Respond to feedback faster (tracked via time between feedback and updated PR)
