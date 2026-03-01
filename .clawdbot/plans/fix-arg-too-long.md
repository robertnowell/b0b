# Fix: OSError "Argument list too long"

## Root Cause

There is no `fill-template.sh` or `dispatch.sh` — the actual scripts involved are:

- **`.clawdbot/monitor.sh`** — the pipeline state machine (calls notify.sh and spawn-agent.sh)
- **`.clawdbot/notify.sh`** — sends Slack notifications
- **`.clawdbot/spawn-agent.sh`** — spawns agents in tmux worktrees

The crash happens when `monitor.sh` advances `workspace-pipeline-v2` from `implementing` to `auditing`. At that transition, `monitor.sh` calls `build_audit_prompt(task)` which reads both `{PRD}` and `{PLAN}` files and substitutes them inline into the prompt template. It then writes the result to a temp file — **this part is fine**.

The real problem is in **`notify.sh`** (and how `monitor.sh` calls it). There are **two** argument-size bottlenecks:

### Bottleneck 1: `notify.sh` is called via `subprocess.run()` with message as a positional argument

```python
subprocess.run([
    f'{script_dir}/notify.sh',
    action['task_id'],
    action['message'],    # <-- shell argument, subject to ARG_MAX
    action['emoji']
], ...)
```

While most notification messages are short (~200 chars), the error-handling path for spawn failures includes up to 300 chars of error output. This alone shouldn't hit ARG_MAX, but combined with inherited environment variables it can push over the limit.

### Bottleneck 2: `notify.sh` passes `$PAYLOAD` as a curl `--data` argument

```bash
curl -s -X POST -H 'Content-type: application/json' \
  --data "$PAYLOAD" "$WEBHOOK_URL" > /dev/null
```

The `--data "$PAYLOAD"` expands the entire JSON payload as a command-line argument to `curl`. If the message is large, this hits the OS argument limit.

### Bottleneck 3 (likely trigger): Inherited environment

`monitor.sh`'s embedded Python script uses `subprocess.run()` which inherits the parent environment. The Python process has the entire `monitor.sh` environment plus any variables set during the run. On macOS, ARG_MAX (~256KB) includes **both** argv and environ. If the accumulated environment is large (e.g., from a cron job that sources heavy profiles, or from tmux sessions with large env), even modest arguments can tip over the limit.

The specific trigger for `workspace-pipeline-v2` is likely a combination of:
- A large PRD/plan file that was read into memory (not directly the cause, since prompts are written to temp files)
- The accumulated environment from the cron + tmux context
- The notification message being passed as a subprocess argument

## Fix Plan

### Fix 1: `notify.sh` — use `--data @-` (stdin) for curl

**File:** `.clawdbot/notify.sh`

Change:
```bash
curl -s -X POST -H 'Content-type: application/json' \
  --data "$PAYLOAD" "$WEBHOOK_URL" > /dev/null
```

To:
```bash
echo "$PAYLOAD" | curl -s -X POST -H 'Content-type: application/json' \
  --data @- "$WEBHOOK_URL" > /dev/null
```

This removes the `$PAYLOAD` from curl's argument list entirely. curl reads the POST body from stdin instead.

### Fix 2: `notify.sh` — accept message via stdin instead of positional argument

**File:** `.clawdbot/notify.sh`

Change the script to read the message from stdin when argument 2 is `-` or missing:

```bash
TASK_ID="${1:?Missing task ID}"
if [ "${2:-}" = "-" ] || [ $# -lt 2 ]; then
  MESSAGE="$(cat)"
else
  MESSAGE="$2"
fi
EMOJI="${3:-:robot_face:}"
```

This is backward-compatible: existing callers passing a string argument still work; new callers can pipe the message in.

### Fix 3: `monitor.sh` — pipe notification messages via stdin

**File:** `.clawdbot/monitor.sh`

In the deferred actions execution loop, change the notify call from:

```python
subprocess.run([
    f'{script_dir}/notify.sh',
    action['task_id'],
    action['message'],
    action['emoji']
], capture_output=True, text=True, check=True)
```

To:

```python
subprocess.run(
    [f'{script_dir}/notify.sh', action['task_id'], '-', action['emoji']],
    input=action['message'],
    capture_output=True, text=True, check=True
)
```

Similarly for the spawn-failure notification path.

### Fix 4: `monitor.sh` — trim environment before subprocess calls

Add `env=` parameter to subprocess calls to pass a minimal environment:

```python
clean_env = {k: v for k, v in os.environ.items()
             if k in ('PATH', 'HOME', 'USER', 'SHELL', 'TERM',
                       'CLAWDBOT_SLACK_WEBHOOK', 'LANG', 'LC_ALL')}
```

Then pass `env=clean_env` to all `subprocess.run()` calls. This prevents environment bloat from contributing to ARG_MAX.

## Implementation Order

1. Fix `notify.sh` (Fixes 1 + 2) — the most impactful change
2. Fix `monitor.sh` notify calls (Fix 3) — uses the new stdin interface
3. Fix `monitor.sh` environment trimming (Fix 4) — defense in depth
4. Test with a large plan file to verify

## Backward Compatibility

- `notify.sh` remains callable with positional arguments (old behavior)
- `spawn-agent.sh` is unaffected (it already writes prompts to temp files and passes file paths)
- `approve-plan.sh` / `reject-plan.sh` don't call notify.sh with large messages
- No changes to `active-tasks.json` schema

## Testing

1. Create a task with a large PRD (>100KB) and plan file
2. Run `monitor.sh` through an implementing -> auditing transition
3. Verify notification is sent successfully
4. Verify agent spawns correctly
5. Run with `getconf ARG_MAX` to confirm headroom
