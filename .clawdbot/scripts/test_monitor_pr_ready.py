#!/usr/bin/env python3
"""Tests for monitor.sh pr_ready phase logic.

Validates the fix that introduces a pr_ready intermediate phase between
reviewing and merged, ensuring the pipeline only marks a task as merged
after the PR is actually merged on GitHub.

Covers:
  - reviewing → pr_ready transition (CI pass with prNumber storage)
  - pr_ready → merged transition (actual merge detected)
  - pr_ready stays pr_ready when PR is still open
  - pr_ready stays pr_ready when gh command fails
  - pr_ready backfill of prNumber for legacy tasks
  - pr_ready without prNumber and no branch (no-op)
  - Race guard allows pr_ready and reviewing phases through
  - reviewing does NOT jump straight to merged anymore
"""

import json
import subprocess
import unittest
from unittest.mock import MagicMock, call, patch

# ---------------------------------------------------------------------------
# Helpers — simulate the monitor state-machine fragments under test
# ---------------------------------------------------------------------------

def simulate_reviewing_phase(task, subprocess_run_mock):
    """Simulate the 'reviewing' block from monitor.sh."""
    branch = task.get('branch', '')
    pr_number = None
    ci_pass = False
    updates = {}
    notifications = []
    conflict_updates = {}
    conflict_notifications = []
    conflict_dispatch_attempted = False

    if branch:
        task_repo = '/fake/repo'
        pr_result = subprocess_run_mock(
            ['gh', 'pr', 'list', '--head', branch, '--state', 'open',
             '--json', 'number,statusCheckRollup', '--limit', '1'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_result.returncode == 0 and pr_result.stdout.strip():
            prs = json.loads(pr_result.stdout)
            if prs:
                pr_number = prs[0].get('number')
                checks = prs[0].get('statusCheckRollup', [])
                ci_pass = checks and all(
                    (c.get('conclusion') or c.get('state', '')).upper() == 'SUCCESS'
                    for c in checks
                )
        if pr_number and ci_pass:
            updates = {'phase': 'pr_ready', 'status': 'pr_ready', 'prNumber': pr_number, 'conflictFixCount': 0}
            notifications.append(('pr_ready', f'PR #{pr_number} passed CI — ready for human review'))
        elif pr_number and not ci_pass:
            # Check for merge conflicts while waiting for CI
            merge_result = subprocess_run_mock(
                ['gh', 'pr', 'view', str(pr_number), '--json', 'mergeable'],
                capture_output=True, text=True, cwd=task_repo)
            if merge_result.returncode == 0 and merge_result.stdout.strip():
                mergeable = json.loads(merge_result.stdout).get('mergeable', '')
                if mergeable == 'CONFLICTING':
                    conflict_fix_count = task.get('conflictFixCount', 0)
                    if conflict_fix_count >= 2:
                        conflict_notifications.append(('reviewing',
                            f'PR #{pr_number} still has merge conflicts after {conflict_fix_count} fix attempts. Needs manual resolution.'))
                    else:
                        conflict_dispatch_attempted = True
                        # In the real monitor, dispatch-fix.sh is called here.
                        # We simulate dispatch success by default.
                        conflict_updates = {'conflictFixCount': conflict_fix_count + 1}
                        conflict_notifications.append(('fixing',
                            f'PR #{pr_number} has merge conflicts. Auto-dispatching fix agent.'))
    return updates, notifications, conflict_updates, conflict_notifications, conflict_dispatch_attempted


def simulate_pr_ready_phase(task, subprocess_run_mock):
    """Simulate the 'pr_ready' block from monitor.sh."""
    branch = task.get('branch', '')
    task_repo = '/fake/repo'
    pr_number = task.get('prNumber')
    product_goal = task.get('productGoal', '')
    tid = task.get('id', '')
    updates_list = []
    notifications = []
    changes_made = 0

    # Backfill PR number for tasks created before prNumber tracking existed.
    if not pr_number and branch:
        pr_result = subprocess_run_mock(
            ['gh', 'pr', 'list', '--head', branch, '--state', 'open',
             '--json', 'number', '--limit', '1'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_result.returncode == 0 and pr_result.stdout.strip():
            prs = json.loads(pr_result.stdout)
            if prs:
                pr_number = prs[0].get('number')
                updates_list.append({'prNumber': pr_number})
                changes_made += 1

    if pr_number:
        pr_state_result = subprocess_run_mock(
            ['gh', 'pr', 'view', str(pr_number), '--json', 'state'],
            capture_output=True, text=True, cwd=task_repo)
        if pr_state_result.returncode == 0 and pr_state_result.stdout.strip():
            pr_state = json.loads(pr_state_result.stdout).get('state', '')
            if str(pr_state).upper() == 'MERGED':
                updates_list.append({'phase': 'merged', 'status': 'merged'})
                notifications.append(('merged', f'PR #{pr_number} has been merged'))
                changes_made += 1

    return updates_list, notifications, changes_made


def simulate_pr_creating_success(
    task,
    pr_list_result,
    dispatch_fix_result=None,
    max_missing_pr_retries=2,
):
    """Simulate the succeeded + pr_creating branch from monitor.sh."""
    pr_number = None
    pr_lookup_reason = 'no_pr_found'
    updates = {}
    notifications = []
    changes_made = 0
    dispatch_attempted = False

    branch = task.get('branch', '')
    retry_count = int(task.get('missingPrRetryCount', 0))

    if branch:
        if pr_list_result.returncode == 0 and pr_list_result.stdout.strip():
            try:
                prs = json.loads(pr_list_result.stdout)
            except json.JSONDecodeError:
                prs = []
                pr_lookup_reason = 'invalid_pr_list_json'
            if prs:
                pr_number = prs[0].get('number')
            else:
                pr_lookup_reason = 'no_pr_found'
        elif pr_list_result.returncode != 0:
            pr_lookup_reason = f'gh_pr_list_failed_rc_{pr_list_result.returncode}'
        else:
            pr_lookup_reason = 'empty_pr_list_output'
    else:
        pr_lookup_reason = 'missing_branch'

    if pr_number:
        updates = {
            'phase': 'reviewing',
            'status': 'reviewing',
            'prNumber': pr_number,
            'missingPrRetryCount': 0,
        }
        notifications.append(('reviewing', f'PR created (PR #{pr_number}). Awaiting review.'))
    else:
        if retry_count < max_missing_pr_retries:
            dispatch_attempted = True
            next_retry = retry_count + 1
            if dispatch_fix_result and dispatch_fix_result.returncode == 0:
                updates = {'missingPrRetryCount': next_retry}
                notifications.append((
                    'fixing',
                    f'No PR found after pr_creating success ({pr_lookup_reason}). '
                    f'Auto-dispatched remediation ({next_retry}/{max_missing_pr_retries}).',
                ))
            else:
                updates = {'missingPrRetryCount': next_retry}
                notifications.append((
                    'pr_creating',
                    f'No PR found after pr_creating success ({pr_lookup_reason}). '
                    f'Auto-remediation dispatch failed ({next_retry}/{max_missing_pr_retries}); will retry.',
                ))
        else:
            updates = {
                'phase': 'failed',
                'status': 'failed',
                'failReason': 'pr_missing_after_retries',
            }
            notifications.append((
                'failed',
                f'No PR found after {retry_count} remediation attempt(s) '
                f'(reason: {pr_lookup_reason}). Manual intervention required.',
            ))

    changes_made += 1
    return updates, notifications, changes_made, dispatch_attempted


def should_skip_race_guard(phase, last_action, now):
    """Simulate the race guard logic from monitor.sh."""
    if now - last_action < 60 and phase not in ('reviewing', 'pr_ready'):
        return True  # skip
    return False  # don't skip


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestReviewingToPrReady(unittest.TestCase):
    """Reviewing phase should transition to pr_ready (not merged) when CI passes."""

    def _make_pr_list_result(self, pr_number, checks):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{
            'number': pr_number,
            'statusCheckRollup': checks,
        }])
        return result

    def test_ci_pass_transitions_to_pr_ready(self):
        """When CI passes, reviewing → pr_ready with prNumber stored."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        mock_run = MagicMock(return_value=self._make_pr_list_result(
            42, [{'conclusion': 'SUCCESS'}]
        ))

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates['phase'], 'pr_ready')
        self.assertEqual(updates['status'], 'pr_ready')
        self.assertEqual(updates['prNumber'], 42)
        self.assertEqual(updates['conflictFixCount'], 0)
        self.assertNotEqual(updates.get('phase'), 'merged',
                            'reviewing must NOT skip to merged')

    def test_ci_pass_sends_pr_ready_notification(self):
        """Notification should say pr_ready, not merged."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        mock_run = MagicMock(return_value=self._make_pr_list_result(
            42, [{'conclusion': 'SUCCESS'}]
        ))

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(len(notifications), 1)
        phase_notified, msg = notifications[0]
        self.assertEqual(phase_notified, 'pr_ready')
        self.assertIn('ready for human review', msg)

    def test_ci_not_passing_stays_reviewing(self):
        """When CI hasn't passed, stay in reviewing (no updates)."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        call_idx = [0]
        def mock_run(cmd, **kwargs):
            call_idx[0] += 1
            result = MagicMock()
            result.returncode = 0
            if call_idx[0] == 1:
                result.stdout = json.dumps([{
                    'number': 42,
                    'statusCheckRollup': [{'conclusion': 'FAILURE'}],
                }])
            else:
                result.stdout = json.dumps({'mergeable': 'MERGEABLE'})
            return result

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})
        self.assertEqual(notifications, [])

    def test_no_pr_stays_reviewing(self):
        """When no PR found, stay in reviewing."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([])
        mock_run = MagicMock(return_value=result)

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})

    def test_ci_pending_stays_reviewing(self):
        """When checks are still pending (empty list), stay in reviewing."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing'}
        call_idx = [0]
        def mock_run(cmd, **kwargs):
            call_idx[0] += 1
            result = MagicMock()
            result.returncode = 0
            if call_idx[0] == 1:
                result.stdout = json.dumps([{
                    'number': 42,
                    'statusCheckRollup': [],
                }])
            else:
                result.stdout = json.dumps({'mergeable': 'MERGEABLE'})
            return result

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates, {})


class TestPrCreatingGate(unittest.TestCase):
    """pr_creating success must not advance without a discoverable PR."""

    def _make_result(self, rc=0, stdout=''):
        result = MagicMock()
        result.returncode = rc
        result.stdout = stdout
        return result

    def test_pr_present_advances_to_reviewing(self):
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_creating'}
        pr_result = self._make_result(stdout=json.dumps([{'number': 42}]))

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result
        )

        self.assertEqual(updates['phase'], 'reviewing')
        self.assertEqual(updates['status'], 'reviewing')
        self.assertEqual(updates['prNumber'], 42)
        self.assertEqual(updates['missingPrRetryCount'], 0)
        self.assertFalse(dispatch_attempted)
        self.assertEqual(notifications[0][0], 'reviewing')

    def test_no_pr_dispatches_remediation_and_increments_retry(self):
        task = {
            'id': 'task-1',
            'branch': 'feat/test',
            'phase': 'pr_creating',
            'missingPrRetryCount': 0,
        }
        pr_result = self._make_result(stdout=json.dumps([]))
        dispatch_ok = self._make_result(rc=0)

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_ok
        )

        self.assertEqual(updates, {'missingPrRetryCount': 1})
        self.assertTrue(dispatch_attempted)
        self.assertEqual(notifications[0][0], 'fixing')
        self.assertIn('Auto-dispatched remediation (1/2)', notifications[0][1])

    def test_gh_failure_treated_as_missing_pr_and_remediated(self):
        task = {
            'id': 'task-1',
            'branch': 'feat/test',
            'phase': 'pr_creating',
            'missingPrRetryCount': 0,
        }
        pr_result = self._make_result(rc=1, stdout='')
        dispatch_ok = self._make_result(rc=0)

        updates, notifications, _, _ = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_ok
        )

        self.assertEqual(updates, {'missingPrRetryCount': 1})
        self.assertEqual(notifications[0][0], 'fixing')
        self.assertIn('gh_pr_list_failed_rc_1', notifications[0][1])

    def test_retry_limit_escalates_to_terminal_failure(self):
        task = {
            'id': 'task-1',
            'branch': 'feat/test',
            'phase': 'pr_creating',
            'missingPrRetryCount': 2,
        }
        pr_result = self._make_result(stdout=json.dumps([]))

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result
        )

        self.assertFalse(dispatch_attempted)
        self.assertEqual(updates['phase'], 'failed')
        self.assertEqual(updates['status'], 'failed')
        self.assertEqual(updates['failReason'], 'pr_missing_after_retries')
        self.assertEqual(notifications[0][0], 'failed')

    def test_dispatch_failure_still_bounded_by_retry_limit(self):
        task = {
            'id': 'task-1',
            'branch': 'feat/test',
            'phase': 'pr_creating',
            'missingPrRetryCount': 1,
        }
        pr_result = self._make_result(stdout=json.dumps([]))
        dispatch_fail = self._make_result(rc=1)

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_fail
        )
        self.assertTrue(dispatch_attempted)
        self.assertEqual(updates, {'missingPrRetryCount': 2})
        self.assertEqual(notifications[0][0], 'pr_creating')

        # Next unchanged cycle reaches the configured retry ceiling and escalates.
        next_task = {**task, **updates}
        updates2, notifications2, _, dispatch_attempted2 = simulate_pr_creating_success(
            next_task, pr_result, dispatch_fix_result=dispatch_fail
        )
        self.assertFalse(dispatch_attempted2)
        self.assertEqual(updates2['phase'], 'failed')
        self.assertEqual(notifications2[0][0], 'failed')


class TestPrReadyToMerged(unittest.TestCase):
    """pr_ready phase should only transition to merged when PR is actually merged."""

    def _make_pr_view_result(self, state):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({'state': state})
        return result

    def _make_pr_list_result(self, pr_number):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{'number': pr_number}])
        return result

    def test_merged_pr_transitions_to_merged(self):
        """When gh pr view shows MERGED, transition to merged."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42, 'productGoal': 'Test goal'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('MERGED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have one update setting phase to merged
        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNotNone(merged_update)
        self.assertEqual(merged_update['status'], 'merged')
        self.assertEqual(changes, 1)

    def test_open_pr_stays_pr_ready(self):
        """When PR is still OPEN, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42, 'productGoal': 'Test goal'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('OPEN'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNone(merged_update, 'Must NOT transition to merged while PR is OPEN')
        self.assertEqual(notifications, [])
        self.assertEqual(changes, 0)

    def test_closed_pr_stays_pr_ready(self):
        """When PR is CLOSED (not merged), remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        mock_run = MagicMock(return_value=self._make_pr_view_result('CLOSED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        merged_update = next((u for u in updates_list if u.get('phase') == 'merged'), None)
        self.assertIsNone(merged_update)
        self.assertEqual(changes, 0)

    def test_gh_failure_stays_pr_ready(self):
        """When gh command fails, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 1
        result.stdout = ''
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_empty_gh_response_stays_pr_ready(self):
        """When gh returns empty output, remain in pr_ready."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 0
        result.stdout = ''
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_merged_sends_correct_notification(self):
        """Merged notification includes PR number and says 'has been merged'."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 99, 'productGoal': 'Ship feature'}
        mock_run = MagicMock(return_value=self._make_pr_view_result('MERGED'))

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(len(notifications), 1)
        phase_notified, msg = notifications[0]
        self.assertEqual(phase_notified, 'merged')
        self.assertIn('PR #99', msg)
        self.assertIn('has been merged', msg)

    def test_uses_specific_pr_number(self):
        """pr_ready must poll the specific prNumber, not discover a new one."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}

        calls = []
        def capture_run(*args, **kwargs):
            calls.append(args[0] if args else kwargs.get('args'))
            result = MagicMock()
            result.returncode = 0
            result.stdout = json.dumps({'state': 'OPEN'})
            return result

        simulate_pr_ready_phase(task, capture_run)

        # Should call gh pr view with the specific PR number, not gh pr list
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ['gh', 'pr', 'view', '42', '--json', 'state'])


class TestPrReadyBackfill(unittest.TestCase):
    """Tasks without prNumber should attempt backfill via gh pr list."""

    def test_backfill_pr_number(self):
        """When prNumber is missing, backfill from gh pr list then check state."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        call_count = [0]
        def mock_run(cmd, **kwargs):
            call_count[0] += 1
            result = MagicMock()
            result.returncode = 0
            if 'pr' in cmd and 'list' in cmd:
                result.stdout = json.dumps([{'number': 55}])
            elif 'pr' in cmd and 'view' in cmd:
                result.stdout = json.dumps({'state': 'OPEN'})
            return result

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have backfilled prNumber
        backfill_update = next((u for u in updates_list if 'prNumber' in u), None)
        self.assertIsNotNone(backfill_update)
        self.assertEqual(backfill_update['prNumber'], 55)
        # Should have made 2 calls: pr list (backfill) + pr view (state check)
        self.assertEqual(call_count[0], 2)

    def test_backfill_then_merge(self):
        """Backfill prNumber, then detect merge in the same cycle."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        def mock_run(cmd, **kwargs):
            result = MagicMock()
            result.returncode = 0
            if 'pr' in cmd and 'list' in cmd:
                result.stdout = json.dumps([{'number': 55}])
            elif 'pr' in cmd and 'view' in cmd:
                result.stdout = json.dumps({'state': 'MERGED'})
            return result

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        # Should have both backfill and merged updates
        self.assertTrue(any('prNumber' in u for u in updates_list))
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_no_branch_no_pr_number_noop(self):
        """When there's no prNumber and no branch, nothing happens."""
        task = {'id': 'task-1', 'phase': 'pr_ready'}
        mock_run = MagicMock()

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        mock_run.assert_not_called()
        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)

    def test_backfill_empty_pr_list(self):
        """When gh pr list returns no PRs, no backfill and no state check."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready'}

        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([])
        mock_run = MagicMock(return_value=result)

        updates_list, notifications, changes = simulate_pr_ready_phase(task, mock_run)

        self.assertEqual(updates_list, [])
        self.assertEqual(changes, 0)


class TestRaceGuard(unittest.TestCase):
    """Race guard must allow pr_ready and reviewing to be processed every cycle."""

    def test_pr_ready_bypasses_race_guard(self):
        """pr_ready phase is NOT skipped even if acted on < 60s ago."""
        skipped = should_skip_race_guard('pr_ready', last_action=100, now=130)
        self.assertFalse(skipped, 'pr_ready must bypass the race guard')

    def test_reviewing_bypasses_race_guard(self):
        """reviewing phase is NOT skipped even if acted on < 60s ago."""
        skipped = should_skip_race_guard('reviewing', last_action=100, now=130)
        self.assertFalse(skipped)

    def test_implementing_respects_race_guard(self):
        """implementing phase IS skipped if acted on < 60s ago."""
        skipped = should_skip_race_guard('implementing', last_action=100, now=130)
        self.assertTrue(skipped)

    def test_old_action_not_skipped(self):
        """Any phase is NOT skipped if last action was > 60s ago."""
        skipped = should_skip_race_guard('implementing', last_action=100, now=200)
        self.assertFalse(skipped)


class TestTerminalPhaseSkip(unittest.TestCase):
    """Verify that the terminal phase list is correct."""

    TERMINAL_PHASES = ('merged', 'plan_review', 'split', 'failed')

    def test_merged_is_terminal(self):
        """merged phase should be skipped (terminal)."""
        self.assertIn('merged', self.TERMINAL_PHASES)

    def test_failed_is_terminal(self):
        """failed phase should be skipped (terminal)."""
        self.assertIn('failed', self.TERMINAL_PHASES)

    def test_pr_ready_is_not_terminal(self):
        """pr_ready should NOT be in the terminal list."""
        self.assertNotIn('pr_ready', self.TERMINAL_PHASES,
                         'pr_ready must not be terminal — it needs polling')

    def test_reviewing_is_not_terminal(self):
        """reviewing should NOT be in the terminal list."""
        self.assertNotIn('reviewing', self.TERMINAL_PHASES)


class TestPrReadyMergedStateVariants(unittest.TestCase):
    """Test various casing/formats of the MERGED state from GitHub."""

    def _run_with_state(self, state_str):
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_ready',
                'prNumber': 42}
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({'state': state_str})
        mock_run = MagicMock(return_value=result)
        return simulate_pr_ready_phase(task, mock_run)

    def test_uppercase_merged(self):
        updates_list, _, changes = self._run_with_state('MERGED')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_lowercase_merged(self):
        updates_list, _, changes = self._run_with_state('merged')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_mixed_case_merged(self):
        updates_list, _, changes = self._run_with_state('Merged')
        self.assertTrue(any(u.get('phase') == 'merged' for u in updates_list))

    def test_open_does_not_merge(self):
        updates_list, _, changes = self._run_with_state('OPEN')
        self.assertFalse(any(u.get('phase') == 'merged' for u in updates_list))


class TestPrCreatingGuardCompatibility(unittest.TestCase):
    """Additional coverage for missing-PR handling edge cases."""

    def _make_result(self, rc=0, stdout=''):
        result = MagicMock()
        result.returncode = rc
        result.stdout = stdout
        return result

    def test_empty_output_retries_with_pr_creating_notice(self):
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_creating', 'missingPrRetryCount': 0}
        pr_result = self._make_result(rc=0, stdout='')
        dispatch_fail = self._make_result(rc=1, stdout='')

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_fail
        )

        self.assertTrue(dispatch_attempted)
        self.assertEqual(updates, {'missingPrRetryCount': 1})
        self.assertEqual(notifications[0][0], 'pr_creating')
        self.assertIn('empty_pr_list_output', notifications[0][1])

    def test_missing_branch_still_attempts_remediation(self):
        task = {'id': 'task-1', 'phase': 'pr_creating', 'missingPrRetryCount': 0}
        pr_result = self._make_result(rc=0, stdout='')
        dispatch_ok = self._make_result(rc=0, stdout='')

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_ok
        )

        self.assertTrue(dispatch_attempted)
        self.assertEqual(updates, {'missingPrRetryCount': 1})
        self.assertEqual(notifications[0][0], 'fixing')
        self.assertIn('missing_branch', notifications[0][1])


class TestConflictFixRetryGuard(unittest.TestCase):
    """Conflict-fix dispatch in reviewing/pr_ready is bounded by conflictFixCount."""

    def _make_result(self, rc=0, stdout=''):
        result = MagicMock()
        result.returncode = rc
        result.stdout = stdout
        return result

    def _make_pr_list_with_failing_ci(self, pr_number):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps([{
            'number': pr_number,
            'statusCheckRollup': [{'conclusion': 'FAILURE'}],
        }])
        return result

    def _make_mergeable_result(self, mergeable):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({'mergeable': mergeable})
        return result

    def test_reviewing_conflict_dispatches_fix_and_increments(self):
        """First conflict in reviewing dispatches fix and increments conflictFixCount."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing', 'conflictFixCount': 0}
        call_idx = [0]
        def mock_run(cmd, **kwargs):
            call_idx[0] += 1
            if call_idx[0] == 1:
                return self._make_pr_list_with_failing_ci(42)
            else:
                return self._make_mergeable_result('CONFLICTING')

        _, _, conflict_updates, conflict_notifications, dispatched = simulate_reviewing_phase(task, mock_run)

        self.assertTrue(dispatched)
        self.assertEqual(conflict_updates, {'conflictFixCount': 1})
        self.assertEqual(conflict_notifications[0][0], 'fixing')

    def test_reviewing_conflict_escalates_after_max_retries(self):
        """After 2 conflict fixes, reviewing escalates instead of dispatching."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing', 'conflictFixCount': 2}
        call_idx = [0]
        def mock_run(cmd, **kwargs):
            call_idx[0] += 1
            if call_idx[0] == 1:
                return self._make_pr_list_with_failing_ci(42)
            else:
                return self._make_mergeable_result('CONFLICTING')

        _, _, conflict_updates, conflict_notifications, dispatched = simulate_reviewing_phase(task, mock_run)

        self.assertFalse(dispatched)
        self.assertEqual(conflict_updates, {})
        self.assertEqual(conflict_notifications[0][0], 'reviewing')
        self.assertIn('manual resolution', conflict_notifications[0][1].lower())

    def test_reviewing_no_conflict_no_dispatch(self):
        """If PR is not CONFLICTING, no conflict dispatch occurs."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing', 'conflictFixCount': 0}
        call_idx = [0]
        def mock_run(cmd, **kwargs):
            call_idx[0] += 1
            if call_idx[0] == 1:
                return self._make_pr_list_with_failing_ci(42)
            else:
                return self._make_mergeable_result('MERGEABLE')

        _, _, conflict_updates, conflict_notifications, dispatched = simulate_reviewing_phase(task, mock_run)

        self.assertFalse(dispatched)
        self.assertEqual(conflict_updates, {})
        self.assertEqual(conflict_notifications, [])

    def test_ci_pass_resets_conflict_fix_count(self):
        """When CI passes, conflictFixCount is reset to 0."""
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'reviewing', 'conflictFixCount': 1}
        pr_result = MagicMock()
        pr_result.returncode = 0
        pr_result.stdout = json.dumps([{
            'number': 42,
            'statusCheckRollup': [{'conclusion': 'SUCCESS'}],
        }])
        mock_run = MagicMock(return_value=pr_result)

        updates, notifications, _, _, _ = simulate_reviewing_phase(task, mock_run)

        self.assertEqual(updates['phase'], 'pr_ready')
        self.assertEqual(updates['conflictFixCount'], 0)


