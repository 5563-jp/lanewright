日本語: [README.md](README.md)

> Note: Detailed reference documents under `docs/*.md` are currently available in Japanese only.

# lanewright — Run AI Coding CLIs in Parallel "Lanes" on macOS

A toolkit for running multiple AI coding CLIs installed on macOS—Claude Code, Codex, and Gemini (Antigravity CLI `agy`)—in parallel as independent **lanes** (1 task = 1 worktree = 1 launcher), safely managing the flow from implementation to code review to PR (pull request).

- **worktree**: A separate working directory checked out from the same Git repository so each branch can be worked on independently in parallel.
- **launcher**: A wrapper script that handles pre-flight checks, logging, and process lifecycle tracking (`logs/<label>.pid` and `logs/<label>.done`).

## Safety and disclaimer

- **Automated write and shell access**: This toolkit runs AI coding agents automatically with write permissions to the target worktree and shell execution capabilities.
- **Review restrictions are not a complete sandbox**: The review lane's read-only restrictions and command deny-lists are not a full OS-level sandbox and rely in part on post-execution detection (checking whether the working tree changed after the run). Pushes are blocked by disabling git networking in review children.
- **Your global instruction files apply to lanes too**: MCP is disabled, but instruction files such as `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and the instructions under `~/.gemini/` are still loaded by the lane agents (see "Your global settings apply to lanes too" below).
- **Never use near production**: Do not run this toolkit in any environment that has access to production API keys, production credentials, production databases, or production deployment targets.
- **Verification runs AI-written code outside the sandbox**: `run-gemini.sh --verify`, `chk-run.sh` (`LANES_CHECK_CMD` / `.lanes/check.sh`), and post-merge dependency installs (such as `npm ci`) execute code the AI wrote or changed (`package.json` scripts, tests, `.lanes/check.sh` itself, and so on) with the launcher's own permissions. The sandbox only protects you while the AI itself is running. Also, `.lanes/check.sh` lives inside the worktree and takes precedence over `LANES_CHECK_CMD`, so if a lane's diff changes `.lanes/check.sh`, always inspect it during review (a script reduced to `exit 0` would silently pass the final check).
- **No warranty / at your own risk (MIT)**: This software is provided "AS IS", without warranty of any kind, under the [MIT License](LICENSE). You are solely responsible for any actions taken by the agents and scripts.
- **Comply with AI service terms**: Use this toolkit in compliance with the terms of service and usage policies of each AI provider you use (Anthropic Claude, OpenAI ChatGPT / Codex, Google Gemini / Antigravity).
- **Unofficial / no affiliation**: This project is an independent open-source toolkit and is not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, Google, or GitHub. All product names, logos, and trademarks are the property of their respective owners.
- **macOS & zsh only / best-effort**: This toolkit only supports macOS and `zsh`. Changes in the CLI flags or output formats of the underlying AI tools may break functionality at any time. It is provided as-is with no promise of support or maintenance.
- **Reporting vulnerabilities**: See [SECURITY.md](SECURITY.md) (do not report security issues in public Issues).

## Why use it

- **Fast in parallel**: Split a goal into small tasks that touch non-overlapping files and run them all simultaneously.
- **Know immediately when something stalls**: Every lane writes `logs/<label>.pid` (start record) and `logs/<label>.done` (completion record).
  `lanes-status.sh` returns a single-line status: `RUNNING` / `STALLED` / `DONE` / `FAILED` / `DEAD`.
- **Reviews cannot be skipped**: A separate lane reviews the changes in read-only mode and decides using the final line `VERDICT: CLEAN` (no issues) or `VERDICT: NEEDS_FIX` (changes required).
  Truncated output or vague prose is never treated as `CLEAN`.
- **No repeated checks**: From the second round on, reviews look only at what changed since the last clean review (`--mode auto` for both Codex and Claude reviews). If the parent already passed the check command (`chk-run.sh`) on the same content, the review reuses that record instead of rerunning typecheck, lint, and unit tests (`LANES_REVIEW_REUSE_CHECKS`).
- **Fewer accidents by design**: Launchers only start with subscription logins—never API keys. MCP (external service connections for AI) is disabled across all lanes.
  Duplicate runs with the same `label` are rejected. Post-merge cleanup stops if uncommitted changes remain.
- **Flexible tool combinations**: Works with Claude alone. Adding Codex or Gemini automatically assigns implementation and review roles ([docs/roles.md](docs/roles.md), in Japanese).

## Overall workflow

```
 Commander (an external bot such as Grok Bot, or a Claude Desktop Code tab)
   │  Splits the goal into small lanes that touch non-overlapping files
   ▼
 git worktree add ... → write task prompt (prompt.md)
   │
   ├─▶ run-impl.sh  ── Implementation lane (Claude / Gemini) ── commit
   │        │ Check liveness within 60s via lanes-status.sh
   │        ▼ DONE
   ├─▶ run-review.sh ── Review lane (Codex, or a separate read-only Claude session)
   │        │ VERDICT: NEEDS_FIX → fix in implementation lane → re-review
   │        ▼ VERDICT: CLEAN
   ├─▶ Final verification (chk-run.sh) → Create PR (paste evidence.md into the PR body)
   │        ▼
   │    GitHub auto-merge (GitHub merges once CI passes)
   │        ▼
   └─▶ cleanup-after-merge.sh cleans up the worktree and branch
 In parallel: lanes-watch.sh checks all lanes every 5 minutes and wakes the commander with WAKE: on changes
