# Plan: Fix monitor.sh setting phase to merged before PR is actually merged

## Bug Analysis

The `pr_ready` handler in `monitor.sh` (lines 488-507) checks for merged PRs using:
```
gh pr list --head <branch> --state merged --json number --limit 1
```

This returns **any** merged PR that used that head branch — not necessarily the current PR. If a branch previously had a merged PR (e.g., from a prior iteration, manual PR, or reused branch name), the old merged PR would be returned, causing the task to be **incorrectly marked as `merged`** before the current PR is actually merged.

The `reviewing` handler (lines 462-485) already discovers the correct PR number when checking CI status, but **never stores it** in the task. The `pr_ready` handler then has to re-discover the PR by branch name, using the wrong query (`--state merged` instead of checking the specific PR).

## Files to Modify/Create

### 1. `.clawdbot/scripts/monitor.sh` (modify)
Two targeted changes in the embedded Python state machine.

## Specific Changes

### Change 1: Store PR number when transitioning from `reviewing` → `pr_ready`

**Location:** Line 478 in the `reviewing` handler.

**Current code:**
```python
apply_updates(tid, {'phase': 'pr_ready', 'status': 'pr_ready'})
```

**New code:**
```python
apply_updates(tid, {'phase': 'pr_ready', 'status': 'pr_ready', 'prNumber': pr_number})
```

This persists the specific PR number that passed CI, so the `pr_ready` handler can verify the exact PR.

### Change 2: Check specific PR merge status in `pr_ready` handler

**Location:** Lines 488-507, the `pr_ready` handler.

**Current code:**
```python
if phase == 'pr_ready':
    branch = task.get('branch', '')
    if branch:
        task_repo = get_task_repo(task)
        # Check if PR has been merged
        merged_result = subprocess.run(
            ['gh', 'pr', 'list', '--head', branch, '--state', 'merged', '--json', 'number', '--limit', '1'],
            capture_output=True, text=True, cwd=task_repo)
        if merged_result.returncode == 0 and merged_result.stdout.strip():
            merged_prs = json.loads(merged_result.stdout)
            if merged_prs:
                pr_number = merged_prs[0].get('number')
                apply_updates(tid, {'phase': 'merged', 'status': 'merged'})
                run_notify(tid, 'merged',
                    f'PR #{pr_number} has been merged',
                    product_goal,
                    'Done')
                changes_made += 1
    # If not yet merged, stay in pr_ready (wait for next cycle)
    continue
```

**New code:**
```python
if phase == 'pr_ready':
    pr_number = task.get('prNumber')
    if pr_number:
        task_repo = get_task_repo(task)
        # Check if the specific PR has been merged
        merged_result = subprocess.run(
            ['gh', 'pr', 'view', str(pr_number), '--json', 'state'],
            capture_output=True, text=True, cwd=task_repo)
        if merged_result.returncode == 0 and merged_result.stdout.strip():
            pr_data = json.loads(merged_result.stdout)
            if pr_data.get('state') == 'MERGED':
                apply_updates(tid, {'phase': 'merged', 'status': 'merged'})
                run_notify(tid, 'merged',
                    f'PR #{pr_number} has been merged',
                    product_goal,
                    'Done')
                changes_made += 1
    # If not yet merged, stay in pr_ready (wait for next cycle)
    continue
```

Key differences:
- Uses `task.get('prNumber')` instead of discovering by branch
- Uses `gh pr view <number> --json state` to check the **specific** PR's state
- Checks `state == 'MERGED'` (the `gh pr view` state value for merged PRs)
- Falls back gracefully: if `prNumber` is not set (legacy tasks), task stays in `pr_ready` indefinitely rather than false-positiving

## Testing Strategy

### Manual validation
1. Verify `gh pr view <number> --json state` returns `{"state": "MERGED"}` for a known merged PR and `{"state": "OPEN"}` for an open PR
2. Run `bash -n .clawdbot/scripts/monitor.sh` to verify no syntax errors
3. Test the Python block with `python3 -c "..."` syntax check

### Edge cases to verify
- Task that reached `pr_ready` before this fix (no `prNumber` field) — should safely stay in `pr_ready` without false positive
- PR that is closed (not merged) — `state` would be `CLOSED`, not `MERGED`, so no false positive

### No automated tests exist
The pipeline scripts don't have a test suite. Validation is manual + syntax checks.

## Risk Assessment

- **Low risk**: Only two lines of the state machine change. The logic is more conservative (checks specific PR rather than any PR on the branch).
- **Edge case — legacy tasks**: Tasks already in `pr_ready` without a `prNumber` field will not be able to transition to `merged`. This is intentional — it's safer to require manual intervention than to false-positive. If needed, the `prNumber` can be manually set in `active-tasks.json`.
- **Edge case — `gh pr view` failure**: If the `gh` command fails (network issue, rate limit), `merged_result.returncode != 0` and the task stays in `pr_ready`, which is the safe behavior.

## Estimated Complexity

**trivial** — Two targeted changes in one file. No new dependencies, no architectural changes.

PLAN_VERDICT:READY