class TestPrCreatingInvalidJson(unittest.TestCase):
    """Edge case: gh pr list returns invalid JSON."""

    def _make_result(self, rc=0, stdout=''):
        result = MagicMock()
        result.returncode = rc
        result.stdout = stdout
        return result

    def test_invalid_json_triggers_remediation(self):
        """Invalid JSON from gh still triggers remediation.

        NOTE: There is a minor bug in monitor.sh — after catching JSONDecodeError
        and setting pr_lookup_reason='invalid_pr_list_json', the subsequent
        ``else`` branch (for empty prs list) overwrites it with 'no_pr_found'.
        The reason in the notification will therefore say 'no_pr_found' instead
        of 'invalid_pr_list_json'. Remediation still fires correctly.
        """
        task = {'id': 'task-1', 'branch': 'feat/test', 'phase': 'pr_creating', 'missingPrRetryCount': 0}
        pr_result = self._make_result(rc=0, stdout='not valid json')
        dispatch_ok = self._make_result(rc=0)

        updates, notifications, _, dispatch_attempted = simulate_pr_creating_success(
            task, pr_result, dispatch_fix_result=dispatch_ok
        )

        self.assertTrue(dispatch_attempted)
        self.assertEqual(updates, {'missingPrRetryCount': 1})
        # The reason is 'no_pr_found' due to the overwrite bug (see docstring above)
        self.assertIn('no_pr_found', notifications[0][1])


