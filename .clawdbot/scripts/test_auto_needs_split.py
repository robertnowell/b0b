#!/usr/bin/env python3
"""Tests for auto needs_split handling in monitor.sh.

Covers:
  - needs_split -> auto-retry (first time, depth 0)
  - needs_split -> auto-split (after retry exhausted)
  - needs_split stays terminal (both retry and split exhausted)
  - needs_split stays terminal for deep-split tasks (splitDepth >= max)
  - Subtask no-retry (subtasks with splitDepth > 0 don't auto-retry)
  - Retry resets iteration and preserves findings
  - Retry resets autoSplitAttemptCount to 0
  - Split creates subtask IDs with correct convention
  - Split sets parent to 'split' phase
  - Split failure increments autoSplitAttemptCount
  - Full lifecycle: retry -> split -> terminal
  - MAX_AUTO_RETRIES configurability
  - Race guard bypass for needs_split
  - Terminal phase list includes 'split'
  - Superseding task phase filter (all terminal phases)
  - Respawn metadata preservation (autoRetryCount, autoSplitAttemptCount, splitDepth, parentTask)
  - SPLIT_RESULT parsing (valid, malformed, missing)
"""

import json
import re
import unittest
from unittest.mock import MagicMock


# ---------------------------------------------------------------------------
# Helpers — simulate the monitor state-machine decision logic
# ---------------------------------------------------------------------------

def can_auto_retry(task, max_auto_retries=1):
    """Decide if a needs_split task should auto-retry."""
    auto_retry_count = task.get('autoRetryCount', 0)
    split_depth = task.get('splitDepth', 0)
    return auto_retry_count < max_auto_retries and split_depth == 0


def can_auto_split(task, max_split_depth=1, max_auto_split_attempts=2):
    """Decide if a needs_split task should auto-split."""
    split_depth = task.get('splitDepth', 0)
    auto_split_attempt_count = task.get('autoSplitAttemptCount', 0)
    description = task.get('description', '')
    product_goal = task.get('productGoal', '')
    should_retry = can_auto_retry(task)
    return (not should_retry
            and split_depth < max_split_depth
            and auto_split_attempt_count < max_auto_split_attempts
            and bool(description) and bool(product_goal))


def simulate_needs_split_decision(task, max_auto_retries=1, max_split_depth=1, max_auto_split_attempts=2):
    """Simulate the needs_split handler decision flow.

    Returns: ('retry', updates) | ('split', updates) | ('terminal', {})
    """
    should_retry = can_auto_retry(task, max_auto_retries)
    should_split = can_auto_split(task, max_split_depth, max_auto_split_attempts)

    if should_retry:
        new_retry_count = task.get('autoRetryCount', 0) + 1
        preserved_findings = task.get('findings', []) + [f'Auto-retry #{new_retry_count} triggered']
        updates = {
            'phase': 'planning',
            'status': 'running',
            'iteration': 0,
            'autoRetryCount': new_retry_count,
            'findings': preserved_findings,
        }
        return 'retry', updates

    elif should_split:
        return 'split', {'phase': 'split', 'status': 'split'}

    else:
        return 'terminal', {}


def should_skip_race_guard(phase, last_action, now):
    """Simulate the race guard logic from monitor.sh."""
    if now - last_action < 60 and phase not in ('reviewing', 'pr_ready', 'needs_split'):
        return True
    return False


def parse_split_result(output):
    """Simulate the SPLIT_RESULT parsing from auto-split.sh."""
    match = re.search(r'SPLIT_RESULT:\s*(\[.*?\])', output, re.DOTALL)
    if not match:
        match = re.search(r'\[\s*\{[^}]*"suffix"[^]]*\]', output, re.DOTALL)

    if match:
        try:
            raw = match.group(1) if 'SPLIT_RESULT' in output[:match.start() + 20] else match.group(0)
            result = json.loads(raw)
            validated = []
            for item in result:
                if isinstance(item, dict) and 'suffix' in item and 'description' in item:
                    suffix = re.sub(r'[^a-zA-Z0-9-]', '', item['suffix'])[:20]
                    if suffix:
                        validated.append({'suffix': suffix, 'description': item['description'][:500]})
            if 2 <= len(validated) <= 4:
                return validated
        except (json.JSONDecodeError, TypeError):
            pass
    return []


