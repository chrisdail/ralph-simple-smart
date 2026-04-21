![Ralph](ralph-wiggum.webp)
# Ralph Simple Smart

A simple, lightweight implementation of the [Ralph Wiggum](https://ghuntley.com/ralph/) technique for Claude Code autonomous loops.

> "Me fail English? That's unpossible!" - Ralph Wiggum

## Why Another Ralph?

Existing implementations were lacking in multiple ways, and this implementation aims to correct these.

- **New Context Each Time** - This project uses a new context for each task (unlike the official [ralph-loop plugin](https://awesomeclaude.ai/ralph-wiggum) which relies on auto-compaction, which can lead to [context pollution](https://x.com/yoavtzfati/status/2008362072380461515)).
- **Cost-Effective** - Ralph can consume a lot of tokens since each task sets up a fresh context. This implementation has a feature to cap usage based on Claude session usage instead of an arbitrary number of iterations.
- **Safe** - This implementation supports Claude's auto mode which is safer than `--dangerously-skip-permissions`.
- **Simple** - Many implementations simply try to add too many things that are simply not needed like monitoring dashboards, orchestrators and opinionated workflows. This implementation is ~200 lines of bash and is easy to understand and modify.
## Claude Auto Mode

Auto mode requires a Max, Team, Enterprise, or API plan (not available on Pro) and must be enabled by admins on Team/Enterprise plans. It works with Anthropic API only (not Bedrock, Vertex, or Foundry).

Claude Code's auto permission mode (`--permission-mode auto`) lets Claude execute actions without individual permission prompts. Instead, a separate classifier model reviews each action in the background before execution and blocks anything that escalates beyond your request, targets unrecognized infrastructure, or appears driven by hostile content.

By default, the classifier blocks dangerous patterns like `curl | bash`, pushing to main, mass cloud deletion, and production deploys — while allowing safe local operations such as file edits, dependency installation, and read-only HTTP requests. Protected paths (`.git`, `.claude`, `.mcp.json`) always require manual approval even in auto mode. If the classifier blocks an action 3 times consecutively or 20 times total, auto mode pauses and falls back to manual prompting.

When not using auto mode, ralph-loop defaults to `acceptEdits` permission mode with a configurable set of allowed tools via the `RALPH_ALLOWED_TOOLS` environment variable.

## Claude Session Usage

Claude Code implements rolling usage allowances tied to your plan. There are two levels of limits:

- **Session limits** — A short-term quota that resets on a rolling basis (e.g., every few hours).
- **Weekly limits** — A longer-term quota that resets on a weekly schedule.

When you hit a limit, Claude Code blocks further requests until the reset time. The `/usage` command shows current usage percentages and reset times.

Ralph-loop can use the `--max-session-usage` option to stop before hitting the session limit. This also prevents going overage session limits when extra usage is enabled on team plans.

## Installation

The following tools are used and are required to be installed:

- `jq` - Used for parsing claude output files.
- `tmux` - Used for terminal capture/response to get claude usage.

Check out this repo and either put it on your path or reference `ralph-loop.sh` directly.

## Example Setup

Example Prompt (`ralph.md`):

```
Look at the work to be done in @todo.md. This is a set of current tasks that need to be completed.

Pick up exactly one task, and one task only, from this list and implement it. When the task is done, check off the task in @todo.md. If there are uncommitted files, look at them and try to figure out what task you were working on last and continue.

Follow the following steps to ensure the task is completed:

- Write all code and unit tests required for the task.
- Ensure you follow any conventions in @CLAUDE.md, including linting and running unit tests.
- Create a git commit using the git CLI, adding the file changes.

After the task is complete, the @todo.md has been updated with a checkmark on the task. If there are additional tasks to perform, exit the session. If all tasks in @todo.md are checked off, output <promise>COMPLETE</promise>. Only output this if all tasks are complete.
```

This commits each change as one commit. Alternatively, this could create a PR for each.

For this setup, it uses a `todo.md` to provide the list of tasks and track progress. Here is an example `todo.md`

```
# Task List

Do not commit this file to the repository.

## Feature Flags

These flags always evaluate to `true` in production. The flag checks are dead code and should be removed — keep the guarded feature, remove the condition.

- [ ] Remove feature flag `unused-flag`
- [ ] ...
```

## Usage

```bash
# Single run (default)
./ralph-loop.sh @ralph.md

# Prompt inline or as a file
./ralph-loop.sh "This is the prompt"

# Run with a session usage limit (recommended)
./ralph-loop.sh --max-session-usage 80 --auto-mode @ralph.md

# Run a fixed number of iterations
./ralph-loop.sh --max-iterations 5 @ralph.md

```

### Options

| Option                    | Description                                                         |
| ------------------------- | ------------------------------------------------------------------- |
| `--auto-mode`             | Use auto permission mode (requires Team/Enterprise plan)            |
| `--max-iterations N`      | Max loop iterations (default: 1, or 999 with `--max-session-usage`) |
| `--max-session-usage PCT` | Stop when session usage reaches PCT%                                |

### Environment Variables

| Variable              | Description                                                                                    |
| --------------------- | ---------------------------------------------------------------------------------------------- |
| `RALPH_ALLOWED_TOOLS` | Override default allowed tools (space-separated patterns). Only used when not using auto mode. |

### Completion

Claude signals completion by including `<promise>COMPLETE</promise>` in its response. The loop exits when this is detected.

## Scripts

### `ralph-loop.sh`

The main loop runner. Runs Claude repeatedly with usage monitoring, permission controls, and JSON logging. Logs are written to `ralph-logs/` in the working directory.

### `claude-usage.sh`

Checks Claude's current session and weekly usage percentages by querying the `/usage` command via tmux.

```bash
./claude-usage.sh        # Show both session and weekly usage
./claude-usage.sh -s     # Session usage only
./claude-usage.sh -w     # Weekly usage only
```