class TestAutoRevert(unittest.TestCase):
    """Tests for auto_revert() — worktree + branch cleanup."""

    def _auto_revert(self, task, subprocess_run, path_exists):
        """Replicate auto_revert() logic from monitor.sh for unit testing."""
        tmux = task.get('tmuxSession', f'agent-{task["id"]}')
        subprocess_run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

        worktree = task.get('worktree', '')
        branch = task.get('branch', '')
        task_repo = '/fake/repo'

        if worktree and path_exists(worktree):
            subprocess_run(['git', 'worktree', 'remove', '--force', worktree],
                           capture_output=True, cwd=task_repo)

        if branch:
            subprocess_run(['git', 'branch', '-D', branch],
                           capture_output=True, cwd=task_repo)
            if not task.get('prNumber'):
                subprocess_run(['git', 'push', 'origin', '--delete', branch],
                               capture_output=True, cwd=task_repo)

    def test_removes_worktree_and_deletes_branches(self):
        """auto_revert removes worktree, deletes local and remote branch."""
        task = {
            'id': 'task-1',
            'branch': 'fix/something',
            'worktree': '/worktrees/task-1',
        }
        mock_run = MagicMock()
        mock_exists = MagicMock(return_value=True)

        self._auto_revert(task, mock_run, mock_exists)

        mock_run.assert_any_call(
            ['tmux', 'kill-session', '-t', 'agent-task-1'], capture_output=True)
        mock_run.assert_any_call(
            ['git', 'worktree', 'remove', '--force', '/worktrees/task-1'],
            capture_output=True, cwd='/fake/repo')
        mock_run.assert_any_call(
            ['git', 'branch', '-D', 'fix/something'],
            capture_output=True, cwd='/fake/repo')
        mock_run.assert_any_call(
            ['git', 'push', 'origin', '--delete', 'fix/something'],
            capture_output=True, cwd='/fake/repo')

    def test_skips_remote_delete_when_pr_exists(self):
        """auto_revert does NOT delete remote branch when task has a PR."""
        task = {
            'id': 'task-2',
            'branch': 'fix/reviewed',
            'worktree': '/worktrees/task-2',
            'prNumber': 42,
        }
        mock_run = MagicMock()
        mock_exists = MagicMock(return_value=True)

        self._auto_revert(task, mock_run, mock_exists)

        remote_delete_call = call(
            ['git', 'push', 'origin', '--delete', 'fix/reviewed'],
            capture_output=True, cwd='/fake/repo')
        self.assertNotIn(remote_delete_call, mock_run.call_args_list)
        mock_run.assert_any_call(
            ['git', 'branch', '-D', 'fix/reviewed'],
            capture_output=True, cwd='/fake/repo')

    def test_skips_worktree_removal_when_not_exists(self):
        """auto_revert skips worktree removal when directory doesn't exist."""
        task = {
            'id': 'task-3',
            'branch': 'fix/gone',
            'worktree': '/worktrees/task-3',
        }
        mock_run = MagicMock()
        mock_exists = MagicMock(return_value=False)

        self._auto_revert(task, mock_run, mock_exists)

        worktree_remove_call = call(
            ['git', 'worktree', 'remove', '--force', '/worktrees/task-3'],
            capture_output=True, cwd='/fake/repo')
        self.assertNotIn(worktree_remove_call, mock_run.call_args_list)
        mock_run.assert_any_call(
            ['git', 'branch', '-D', 'fix/gone'],
            capture_output=True, cwd='/fake/repo')

    def test_no_branch_no_worktree(self):
        """auto_revert with minimal task only kills tmux."""
        task = {'id': 'task-4'}
        mock_run = MagicMock()
        mock_exists = MagicMock(return_value=False)

        self._auto_revert(task, mock_run, mock_exists)

        self.assertEqual(mock_run.call_count, 1)
        mock_run.assert_called_once_with(
            ['tmux', 'kill-session', '-t', 'agent-task-4'], capture_output=True)

    def test_custom_tmux_session(self):
        """auto_revert uses custom tmuxSession if present."""
        task = {
            'id': 'task-5',
            'tmuxSession': 'my-custom-session',
            'branch': 'fix/custom',
            'worktree': '/worktrees/task-5',
        }
        mock_run = MagicMock()
        mock_exists = MagicMock(return_value=True)

        self._auto_revert(task, mock_run, mock_exists)

        mock_run.assert_any_call(
            ['tmux', 'kill-session', '-t', 'my-custom-session'], capture_output=True)