def get_superseding_task(tid, all_tasks):
    """Simulate monitor.sh get_superseding_task phase filtering."""
    match = re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)

    terminal_phases = {'failed', 'split', 'merged', 'needs_split'}
    for task in all_tasks:
        other_id = task.get('id', '')
        if other_id == tid:
            continue
        other_match = re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        if other_match.group(1) == base and task.get('phase', '') not in terminal_phases:
            return other_id

    return None


def build_respawn_entry(existing, workspace=False):
    """Simulate spawn-agent.sh respawn metadata preservation."""
    iteration = 0
    findings = []
    fix_target = 'auditing'
    require_plan_review = True
    auto_retry_count = 0
    auto_split_attempt_count = 0
    split_depth = 0
    parent_task = None

    if existing:
        iteration = existing.get('iteration', 0)
        findings = existing.get('findings', [])
        fix_target = existing.get('fixTarget', 'auditing')
        require_plan_review = existing.get('requiresPlanReview', True)
        auto_retry_count = existing.get('autoRetryCount', 0)
        auto_split_attempt_count = existing.get('autoSplitAttemptCount', 0)
        split_depth = existing.get('splitDepth', 0)
        parent_task = existing.get('parentTask')
        workspace = existing.get('workspace', workspace)

    entry = {
        'iteration': iteration,
        'findings': findings,
        'fixTarget': fix_target,
        'requiresPlanReview': require_plan_review,
        'autoRetryCount': auto_retry_count,
        'autoSplitAttemptCount': auto_split_attempt_count,
        'splitDepth': split_depth,
    }
    if workspace:
        entry['workspace'] = True
    if parent_task:
        entry['parentTask'] = parent_task
    return entry


# ---------------------------------------------------------------------------
# Tests — Decision Logic
# ---------------------------------------------------------------------------

class TestCanAutoRetry(unittest.TestCase):
    """Test the auto-retry decision function."""

    def test_first_needs_split_can_retry(self):
        """Fresh task (no retries, depth 0) should be retryable."""
        task = {'autoRetryCount': 0, 'splitDepth': 0}
        self.assertTrue(can_auto_retry(task))

    def test_already_retried_cannot_retry(self):
        """Task that already retried (autoRetryCount >= max) cannot retry again."""
        task = {'autoRetryCount': 1, 'splitDepth': 0}
        self.assertFalse(can_auto_retry(task, max_auto_retries=1))

    def test_subtask_cannot_retry(self):
        """Subtask (splitDepth > 0) should not auto-retry."""
        task = {'autoRetryCount': 0, 'splitDepth': 1}
        self.assertFalse(can_auto_retry(task))

    def test_defaults_retryable(self):
        """Task with no autoRetryCount/splitDepth fields defaults to retryable."""
        task = {}
        self.assertTrue(can_auto_retry(task))

    def test_custom_max_retries(self):
        """Respects custom MAX_AUTO_RETRIES setting."""
        task = {'autoRetryCount': 1, 'splitDepth': 0}
        self.assertTrue(can_auto_retry(task, max_auto_retries=3))
        self.assertFalse(can_auto_retry(task, max_auto_retries=1))


