# bakery

An autonomous coding agent that runs on a Raspberry Pi. It monitors GitHub repositories for open issues, implements fixes using the Claude API via ZeroClaw, and opens pull requests — with GitHub Actions providing build verification and Telegram delivering human-in-the-loop notifications. Many of the design choices were a result of the hardware that it was being developed on. The Raspberry Pi 1 model B was released in 2012 and sports a 700mhz ARMV6 processor with 512 GB RAM. 

## How it works

A systemd timer fires every 30 minutes and runs the orchestrator. The orchestrator maintains a JSON state file that acts as a persistent state machine — each invocation reads the current state, does one unit of work, updates the state, and exits. This means no long-running processes, no memory pressure, and clean resumability after reboots or failures.

The agent progresses through the following states:

- `looking_for_work` — polls all enabled repos for open issues without the `in-progress` label, picks the oldest one across all repos
- `waiting_for_claude` — invokes ZeroClaw with the issue as the prompt; ZeroClaw reads the codebase, implements a fix, and commits
- `waiting_on_build` — checks the GitHub Actions build status once per cron invocation; if the build fails, appends the compiler errors to the prompt and retries
- `waiting_on_approval` — polls the PR for merge or close; detects `[FEEDBACK]` comments and re-invokes ZeroClaw with your feedback as additional context
- `waiting_for_answer` — the agent posted an `[AGENT QUESTION]` comment on the issue; waits for a human reply before resuming
- `intervention_required` — something went wrong that requires manual attention

## Architecture

```
systemd timer (every 30 min)
  └── orchestrator.sh        # bash state machine
        ├── gh CLI            # GitHub API — issues, PRs, Actions
        ├── ZeroClaw          # AI agent loop (Claude API)
        │     └── git         # commits changes to the repo
        └── Telegram          # notifications and Q&A
```

ZeroClaw handles all AI reasoning — reading files, writing code, running git commands. The orchestrator handles everything else: issue selection, locking, state transitions, build polling, and human communication.

## Requirements

- Raspberry Pi (tested on Pi 1B and Pi 4)
- [ZeroClaw](https://github.com/absolutscottie/zeroclaw) with Anthropic and Telegram configured
- `gh` CLI authenticated with a GitHub PAT
- `jq`
- A GitHub PAT with `contents`, `issues`, `pull-requests`, and `actions` read/write permissions

## Repository configuration

Repos the agent can work on are defined in `repos.json`:

```json
[
  {
    "repo": "owner/repo-name",
    "enabled": true,
    "in_progress_label": "in-progress",
    "max_attempts": 3,
    "has_ci": true,
    "default_branch": "main"
  }
]
```

Set `has_ci: false` for repos without a GitHub Actions build workflow — the agent will skip build polling and go straight to `waiting_on_approval`.

## GitHub setup

For each repo in `repos.json`:

1. Create an `in-progress` label (the agent applies this when it picks up an issue)
2. Optionally create `model:sonnet` and `model:opus` labels — apply these to issues that need more capable models than the default (Haiku)
3. For repos with `has_ci: true`, add a GitHub Actions workflow that builds on push and PR

## Model selection

The agent defaults to `claude-haiku-4-5-20251001`. To use a more capable model for a specific issue, add a label before the agent picks it up:

- `model:sonnet` → `claude-sonnet-4-20250514`
- `model:opus` → `claude-opus-4-20250514`

This is useful for issues that require significant research or involve complex codebases.

## Human interaction

The agent communicates with you through GitHub and Telegram:

**Questions** — if the agent is genuinely blocked, it posts a comment on the issue prefixed with `[AGENT QUESTION]` and sends you a Telegram notification with a link. Reply on the issue and the next cron invocation will resume with your answer as context.

**Feedback** — if you review a PR and want changes, leave a comment prefixed with `[FEEDBACK]`. The agent will pick it up on the next cron invocation, re-invoke ZeroClaw with your feedback appended, and force-push an updated commit.

**Notifications** — the agent sends Telegram messages when it starts work on an issue, when a build passes and the PR is ready to review, when it hits a dead lock, and when it gives up after exhausting retries.

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/absolutscottie/coding-agent ~/coding-agent

# 2. Install dependencies
sudo apt install gh jq -y
echo "YOUR_GITHUB_PAT" | gh auth login --with-token
gh auth setup-git

# 3. Configure environment
cp env.example ~/coding-agent/env
vi ~/coding-agent/env          # add tokens
chmod 600 ~/coding-agent/env

# 4. Configure repos
vi ~/coding-agent/repos.json   # add your repos

# 5. Install systemd units
mkdir -p ~/.config/systemd/user
cp systemd/coding-agent.service ~/.config/systemd/user/
cp systemd/coding-agent.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now coding-agent.timer

# 6. Run once manually to verify
bash ~/coding-agent/orchestrator.sh
```

## Files

```
coding-agent/
├── orchestrator.sh       # main state machine
├── agent-reset           # manually reset state to looking_for_work
├── repos.json            # list of repos to work on
├── env                   # environment variables (not committed)
├── env.example           # template
├── state.json            # runtime state (not committed)
├── agent.log             # runtime log (not committed)
├── sessions/             # ZeroClaw session state per issue (not committed)
└── systemd/
    ├── coding-agent.service
    └── coding-agent.timer
```

## Operations

```bash
# Watch the log live
tail -f ~/coding-agent/agent.log

# Check current state
cat ~/coding-agent/state.json | jq .

# Trigger a run immediately
systemctl --user start coding-agent.service

# Pause the agent
systemctl --user stop coding-agent.timer

# Resume
systemctl --user start coding-agent.timer

# Reset after intervention_required
~/coding-agent/agent-reset
```

## Known limitations

- The agent cannot build or run code locally — build verification requires GitHub Actions on a platform-appropriate runner (e.g. macOS for Swift projects)
- ZeroClaw's workspace security policy restricts file access to its workspace directory — repos must be cloned inside that directory
- Session state across cron invocations requires ZeroClaw's `--session-state-file` option with `-m` support (available from [this fix](https://github.com/absolutscottie/zeroclaw/pulls))