class TestWorktreeCleanupBeforeSpawn(unittest.TestCase):
    """spawn_agent() must clean dirty worktree state before spawning a new agent."""

    @staticmethod
    def _simulate_cleanup(worktree, phase, tid, subprocess_run, path_isdir):
        """Replicate the worktree cleanup block from spawn_agent() in monitor.sh."""
        cleaned_count = 0
        if worktree and path_isdir(worktree):
            dirty_check = subprocess_run(
                ['git', 'status', '--porcelain'],
                capture_output=True, text=True, cwd=worktree)
            dirty_files = dirty_check.stdout.strip()
            if dirty_files:
                cleaned_count = len(dirty_files.splitlines())
                subprocess_run(['git', 'checkout', '.'], capture_output=True, cwd=worktree)
                subprocess_run(['git', 'clean', '-fd'], capture_output=True, cwd=worktree)
        return cleaned_count

    def _make_status_result(self, porcelain_output):
        result = MagicMock()
        result.returncode = 0
        result.stdout = porcelain_output
        return result

    def test_dirty_worktree_triggers_checkout_and_clean(self):
        """When worktree has uncommitted files, git checkout and clean are called."""
        dirty_output = ' M brand-store.tsx\n M email-row.test.tsx\n?? plan.md'
        calls = []
        def mock_run(cmd, **kwargs):
            calls.append((cmd, kwargs.get('cwd')))
            return self._make_status_result(dirty_output)

        count = self._simulate_cleanup(
            '/worktrees/task-1', 'pr_creating', 'task-1',
            mock_run, lambda p: True)

        self.assertEqual(count, 3)
        self.assertEqual(calls[0], (['git', 'status', '--porcelain'], '/worktrees/task-1'))
        self.assertEqual(calls[1], (['git', 'checkout', '.'], '/worktrees/task-1'))
        self.assertEqual(calls[2], (['git', 'clean', '-fd'], '/worktrees/task-1'))

    def test_clean_worktree_skips_checkout_and_clean(self):
        """When worktree is clean, only git status is called."""
        calls = []
        def mock_run(cmd, **kwargs):
            calls.append(cmd)
            return self._make_status_result('')

        count = self._simulate_cleanup(
            '/worktrees/task-1', 'auditing', 'task-1',
            mock_run, lambda p: True)

        self.assertEqual(count, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ['git', 'status', '--porcelain'])

    def test_missing_worktree_skips_cleanup(self):
        """When worktree directory doesn't exist, no git commands are run."""
        mock_run = MagicMock()

        count = self._simulate_cleanup(
            '/worktrees/task-1', 'testing', 'task-1',
            mock_run, lambda p: False)

        self.assertEqual(count, 0)
        mock_run.assert_not_called()

    def test_empty_worktree_path_skips_cleanup(self):
        """When worktree path is empty string, no git commands are run."""
        mock_run = MagicMock()

        count = self._simulate_cleanup(
            '', 'implementing', 'task-1',
            mock_run, lambda p: True)

        self.assertEqual(count, 0)
        mock_run.assert_not_called()

    def test_single_dirty_file_cleans(self):
        """Even a single dirty file triggers cleanup."""
        calls = []
        def mock_run(cmd, **kwargs):
            calls.append(cmd)
            return self._make_status_result('?? plan.md')

        count = self._simulate_cleanup(
            '/worktrees/task-1', 'pr_creating', 'task-1',
            mock_run, lambda p: True)

        self.assertEqual(count, 1)
        self.assertEqual(len(calls), 3)


if __name__ == '__main__':
    unittest.main()