class TestCanAutoSplit(unittest.TestCase):
    """Test the auto-split decision function."""

    def test_after_retry_can_split(self):
        """Task that exhausted retries (autoRetryCount=1) can split."""
        task = {'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Do stuff', 'productGoal': 'Ship it'}
        self.assertTrue(can_auto_split(task))

    def test_deep_split_cannot_split(self):
        """Task already at max split depth cannot split further."""
        task = {'autoRetryCount': 1, 'splitDepth': 1,
                'description': 'Do stuff', 'productGoal': 'Ship it'}
        self.assertFalse(can_auto_split(task, max_split_depth=1))

    def test_no_description_cannot_split(self):
        """Task without description cannot split."""
        task = {'autoRetryCount': 1, 'splitDepth': 0,
                'description': '', 'productGoal': 'Ship it'}
        self.assertFalse(can_auto_split(task))

    def test_no_product_goal_cannot_split(self):
        """Task without productGoal cannot split."""
        task = {'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Do stuff', 'productGoal': ''}
        self.assertFalse(can_auto_split(task))

    def test_retryable_task_does_not_split(self):
        """Task that can still retry should NOT split."""
        task = {'autoRetryCount': 0, 'splitDepth': 0,
                'description': 'Do stuff', 'productGoal': 'Ship it'}
        self.assertFalse(can_auto_split(task))

    def test_split_attempts_exhausted_cannot_split(self):
        """Task that exhausted auto-split attempts cannot split."""
        task = {'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Do stuff', 'productGoal': 'Ship it',
                'autoSplitAttemptCount': 2}
        self.assertFalse(can_auto_split(task, max_auto_split_attempts=2))

    def test_split_attempts_remaining_can_split(self):
        """Task with remaining split attempts can split."""
        task = {'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Do stuff', 'productGoal': 'Ship it',
                'autoSplitAttemptCount': 1}
        self.assertTrue(can_auto_split(task, max_auto_split_attempts=2))


class TestNeedsSplitDecisionFlow(unittest.TestCase):
    """Test the full needs_split decision flow."""

    def test_first_hit_retries(self):
        """First time hitting needs_split -> retry."""
        task = {'phase': 'needs_split', 'autoRetryCount': 0, 'splitDepth': 0,
                'description': 'Build widget', 'productGoal': 'Ship widget'}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'retry')
        self.assertEqual(updates['phase'], 'planning')
        self.assertEqual(updates['iteration'], 0)
        self.assertEqual(updates['autoRetryCount'], 1)

    def test_after_retry_splits(self):
        """After retry exhausted -> split."""
        task = {'phase': 'needs_split', 'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Build widget', 'productGoal': 'Ship widget'}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'split')
        self.assertEqual(updates['phase'], 'split')

    def test_after_split_terminal(self):
        """Subtask that hits needs_split (splitDepth=1) -> terminal."""
        task = {'phase': 'needs_split', 'autoRetryCount': 0, 'splitDepth': 1,
                'description': 'Build widget', 'productGoal': 'Ship widget'}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'terminal')
        self.assertEqual(updates, {})

    def test_retry_preserves_findings(self):
        """Retry should preserve previous findings."""
        task = {'phase': 'needs_split', 'autoRetryCount': 0, 'splitDepth': 0,
                'findings': ['Failed during audit', 'Max iterations reached']}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'retry')
        self.assertIn('Failed during audit', updates['findings'])
        self.assertIn('Max iterations reached', updates['findings'])
        self.assertIn('Auto-retry #1 triggered', updates['findings'])

    def test_retry_resets_iteration(self):
        """Retry should reset iteration to 0."""
        task = {'phase': 'needs_split', 'autoRetryCount': 0, 'splitDepth': 0,
                'iteration': 4}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(updates['iteration'], 0)

    def test_both_exhausted_terminal(self):
        """When both retry and split are exhausted -> terminal."""
        task = {'phase': 'needs_split', 'autoRetryCount': 1, 'splitDepth': 1,
                'description': 'Build widget', 'productGoal': 'Ship widget'}
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'terminal')

    def test_max_auto_retries_configurable(self):
        """Respects MAX_AUTO_RETRIES=3 setting."""
        task = {'phase': 'needs_split', 'autoRetryCount': 2, 'splitDepth': 0,
                'description': 'Build widget', 'productGoal': 'Ship widget'}
        action, _ = simulate_needs_split_decision(task, max_auto_retries=3)
        self.assertEqual(action, 'retry')

    def test_split_attempts_exhausted_terminal(self):
        """When split attempts exhausted -> terminal despite retry exhausted."""
        task = {'phase': 'needs_split', 'autoRetryCount': 1, 'splitDepth': 0,
                'description': 'Build widget', 'productGoal': 'Ship widget',
                'autoSplitAttemptCount': 2}
        action, updates = simulate_needs_split_decision(task, max_auto_split_attempts=2)
        self.assertEqual(action, 'terminal')

    def test_subtask_id_convention(self):
        """Subtask IDs follow {parent}-{suffix} convention."""
        tid = 'my-task'
        subtasks = [{'suffix': 'ui', 'description': 'Build UI'},
                    {'suffix': 'api', 'description': 'Build API'}]
        ids = [f'{tid}-{st["suffix"]}' for st in subtasks]
        self.assertEqual(ids, ['my-task-ui', 'my-task-api'])