```

## Prerequisites

- macOS (uses `sandbox-exec`, `osascript`, etc.)
- `zsh` (macOS default shell), `git`, `python3`
- `gh` (official GitHub CLI, used for PR creation and auto-merge; optional)
- shellcheck and pyflakes (static checks in the self-test; optional — if missing, only those checks are skipped)
- Node.js (with npm): required only by the self-test (`selftest.sh`), because `lanes/tests/test-chk-run.sh` uses npm to run example check commands. Without it, that test fails with an explanation (the kit itself does not need Node.js)
- The AI CLIs you plan to use (at least Claude Code). Install them following each official documentation guide:
  - Claude Code (Anthropic official docs)
  - Codex CLI (OpenAI official docs)
  - Antigravity CLI `agy` (Google official docs)
  - GitHub CLI `gh` (GitHub official docs)

### Verify subscription login

Launchers **only start with subscription logins**. Even if API keys are present in environment variables, the launchers unset them before starting. Endpoint overrides (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`) are removed too, so even if your commander shell points at a local model or a proxy, lanes connect to the official subscription endpoints (running the lanes themselves on a local model is not supported; Codex's `model_provider` in `~/.codex/config.toml` is not an environment variable and cannot be removed this way, so keep it at the default for lanes).
Why: API keys bill pay-as-you-go (which can quickly add up when running many lanes in parallel), leaked API keys carry high risk, and mixing login methods makes it unclear which account ran a lane.

| Tool | How to check | Passing condition |
|---|---|---|
| Claude | `claude auth status` | `loggedIn` is `true` and login method is `claude.ai` (subscription) |
| Codex | `codex login status` | `Logged in using ChatGPT` (ChatGPT subscription) |
| Gemini (`agy`) | Launch `agy` interactively and sign in with your account | Login directory (`~/.gemini/antigravity-cli`) exists |

> Warning: Do not paste the output of these commands into chat or GitHub Issues. Depending on your environment, the output may include sensitive values.

### Permission handling (what the agents may do without asking)

Launchers run the CLIs non-interactively, so the agents cannot ask "may I run this?" mid-run (anything that needs confirmation is denied).
For that reason, **the launchers always pass explicit permissions** instead of relying on your `~/.claude/settings.json` or `~/.codex/config.toml`.

| Lane | What is passed | Default | Config key |
|---|---|---|---|
| Claude implementation | Permission mode (`--permission-mode`) and tools allowed without asking (`--allowedTools`) | `acceptEdits` (edits inside the worktree are accepted) and `Bash,Edit,Write,Read,Glob,Grep,TodoWrite` | `CLAUDE_IMPL_PERMISSION_MODE` / `CLAUDE_IMPL_ALLOWED_TOOLS` |
| Codex implementation (only when explicitly used) | Sandbox (`--sandbox`) | `workspace-write` (can write to the worktree and the scratch area; only the parts of the git directory a commit needs (the worktree gitdir, objects, refs, logs) are added; the shared config and hooks stay read-only. Control files inside the gitdir (such as `commondir` and `config.worktree`) are still writable, so the launcher fingerprints them before and after the run and stops with EXIT:4 without calling git if they changed; network is off) | `CODEX_IMPL_SANDBOX` |
| Codex review | Sandbox (`-c sandbox_mode=...`) | `read-only` | `CODEX_REVIEW_SANDBOX` (`read-only` or `workspace-write` only) |
| Claude review / QA | Tool set, deny-list, and permission mode `manual` | Editing tools removed; history rewrites, PR merges, deploys, etc. denied | `CLAUDE_REVIEW_TOOLS` / `CLAUDE_REVIEW_DENY` |

- By default the Claude implementation lane **can run any shell command (Bash) without asking**, including writes outside the worktree. Never run it where production keys or databases are reachable (see the disclaimer above).
- Review and QA child processes start with git networking (push and fetch) disabled via `GIT_ALLOW_PROTOCOL` (see the section "レビューは読み取り専用" (reviews are read-only) in [lanes/README.md](lanes/README.md), Japanese).
- Setting a key to an empty value omits that flag (your own CLI settings apply). If a Codex implementation needs network access (e.g. installing dependencies), choose `CODEX_IMPL_SANDBOX=danger-full-access` (no sandbox) at your own discretion.

### Your global settings apply to lanes too

The launchers disable MCP and pass explicit permissions, but **each CLI still loads the instruction files it normally reads**.
Trial runs with the real CLIs showed that commit-author and tone instructions in global instruction files were followed by lane agents too.
Examples of what gets loaded (this follows each CLI's own behavior; see each tool's official documentation for details):

| Tool | What also applies inside lanes (examples) |
|---|---|
| Claude | `~/.claude/CLAUDE.md`, the target repository's `CLAUDE.md`, hooks (automatic actions) in `~/.claude/settings.json`, etc. |
| Codex | `~/.codex/AGENTS.md`, the target repository's `AGENTS.md` |
| Gemini (`agy`) | Instruction files under `~/.gemini/` (such as `GEMINI.md`) and the target repository's instruction files |

- Rules about commit authors, trailers, commit message language, tone, or workflow (e.g. "post a plan and wait for approval before implementing") are followed inside lanes too.
- The problematic ones are **instructions that wait for a human reply**. Lanes are non-interactive, so the agent either stalls waiting for approval (`STALLED`) or ends without doing the work.
  Add "in non-interactive lanes, proceed without waiting for approval" to your global instructions, or put it at the top of the task prompt (see the templates in `templates/`).
- To control the commit author, set `git config user.name` / `user.email` in the target repository rather than relying on instruction files.
- If your instruction files contain keys or personal information, that content is passed to lane agents as well.

## Installation

1. Place the kit in any directory you like (for example `/Users/you/tools/lanewright`, referred to below as `<kit>`). **Keep the kit in that directory after installation.**
   With git: `git clone https://github.com/owner/lanewright.git /Users/you/tools/lanewright` (`owner` is the account that publishes it); with a zip: extract `lanewright.zip` there.
2. Run the installer (preview the planned changes with `--dry-run` first):
   ```sh
   cd <kit>
   ./install.sh --dry-run
   ./install.sh
   ```
   What it does: Places symlinks from `skills/` into the skill directories of your installed tools (such as `~/.claude/skills`), and copies `lanes.conf.example` to `~/.config/lanewright/lanes.conf` if it does not exist yet. Any existing file with the same name, or a skill directory that is itself a broken symlink or not a directory, is left untouched with a warning and installation continues.
3. Edit the configuration file `~/.config/lanewright/lanes.conf`. At minimum, check these 3 keys (see the Configuration section below and [docs/config.md](docs/config.md) for all keys):
   > Note: The configuration file is loaded (`source`d) as `zsh` code, so every line in it is executed. Do not place it in a location writable by others, and never point `LANES_CONF` at someone else's or an untrusted file.
   ```sh
   LANES_TOOLS="${LANES_TOOLS:-claude codex}"     # Tools to use
   LANES_COMMANDER="${LANES_COMMANDER:-claude}"   # Commander (an operating label; lanes-doctor.sh shows how to run the watcher)
   LANES_BASE_BRANCH="${LANES_BASE_BRANCH:-develop}"  # Target branch to merge into
   ```
   If you use the final pre-merge check (`chk-run.sh`), also set the check command (a `.lanes/check.sh` script in the target repository takes priority):
   ```sh
   LANES_CHECK_CMD="${LANES_CHECK_CMD:-pnpm lint && pnpm typecheck && pnpm test && pnpm build}"
   ```
4. Pre-flight check: `zsh <kit>/lanes/lanes-doctor.sh`. Lists all missing tools or logins and exits with code 2 (or exits 0 when everything is ready).
   Add the target repository path (`lanes-doctor.sh /Users/you/dev/my-app`) to also check that `logs/` is ignored by git (see the preparation in "Your first lane" below).
   You can inspect the active role assignment with `zsh <kit>/lanes/lanes-roles.sh --print`.
5. Self-test: `zsh <kit>/selftest.sh` (runs the test suite across all 4 tool profiles using stub CLIs in a temporary HOME and prints a results table; never calls real AI services).
   Only tests whose result depends on the profile (marked with a `# selftest: 構成ごと` comment line near the top; currently `test-common-security.sh` and `test-gemini-launcher.sh`) run once per profile; the others run once in the first profile and their result is reused for the other columns (shown with a leading `＝`). Pass `--every-profile` to run every test in every profile.
   **Expect about 10–15 minutes per profile; all 4 profiles take about 15–20 minutes** (40+ minutes with `--every-profile`). To save time, test a single profile with `--profile claude-codex`, and run a single test with `--test lanes/tests/test-roles.sh` (path relative to the kit; may be repeated).
   "N/A" entries (exit code 77) indicate tests for tools not included in that profile, verifying instead that those launchers refuse to start in that profile. "緑(一部)" (partially green) means that in that profile part of the test only verified that a launcher stops; the reasons are listed below the table. If any test fails, it exits with code 1 and prints the log location.
   It also fails if the kit's own repository changes during the run (HEAD, branches, refs including remote-tracking refs and branches checked out in other worktrees, stash, worktrees, file contents, the index, config, `info/`, `objects/info/alternates`, or hooks including subfolders), which would mean a test escaped its temporary repository. Do not edit kit files while the self-test is running.
   It also fails while another task is moving branches or worktrees, or fetching, in the same repository; in that case, run it from a separate clone.
   If `TMPDIR` points inside the kit, the self-test stops with a usage error (exit 2); point `TMPDIR` to a folder outside the kit.
   For pre-publication checks (to scan for your own names, domains, or organizations), you can also pass `LANES_PRIVATE_DENYLIST=/path/to/denylist.txt` (kept outside the kit, 1 pattern per line) to `selftest.sh` or `zsh <kit>/tests/test-no-private.sh`. Before publishing, run it this way to check for denylisted words as well.
6. (Optional) Add to `PATH`: add `export PATH="<kit>/lanes:$PATH"` to `~/.zshrc` so you can call `lanes-status.sh ...` without the path prefix.

## Configuration

All settings live in `~/.config/lanewright/lanes.conf` (or the path in `LANES_CONF`, or `${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf`).
Precedence is **environment variable > config file > default value**.
Because the config file is `source`d directly by `zsh`, every line in it is executed as shell code—do not store it in a directory writable by others, and do not point `LANES_CONF` at someone else's file.

| Key | Default | Description |
|---|---|---|
| `LANES_TOOLS` | `claude` | Space-separated list of tools to use (`claude`, `codex`, `gemini`). `claude` is required. Determines the profile (①–④) |
| `LANES_COMMANDER` | `grok` | Commander mode: `grok` (external bot such as Grok Bot) or `claude` (Claude Desktop Code tab) |
| `LANES_BASE_BRANCH` | `develop` | Base branch where lane branches are merged (set to `main` if you merge directly to `main`) |
| `LANES_RUNS_ROOT` | `$HOME/dev/_runs` | Root directory for lane worktrees (`lanes-watch.sh` scans `logs/*.pid` under this directory) |
| `LANES_SCRATCH_ROOT` | `$LANES_RUNS_ROOT/_scratch` | Per-lane temporary directory (`TMPDIR` / `LANES_SCRATCH`), automatically removed during cleanup |
| `LANES_CHECK_CMD` | empty | Command run by `chk-run.sh` before PR creation (e.g., `pnpm lint && pnpm typecheck && pnpm build`). If `.lanes/check.sh` exists in the repo, that script takes priority |
| `CLAUDE_MODEL` / `CODEX_MODEL` / `GEMINI_MODEL` | empty | Leave empty to use each CLI's default model, or set an explicit model name |
| `CLAUDE_EFFORT` / `CODEX_EFFORT` / `GEMINI_EFFORT` | `xhigh` / `xhigh` / `high` | Reasoning effort passed to each CLI (set to empty `""` to omit `--effort`). An environment variable of the same name overrides the config file; the launcher prints a one-line notice when that happens. Write the value literally (`CLAUDE_EFFORT="xhigh"`) to pin it |
| `LANES_STALL_MINUTES` | `10` | Minutes without output before `lanes-status.sh` reports `STALLED` |
| `LANES_NOTIFY` | `1` | Show a macOS notification when a lane finishes (`0` to disable) |
| `LANES_PROMPT_MAX_BYTES` | `200000` | Maximum prompt file size in bytes (prevents pasting huge diffs into prompts) |
| `LANES_DETACH_QA` | `0` | Set to `1` to make `after-develop-merge.sh` launch QA detached via `detach-run.sh` (for bot shells that kill the whole process group on exit) |

Numeric keys (`LANES_STALL_MINUTES`, `LANES_NOTIFY`, `LANES_PROMPT_MAX_BYTES`, `LANES_DOWNLOADS_SCAN`, `LANES_DETACH_QA`) are validated as integers by `lanes.env` before use; any other value stops with exit 2.
For Claude review / QA, `CLAUDE_REVIEW_TOOLS` must not contain editing tools or sub-agents (the launcher refuses to start), and `CLAUDE_REVIEW_DENY` can only add entries to a fixed deny-list that cannot be removed.

See [docs/config.md](docs/config.md) (in Japanese) for the full list of configuration keys.

## 4 Tool Profiles and Weak Review Independence in ③ and ④

Based on `LANES_TOOLS`, `lanes/lanes-roles.sh` selects one of 4 profiles and routes `run-impl.sh` (implementation) and `run-review.sh` (review) automatically:

| Profile | `LANES_TOOLS` | Implementation | Review | Review independence |
|---|---|---|---|---|
| ① `full` | `claude codex gemini` | Claude and Gemini (~50/50) | Codex | Strong (different tool from a different vendor) |
| ② `claude-codex` | `claude codex` | Claude | Codex | Strong |
| ③ `claude-gemini` | `claude gemini` | Claude and Gemini | Claude (separate read-only session) | **Weak** (`LANES_REVIEW_INDEPENDENT=0`) |
| ④ `claude-only` | `claude` | Claude | Claude (separate read-only session) | **Weak** (`LANES_REVIEW_INDEPENDENT=0`) |

- **Claude is required** in all profiles.
- **Gemini (`agy`)** is used only for lightweight implementation tasks (recommended up to ~6 files / 400 lines with clear specs), never for review. When calling `run-impl.sh --engine gemini`, you must pass `--verify "<command>"` and `--allow-path <relative-path>`.
- **If you are unsure, start with ② (`claude-codex`)** so implementation and review use different tools.

### Why ③ and ④ have weak review independence

In profiles ③ and ④, Claude performs both implementation and review. The kit applies safeguards—running the review in a **separate session** (no shared conversation history), enforcing **read-only** rules and verifying that the worktree is unchanged after the review, and requiring an explicit final-line `VERDICT:`.

However, **the same tool tends to share the same blind spots**, so this is a mitigation rather than a true replacement for cross-tool review. If you use ③ or ④, compensate by:

1. **Stronger human review**: Do not rely solely on unattended auto-merge; read the diff yourself before merging (especially for authentication, billing, or data deletion changes).
2. **Stricter CI and branch protection**: Configure required status checks (typecheck, lint, unit tests, E2E tests) so GitHub blocks merging unless CI is green.
3. **Add Codex when possible**: If you have a ChatGPT subscription, add `codex` to `LANES_TOOLS` to upgrade to profile ② or ①.

See [docs/roles.md](docs/roles.md) (in Japanese) for details on profile differences.

## Two Commander Modes (External Bot / Claude Desktop Code Tab)

The **commander** splits a goal into non-overlapping lanes, launches them, checks status within 60 seconds, and connects `DONE` lanes to the next step (review → PR → cleanup). You can run the commander in two ways (`LANES_COMMANDER`):

1. **External Bot such as Grok Bot (`LANES_COMMANDER=grok`, default)** — [docs/commander-grok.md](docs/commander-grok.md) (in Japanese)
   - An external bot with shell access to your Mac drives the workflow. Lanes keep moving even while you sleep (as long as the Mac is kept awake).
   - Scheduled every 5 minutes: run `zsh <kit>/lanes/lanes-monitor.sh` (one-shot check) or keep a single `zsh <kit>/lanes/lanes-watch.sh` daemon running. When output starts with `WAKE: <reason>`, advance the finished lane; when `QUIET`, do nothing.
   - Scheduled every 10 minutes (`LANES_CHECK_INTERVAL_MIN`): run `zsh <kit>/lanes/lanes-watch.sh --check` to verify the watcher heartbeat and check for newly unblocked parallel tasks.
   - Because short-lived bot shell sessions may terminate child processes when they exit, launch lanes via `detach-run.sh`:
     ```sh
     zsh <kit>/lanes/detach-run.sh ~/dev/_runs/my-app/hello/logs/launch.log \
       zsh <kit>/lanes/run-impl.sh ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello.md hello-impl
     ```

2. **Claude Desktop Code Tab (`LANES_COMMANDER=claude`)** — [docs/commander-claude.md](docs/commander-claude.md) (in Japanese)
   - A Claude Desktop Code tab session on your Mac acts as the commander—no external bot required. The commander session delegates work to lanes rather than editing files itself.
   - Runs `zsh <kit>/lanes/lanes-watch.sh --until-wake` in the background (stays quiet until a state change occurs, then prints `WAKE: <reason>` and exits so the session wakes up, advances the lane, and restarts `--until-wake`).
   - Runs `zsh <kit>/lanes/lanes-watch.sh --check` every 10 minutes (`LANES_CHECK_INTERVAL_MIN`; for example via a 10-minute loop in Claude Code) to restart the watcher if `STALE` / `DEAD` and launch additional non-overlapping lanes.
   - Because `--until-wake` exits on every `WAKE:` (its last line is `RE-ARM: ...`), register the Claude Code Stop hook `lanes/hooks/claude-stop-watch-guard.sh`: in a session that uses the watcher, it refuses to let Claude finish its reply while lanes are running (or waiting for the next step) and the watcher is dead, and tells it to restart the watcher. Other sessions are unaffected. See docs/commander-claude.md for the settings snippet.
   - Note: Only progresses while your Mac and the Claude Desktop session remain open and awake, and each wake cycle consumes Claude usage in addition to the lanes themselves.

## Your first lane

As an example, let's add a small feature to your repository `my-app` (whose target base branch is `develop`).

### Before you start: prepare the target repository (once)

1. **Add `logs/` to `.gitignore`**. Launchers write their records to `logs/` inside the worktree. If it is not ignored, the files keep showing up as untracked in `git status`,
   and agents may commit the records (full task prompts and logs) by mistake, for example with `git add -A`.
   ```sh
   cd /Users/you/dev/my-app
   grep -qxF 'logs/' .gitignore 2>/dev/null || echo 'logs/' >> .gitignore
   git add .gitignore && git commit -m "chore: ignore lane records in logs/"
   # Get this into the base branch (develop), via a PR if the branch is protected. Lane worktrees are created from origin/develop, so worktrees created before that are not affected
   ```
   If you prefer not to commit it, adding `logs/` to `.git/info/exclude` (a local ignore list for this Mac, shared by all worktrees) also works.
   Passing a worktree, as in `zsh <kit>/lanes/lanes-doctor.sh /Users/you/dev/my-app`, makes the pre-flight check also verify that `logs/` is ignored (it prints a warning if not).
2. **Prepare a check command**: put the commands that run type checks, lint, and unit tests in `LANES_CHECK_CMD` (installation step 3) or in `.lanes/check.sh` in the target repository.
   Reviews check whether the verification commands were actually run, so a fixed check command keeps implementation, review, and the final check aligned.
   If the repository has no type checking, lint, or unit tests yet, say so in the task prompt ("not set up") so the review does not mistake it for "not run".

```sh
L=<kit>/lanes   # Path to launchers (if added to PATH, you can omit "$L/" below)

# 1. Create a worktree for the lane (under LANES_RUNS_ROOT so the watcher finds it automatically)
cd /Users/you/dev/my-app
git fetch origin
git worktree add -b lane/hello ~/dev/_runs/my-app/hello origin/develop

# 2. Write the task prompt (goal, allowed file paths, completion criteria, verification commands). Keep it outside the worktree (e.g. LANES_RUNS_ROOT/my-app/prompts/)
mkdir -p ~/dev/_runs/my-app/prompts
$EDITOR ~/dev/_runs/my-app/prompts/hello.md

# 3. Launch the implementation lane in the background (detach-run.sh detaches and returns immediately; in Claude Code, tool background execution also works)
zsh "$L/detach-run.sh" ~/dev/_runs/my-app/hello/logs/launch.log \
  zsh "$L/run-impl.sh" ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello.md hello-impl

# 4. Check liveness within 60 seconds of launch (anything other than RUNNING or DONE means launch failed)
zsh "$L/lanes-status.sh" ~/dev/_runs/my-app/hello hello-impl --tail 20

# 5. Once DONE, first run the pre-merge check once (the check command is LANES_CHECK_CMD from installation step 3, or .lanes/check.sh
#    in the target repository. Arguments are <worktree> <port (for the screen-check server)> <output dir>. Put the output under the
#    implementation lane's scratch directory (LANES_SCRATCH_ROOT/<repo>/<label>, removed during cleanup). Call chk-run.sh with bash).
#    The passing record lets the next review reuse it instead of rerunning typecheck, lint, and unit tests on the same content
#    (LANES_REVIEW_REUSE_CHECKS; run the check and the review from the same shell and do not change the worktree in between)
bash "$L/chk-run.sh" ~/dev/_runs/my-app/hello 3100 ~/dev/_runs/_scratch/my-app/hello-impl/chk   # if non-zero, fix and go back to 5

# 6. Run the review. Write a review prompt in the same place (the kit's template adds the common review checklist and verification
#    steps in front; here you only describe the change and what to look at closely). Increase only the trailing number of the label
#    (hello-r1 → hello-r2 …) so rounds are counted in the same series. On NEEDS_FIX, fix and go back to 5. If it is still not CLEAN
#    after LANES_REVIEW_MAX_ROUNDS rounds (default 5), it stops with GATE: ESCALATE and a human decides whether to continue or wrap up
#    (to wrap up, move the remaining items to .lanes/accepted-limitations.md or the follow-up list)
cat > ~/dev/_runs/my-app/prompts/hello-review.md <<'EOF'
# Review: greeting feature (lane/hello)
- Goal: show a greeting on the top page. Only src/hello/ and tests/hello/ may be touched
- Look closely at: empty and very long names, and that existing tests still pass
- Read the diff yourself with git diff origin/develop...HEAD
EOF
zsh "$L/run-review.sh" ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello-review.md hello-r1
zsh "$L/lanes-status.sh" ~/dev/_runs/my-app/hello hello-r1

# 7. Once VERDICT: CLEAN, push and create a PR with logs/hello-r1.evidence.md as the body
cd ~/dev/_runs/my-app/hello
git push -u origin lane/hello
gh pr create --base develop --title "feat: あいさつ機能" --body-file logs/hello-r1.evidence.md
gh pr merge --auto --merge --delete-branch

# 8. After the PR is merged, move out of the worktree to be removed (back to the main repository), then clean up (run dry-run first to preview)
cd /Users/you/dev/my-app
zsh "$L/cleanup-after-merge.sh" ~/dev/_runs/my-app/hello
zsh "$L/cleanup-after-merge.sh" ~/dev/_runs/my-app/hello --apply
```

Tips for writing prompts: Always specify **which files the lane is allowed to touch** and **completion criteria (which commands must pass)**.
Do not paste large diffs into the prompt file—instruct the lane to read `git diff origin/develop...HEAD` itself (oversized prompts will be rejected).

## Daily workflow

1. The commander splits a goal into small non-overlapping lanes and launches all independent lanes in parallel ([docs/commander-grok.md](docs/commander-grok.md) / [docs/commander-claude.md](docs/commander-claude.md), in Japanese).
2. `lanes-watch.sh` checks all lanes every 5 minutes and notifies with `WAKE:` when anything changes (`DONE`, `FAILED`, `STALLED`, or PR state).
3. When a lane reaches `DONE`, the commander immediately connects it to the next step (review → PR). `FAILED` / `DEAD` / `STALLED` lanes are reported to the human right away.
4. Do not spin up lanes just to watch CI. Hand PRs over to GitHub auto-merge and check their state on the next watcher pass.
5. Production changes (merging to `main`, production deployments, production DB migrations) always wait for explicit human approval (`GO`).

For operational rules, see [docs/operating-rules.md](docs/operating-rules.md) (in Japanese). Ready-to-paste templates for your own `AGENTS.md` and `CLAUDE.md` are in `templates/`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Launcher immediately becomes `FAILED` (`EXIT:2`) | Pre-flight check failed. Check `lanes-status.sh <worktree> <label> --tail 20` and `lanes-doctor.sh`. Common causes: not logged in with a subscription, or missing CLI binary |
| Prints "起動禁止" (launch forbidden) | Logged in with an API key or non-subscription method. Re-authenticate following "Verify subscription login" above |
| Prints "この構成では使えない" (unavailable in this profile, exit 2) | Called a tool-specific launcher not enabled in `LANES_TOOLS`. Use the entrypoints `run-impl.sh` / `run-review.sh` instead |
| Immediately becomes `DEAD` after launch | The parent shell exited and took the child process down with it. Keep the parent alive in the background (for short-lived bot shells, use `lanes/detach-run.sh <log> <コマンド...>`) |
| Stays `STALLED` | Waiting for permission, CLI hung, or rate-limited. Inspect output with `--tail`. If child CPU time is still increasing, a build or test may still be running. Once confirmed stuck, stop with `kill <launcher pid>` (never `kill -9`) and relaunch |
| Cannot launch with the same `label` (exit 2) | The previous launcher or its child process is still alive. Check `lanes-status.sh`; only run `kill N` if a `FAILED` / `DEAD` line explicitly reports a surviving child `pid=N` |
| Review ends with `VERDICT: NONE` | Output was truncated or missing the final verdict line. Treated as a failure—re-run the review lane |
| Stops because the prompt is too large | A diff was pasted into the prompt file. Replace it with instructions to run `git diff` (limit is `LANES_PROMPT_MAX_BYTES`) |
| `cleanup-after-merge.sh` stops | Uncommitted changes, untracked files, or a running lane exist in the worktree. Check the printed archive path and reason, resolve them, then re-run with `--apply` (git-ignored build outputs such as `dist/`, `build/`, and `out/` are archived and do not stop the cleanup) |
| The effort from the config file is not used | The launching shell has `CLAUDE_EFFORT` (or `CODEX_EFFORT` / `GEMINI_EFFORT`) set as an environment variable, which is common for shells started from an app. Environment variables take precedence over the config file. The launcher prints a one-line notice at startup ("注意: CLAUDE_EFFORT は環境変数の値「…」で動く …"). To pin the config value, write the value literally in the config file, e.g. `CLAUDE_EFFORT="xhigh"` (see [docs/config.md](docs/config.md)) |
| Review evidence says "親の chk-run の記録は使わない" (parent check record not reused) | Look at the reason in the evidence. `no-record` means `chk-run.sh` has not passed for this tree yet; `input-changed` means dependencies, environment variables, or the check command changed after the record (call `chk-run.sh` and the review from the same shell). Launcher records (logs and launch logs directly under `logs/`) never cause this |
| Auto-merge merges immediately without waiting for CI | The repository has no required status checks (branch protection) configured. Enable branch protection, or wait with `gh pr checks <PR> --watch --fail-fast` before merging manually |

## Uninstallation

```sh
cd <kit>
./install.sh --uninstall --dry-run   # Preview symlinks to be removed
./install.sh --uninstall             # Remove only symlinks created by install.sh
```

Your configuration file (`~/.config/lanewright/lanes.conf`) is left in place; delete it manually if you no longer need it, then remove the `<kit>` directory.
If you added `<kit>/lanes` to `PATH` in `~/.zshrc`, remove that line as well.

## Documentation

See [docs/README.md](docs/README.md) for a map of all documents. The files under `docs/` and `lanes/README.md` are in Japanese.

- Configuration: [docs/config.md](docs/config.md) / Tool profiles and roles: [docs/roles.md](docs/roles.md) / Operating rules: [docs/operating-rules.md](docs/operating-rules.md)
- Commander: [external bot](docs/commander-grok.md) / [Claude desktop Code tab](docs/commander-claude.md)
- Launcher reference (arguments, outputs, exit codes, safety details): [lanes/README.md](lanes/README.md)
- Security: [SECURITY.md](SECURITY.md) / Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) / Changelog: [CHANGELOG.md](CHANGELOG.md)

## License

MIT License. See [LICENSE](LICENSE).