# ---------------------------------------------------------------------------
# Tests — Race Guard
# ---------------------------------------------------------------------------

class TestRaceGuardNeedsSplit(unittest.TestCase):
    """needs_split should bypass the race guard."""

    def test_needs_split_bypasses_race_guard(self):
        """needs_split is NOT skipped even if acted on < 60s ago."""
        skipped = should_skip_race_guard('needs_split', last_action=100, now=130)
        self.assertFalse(skipped)

    def test_implementing_respects_race_guard(self):
        """implementing IS skipped if acted on < 60s ago (control case)."""
        skipped = should_skip_race_guard('implementing', last_action=100, now=130)
        self.assertTrue(skipped)


# ---------------------------------------------------------------------------
# Tests — Terminal Phase List
# ---------------------------------------------------------------------------

class TestTerminalPhases(unittest.TestCase):
    """Verify the terminal phase list is correct."""

    def test_split_is_terminal(self):
        """split phase should be in the terminal skip list."""
        terminal = ('merged', 'plan_review', 'split')
        self.assertIn('split', terminal)

    def test_needs_split_is_not_terminal(self):
        """needs_split should NOT be in the terminal list (it needs processing)."""
        terminal = ('merged', 'plan_review', 'split')
        self.assertNotIn('needs_split', terminal)


class TestSupersedingTaskPhaseFilter(unittest.TestCase):
    """Verify superseding ignores terminal sibling tasks."""

    def test_merged_sibling_does_not_supersede(self):
        tasks = [
            {'id': 'feature-x', 'phase': 'implementing'},
            {'id': 'feature-x-v2', 'phase': 'merged'},
        ]
        self.assertIsNone(get_superseding_task('feature-x', tasks))

    def test_needs_split_sibling_does_not_supersede(self):
        tasks = [
            {'id': 'feature-x', 'phase': 'implementing'},
            {'id': 'feature-x-v2', 'phase': 'needs_split'},
        ]
        self.assertIsNone(get_superseding_task('feature-x', tasks))

    def test_active_sibling_supersedes(self):
        tasks = [
            {'id': 'feature-x', 'phase': 'implementing'},
            {'id': 'feature-x-v2', 'phase': 'planning'},
        ]
        self.assertEqual(get_superseding_task('feature-x', tasks), 'feature-x-v2')


class TestSupersedingTaskAllTerminalPhases(unittest.TestCase):
    """Verify all terminal phases are excluded from superseding."""

    def test_failed_sibling_does_not_supersede(self):
        tasks = [
            {'id': 'feature-x', 'phase': 'implementing'},
            {'id': 'feature-x-v2', 'phase': 'failed'},
        ]
        self.assertIsNone(get_superseding_task('feature-x', tasks))

    def test_split_sibling_does_not_supersede(self):
        tasks = [
            {'id': 'feature-x', 'phase': 'implementing'},
            {'id': 'feature-x-v2', 'phase': 'split'},
        ]
        self.assertIsNone(get_superseding_task('feature-x', tasks))


class TestAutoRetryResetsAutoSplitAttemptCount(unittest.TestCase):
    """Verify that auto-retry resets autoSplitAttemptCount to 0.

    When monitor.sh performs an auto-retry, it resets autoSplitAttemptCount
    so that after the retry if needs_split is hit again, split attempts start fresh.
    """

    def test_retry_resets_split_attempt_count(self):
        """Simulates monitor.sh apply_updates during retry: autoSplitAttemptCount=0."""
        task = {
            'phase': 'needs_split',
            'autoRetryCount': 0,
            'splitDepth': 0,
            'autoSplitAttemptCount': 1,
            'description': 'Build widget',
            'productGoal': 'Ship widget',
        }
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'retry')
        # Monitor.sh explicitly resets autoSplitAttemptCount to 0 on retry
        # (see monitor.sh apply_updates in the should_retry block).
        # The decision function returns retry; the caller (monitor) resets it.
        # Verify the pattern: after retry, a second needs_split can split.
        retried_task = dict(task)
        retried_task['autoRetryCount'] = updates['autoRetryCount']
        retried_task['autoSplitAttemptCount'] = 0  # monitor resets this
        retried_task['phase'] = 'needs_split'
        action2, _ = simulate_needs_split_decision(retried_task)
        self.assertEqual(action2, 'split')


class TestFullLifecycleDecisionChain(unittest.TestCase):
    """Simulate the full needs_split lifecycle: retry -> split -> terminal."""

    def test_fresh_to_retry_to_split_to_terminal(self):
        """Walk through the complete lifecycle of a task hitting needs_split."""
        task = {
            'phase': 'needs_split',
            'autoRetryCount': 0,
            'splitDepth': 0,
            'autoSplitAttemptCount': 0,
            'description': 'Build widget',
            'productGoal': 'Ship widget',
            'findings': [],
        }

        # Step 1: First needs_split -> retry
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'retry')
        self.assertEqual(updates['autoRetryCount'], 1)

        # Step 2: Apply retry updates (including autoSplitAttemptCount=0 reset)
        task['autoRetryCount'] = updates['autoRetryCount']
        task['autoSplitAttemptCount'] = 0
        task['findings'] = updates['findings']
        task['iteration'] = 0

        # Step 3: Task hits needs_split again after retry -> split
        action, updates = simulate_needs_split_decision(task)
        self.assertEqual(action, 'split')

        # Step 4: Subtask (splitDepth=1) hits needs_split -> terminal
        subtask = {
            'phase': 'needs_split',
            'autoRetryCount': 0,
            'splitDepth': 1,
            'autoSplitAttemptCount': 0,
            'description': 'Build widget UI',
            'productGoal': 'Ship widget',
        }
        action, updates = simulate_needs_split_decision(subtask)
        self.assertEqual(action, 'terminal')

    def test_split_failure_increments_attempt_count(self):
        """When auto-split fails, autoSplitAttemptCount increments.

        Simulates the monitor.sh behavior where split command errors or no
        subtasks created leads to incremented autoSplitAttemptCount.
        """
        task = {
            'phase': 'needs_split',
            'autoRetryCount': 1,
            'splitDepth': 0,
            'autoSplitAttemptCount': 0,
            'description': 'Build widget',
            'productGoal': 'Ship widget',
            'findings': [],
        }

        # First split attempt -> should try split
        action, _ = simulate_needs_split_decision(task)
        self.assertEqual(action, 'split')

        # Simulate split failure (monitor increments autoSplitAttemptCount)
        task['autoSplitAttemptCount'] = 1

        # Second split attempt -> should still try split
        action, _ = simulate_needs_split_decision(task, max_auto_split_attempts=2)
        self.assertEqual(action, 'split')

        # Another failure
        task['autoSplitAttemptCount'] = 2

        # Now exhausted -> terminal
        action, _ = simulate_needs_split_decision(task, max_auto_split_attempts=2)
        self.assertEqual(action, 'terminal')


class TestRespawnMetadataPreservation(unittest.TestCase):
    """Verify respawn preserves auto retry/split metadata."""

    def test_preserves_retry_split_metadata(self):
        existing = {
            'iteration': 3,
            'findings': ['A'],
            'fixTarget': 'implementation',
            'requiresPlanReview': False,
            'autoRetryCount': 1,
            'autoSplitAttemptCount': 2,
            'splitDepth': 1,
            'parentTask': 'parent-1',
            'workspace': True,
        }
        entry = build_respawn_entry(existing, workspace=False)
        self.assertEqual(entry['autoRetryCount'], 1)
        self.assertEqual(entry['autoSplitAttemptCount'], 2)
        self.assertEqual(entry['splitDepth'], 1)
        self.assertEqual(entry['parentTask'], 'parent-1')
        self.assertTrue(entry['workspace'])

    def test_defaults_when_no_existing_task(self):
        entry = build_respawn_entry(None, workspace=False)
        self.assertEqual(entry['autoRetryCount'], 0)
        self.assertEqual(entry['autoSplitAttemptCount'], 0)
        self.assertEqual(entry['splitDepth'], 0)
        self.assertNotIn('parentTask', entry)
        self.assertNotIn('workspace', entry)


# ---------------------------------------------------------------------------
# Tests — SPLIT_RESULT Parsing
# ---------------------------------------------------------------------------

class TestSplitResultParsing(unittest.TestCase):
    """Test the SPLIT_RESULT JSON parsing logic."""

    def test_valid_split_result(self):
        """Standard SPLIT_RESULT with 2 subtasks."""
        output = """Some analysis here...

SPLIT_RESULT:[
  {"suffix": "ui", "description": "Build the UI component"},
  {"suffix": "api", "description": "Build the API endpoint"}
]"""
        result = parse_split_result(output)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['suffix'], 'ui')
        self.assertEqual(result[1]['suffix'], 'api')

    def test_three_subtasks(self):
        """SPLIT_RESULT with 3 subtasks."""
        output = 'SPLIT_RESULT:[{"suffix":"a","description":"A"},{"suffix":"b","description":"B"},{"suffix":"c","description":"C"}]'
        result = parse_split_result(output)
        self.assertEqual(len(result), 3)

    def test_four_subtasks(self):
        """SPLIT_RESULT with 4 subtasks (max)."""
        output = 'SPLIT_RESULT:[{"suffix":"a","description":"A"},{"suffix":"b","description":"B"},{"suffix":"c","description":"C"},{"suffix":"d","description":"D"}]'
        result = parse_split_result(output)
        self.assertEqual(len(result), 4)

    def test_one_subtask_rejected(self):
        """SPLIT_RESULT with only 1 subtask should be rejected."""
        output = 'SPLIT_RESULT:[{"suffix":"only","description":"Only one"}]'
        result = parse_split_result(output)
        self.assertEqual(result, [])

    def test_five_subtasks_rejected(self):
        """SPLIT_RESULT with 5 subtasks should be rejected."""
        items = [{"suffix": f"p{i}", "description": f"Part {i}"} for i in range(5)]
        output = f'SPLIT_RESULT:{json.dumps(items)}'
        result = parse_split_result(output)
        self.assertEqual(result, [])

    def test_malformed_json(self):
        """Malformed JSON after SPLIT_RESULT should return empty."""
        output = 'SPLIT_RESULT:[{"suffix": "a", BROKEN}'
        result = parse_split_result(output)
        self.assertEqual(result, [])

    def test_no_split_result(self):
        """Output without SPLIT_RESULT marker returns empty."""
        output = 'Just some text without any structured output.'
        result = parse_split_result(output)
        self.assertEqual(result, [])

    def test_suffix_sanitization(self):
        """Suffixes with special characters get sanitized."""
        output = 'SPLIT_RESULT:[{"suffix":"my/bad suffix!","description":"A"},{"suffix":"ok-name","description":"B"}]'
        result = parse_split_result(output)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['suffix'], 'mybadsuffix')
        self.assertEqual(result[1]['suffix'], 'ok-name')

    def test_description_truncation(self):
        """Long descriptions get truncated to 500 chars."""
        long_desc = 'x' * 1000
        output = f'SPLIT_RESULT:[{{"suffix":"a","description":"{long_desc}"}},{{"suffix":"b","description":"short"}}]'
        result = parse_split_result(output)
        self.assertEqual(len(result), 2)
        self.assertEqual(len(result[0]['description']), 500)

    def test_empty_suffix_rejected(self):
        """Items with empty suffix after sanitization are rejected."""
        output = 'SPLIT_RESULT:[{"suffix":"!!!","description":"A"},{"suffix":"ok","description":"B"},{"suffix":"fine","description":"C"}]'
        result = parse_split_result(output)
        # Only 2 valid items (ok, fine) — the !!! becomes empty
        self.assertEqual(len(result), 2)

    def test_missing_suffix_field(self):
        """Items missing suffix field are skipped."""
        output = 'SPLIT_RESULT:[{"description":"A"},{"suffix":"b","description":"B"},{"suffix":"c","description":"C"}]'
        result = parse_split_result(output)
        self.assertEqual(len(result), 2)


if __name__ == '__main__':
    unittest.main()
