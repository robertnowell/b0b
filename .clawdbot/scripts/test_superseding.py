#!/usr/bin/env python3
"""Tests for get_superseding_task() in monitor.sh.

Validates version ordering, phase awareness, parentTaskId linkage,
terminal phase filtering, and explicit supersededBy support.
"""

import re
import unittest


# ---------------------------------------------------------------------------
# Extract the function under test (mirrors the embedded Python in monitor.sh)
# ---------------------------------------------------------------------------

PHASE_ORDER = ['planning', 'plan_review', 'implementing', 'auditing',
               'fixing', 'testing', 'pr_creating', 'reviewing',
               'pr_ready', 'merged']


def phase_rank(phase):
    try:
        return PHASE_ORDER.index(phase)
    except ValueError:
        return -1


TERMINAL_PHASES = {'failed', 'needs_split', 'split'}


def get_superseding_task(tid, all_tasks):
    """Check if another active task makes this dead task redundant.

    1. Explicit 'supersededBy' field on the task.
    2. Explicit 'parentTaskId' linkage (phase check only).
    3. Convention: same base name (-vN suffix), higher version, at least as advanced phase.
    """
    # Find our own task to get our phase
    my_task = None
    for t in all_tasks:
        if t.get('id') == tid:
            my_task = t
            break

    # 1. Explicit supersededBy field
    if my_task and my_task.get('supersededBy'):
        return my_task['supersededBy']

    my_phase = my_task.get('phase', '') if my_task else ''
    my_rank = phase_rank(my_phase)

    # Parse our version
    match = re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)
    my_version = int(match.group(2)) if match.group(2) else 0

    best_candidate = None
    best_score = None
    for t in all_tasks:
        other_id = t.get('id', '')
        if other_id == tid:
            continue

        # Skip terminal tasks
        if t.get('phase', '') in TERMINAL_PHASES:
            continue

        # Determine relationship: explicit child->parent linkage or same base name
        is_linked = (t.get('parentTaskId') == tid)

        other_match = re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        other_base = other_match.group(1)
        is_same_base = (other_base == base)

        if not is_linked and not is_same_base:
            continue

        # Version check: only for same-base tasks (not parentTaskId-linked)
        if is_same_base and not is_linked:
            other_version = int(other_match.group(2)) if other_match.group(2) else 0
            if other_version <= my_version:
                continue

        # Phase check: superseder must be at least as far along
        other_rank = phase_rank(t.get('phase', ''))
        if other_rank < my_rank:
            continue

        score = (other_rank, int(other_match.group(2)) if other_match.group(2) else 0)
        if best_score is None or score > best_score:
            best_candidate = other_id
            best_score = score

    return best_candidate


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestExplicitSupersededBy(unittest.TestCase):
    """Returns supersededBy field immediately, bypassing all checks."""

    def test_returns_superseded_by(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning', 'supersededBy': 'task-v2'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_superseded_by_takes_priority_over_convention(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'testing', 'supersededBy': 'unrelated'},
            {'id': 'task-v2', 'phase': 'merged'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'unrelated')


class TestVersionOrdering(unittest.TestCase):
    """Higher versions supersede, lower/equal don't."""

    def test_higher_version_supersedes(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_lower_version_does_not_supersede(self):
        """task-v1 alive should NOT supersede task-v2 dead."""
        tasks = [
            {'id': 'task-v2', 'phase': 'planning'},
            {'id': 'task-v1', 'phase': 'implementing'},
        ]
        self.assertIsNone(get_superseding_task('task-v2', tasks))

    def test_equal_version_does_not_supersede(self):
        """Two tasks with same version (both no suffix) don't supersede."""
        tasks = [
            {'id': 'task', 'phase': 'planning'},
            {'id': 'task', 'phase': 'implementing'},  # same id, would be skipped
        ]
        self.assertIsNone(get_superseding_task('task', tasks))

    def test_same_base_both_no_suffix(self):
        """Neither supersedes when both have version 0."""
        tasks = [
            {'id': 'my-feature', 'phase': 'planning'},
            {'id': 'my-feature-extra', 'phase': 'implementing'},
        ]
        # Different base names — no superseding
        self.assertIsNone(get_superseding_task('my-feature', tasks))

    def test_no_suffix_vs_v1(self):
        """task (v0) can be superseded by task-v1."""
        tasks = [
            {'id': 'task', 'phase': 'planning'},
            {'id': 'task-v1', 'phase': 'planning'},
        ]
        self.assertEqual(get_superseding_task('task', tasks), 'task-v1')

    def test_v3_supersedes_v1(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v3', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v3')


class TestPhaseAwareness(unittest.TestCase):
    """Superseder must be at least as advanced in the pipeline."""

    def test_higher_phase_supersedes(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_lower_phase_does_not_supersede(self):
        """task-v2 in planning should NOT supersede task-v1 dead in testing."""
        tasks = [
            {'id': 'task-v1', 'phase': 'testing'},
            {'id': 'task-v2', 'phase': 'planning'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_equal_phase_supersedes(self):
        """Same phase, higher version → supersede."""
        tasks = [
            {'id': 'task-v1', 'phase': 'implementing'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_phase_order_auditing_before_testing(self):
        """Confirm auditing (rank 3) < testing (rank 5) in the pipeline."""
        self.assertLess(phase_rank('auditing'), phase_rank('testing'))

    def test_phase_order_fixing_between_auditing_and_testing(self):
        """Fixing (rank 4) sits between auditing (3) and testing (5)."""
        self.assertGreater(phase_rank('fixing'), phase_rank('auditing'))
        self.assertLess(phase_rank('fixing'), phase_rank('testing'))

    def test_v2_in_testing_supersedes_v1_dead_in_fixing(self):
        """testing (rank 5) >= fixing (rank 4) → supersede."""
        tasks = [
            {'id': 'task-v1', 'phase': 'fixing'},
            {'id': 'task-v2', 'phase': 'testing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_v2_in_auditing_does_not_supersede_v1_dead_in_fixing(self):
        """auditing (rank 3) < fixing (rank 4) → no supersede."""
        tasks = [
            {'id': 'task-v1', 'phase': 'fixing'},
            {'id': 'task-v2', 'phase': 'auditing'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))


class TestTerminalPhases(unittest.TestCase):
    """Failed/needs_split/split tasks can't supersede; merged/reviewing CAN."""

    def test_failed_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'failed'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_needs_split_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'needs_split'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_split_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'split'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_merged_can_supersede(self):
        """merged is NOT terminal — v2 in merged supersedes v1."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'merged'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_reviewing_can_supersede(self):
        """reviewing is NOT terminal — v2 in reviewing supersedes v1."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'reviewing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_pr_ready_can_supersede(self):
        """pr_ready is NOT terminal."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'pr_ready'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')


class TestParentTaskId(unittest.TestCase):
    """Linked tasks bypass version check, phase check still applies."""

    def test_parent_link_supersedes_without_version(self):
        """parentTaskId-linked child supersedes parent (no version check needed)."""
        tasks = [
            {'id': 'old-task', 'phase': 'planning'},
            {'id': 'new-task', 'phase': 'implementing', 'parentTaskId': 'old-task'},
        ]
        self.assertEqual(get_superseding_task('old-task', tasks), 'new-task')

    def test_parent_link_with_different_base_names(self):
        """parentTaskId works even with completely different task IDs."""
        tasks = [
            {'id': 'feature-auth', 'phase': 'planning'},
            {'id': 'feature-login-v2', 'phase': 'implementing', 'parentTaskId': 'feature-auth'},
        ]
        self.assertEqual(get_superseding_task('feature-auth', tasks), 'feature-login-v2')

    def test_parent_link_phase_check_still_applies(self):
        """Even with parentTaskId, superseder must be at least as advanced."""
        tasks = [
            {'id': 'old-task', 'phase': 'testing'},
            {'id': 'new-task', 'phase': 'planning', 'parentTaskId': 'old-task'},
        ]
        self.assertIsNone(get_superseding_task('old-task', tasks))

    def test_parent_does_not_supersede_child(self):
        """Parent should not supersede child via reverse parentTaskId matching."""
        tasks = [
            {'id': 'child-task', 'phase': 'planning', 'parentTaskId': 'parent-task'},
            {'id': 'parent-task', 'phase': 'implementing'},
        ]
        self.assertIsNone(get_superseding_task('child-task', tasks))

    def test_parent_link_terminal_still_filtered(self):
        """parentTaskId-linked task in terminal phase doesn't supersede."""
        tasks = [
            {'id': 'old-task', 'phase': 'planning'},
            {'id': 'new-task', 'phase': 'failed', 'parentTaskId': 'old-task'},
        ]
        self.assertIsNone(get_superseding_task('old-task', tasks))


class TestBaseName(unittest.TestCase):
    """Only same-base or linked tasks are candidates."""

    def test_different_base_no_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'other-task-v2', 'phase': 'implementing'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_unrelated_task_ignored(self):
        tasks = [
            {'id': 'feature-auth-v1', 'phase': 'planning'},
            {'id': 'feature-ui-v2', 'phase': 'merged'},
        ]
        self.assertIsNone(get_superseding_task('feature-auth-v1', tasks))

    def test_task_not_found_still_supersedes(self):
        """If our task isn't in the list, higher version can still supersede."""
        tasks = [
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        # Dead task not in list → phase unknown (rank -1), version parsed from tid
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')


class TestCombined(unittest.TestCase):
    """Version + phase + terminal interactions."""

    def test_v2_planning_does_not_supersede_v1_testing(self):
        """Higher version but lower phase → no supersede."""
        tasks = [
            {'id': 'task-v1', 'phase': 'testing'},
            {'id': 'task-v2', 'phase': 'planning'},
        ]
        self.assertIsNone(get_superseding_task('task-v1', tasks))

    def test_v2_implementing_supersedes_v1_planning(self):
        """Higher version + higher phase → supersede."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_v1_implementing_does_not_supersede_v2_planning(self):
        """Lower version, even if higher phase → no supersede (version required)."""
        tasks = [
            {'id': 'task-v2', 'phase': 'planning'},
            {'id': 'task-v1', 'phase': 'implementing'},
        ]
        self.assertIsNone(get_superseding_task('task-v2', tasks))

    def test_best_candidate_wins(self):
        """When multiple candidates exist, pick the best (highest rank, then version)."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
            {'id': 'task-v3', 'phase': 'testing'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v3')

    def test_skip_terminal_pick_active(self):
        """Skip failed v3, pick active v2."""
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
            {'id': 'task-v3', 'phase': 'failed'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')

    def test_unknown_phase_rank_negative_one(self):
        """Unknown phases get rank -1 (never block superseding)."""
        self.assertEqual(phase_rank('banana'), -1)

    def test_unknown_phase_does_not_block(self):
        """Dead task with unknown phase can be superseded by any known phase."""
        tasks = [
            {'id': 'task-v1', 'phase': 'banana'},
            {'id': 'task-v2', 'phase': 'planning'},
        ]
        self.assertEqual(get_superseding_task('task-v1', tasks), 'task-v2')


class TestMonitorShParity(unittest.TestCase):
    """Extract get_superseding_task from monitor.sh and verify it matches."""

    @classmethod
    def setUpClass(cls):
        """Extract and compile the function from the embedded Python in monitor.sh."""
        import os
        monitor_path = os.path.join(os.path.dirname(__file__), 'monitor.sh')
        with open(monitor_path, 'r') as f:
            content = f.read()

        # Extract the Python block (between 'python3 -c "' and the closing '"')
        py_start = content.find('python3 -c "')
        assert py_start != -1, "Could not find python3 -c block in monitor.sh"
        py_code = content[py_start + len('python3 -c "'):]
        # Find the closing quote (line starts with '"')
        lines = py_code.split('\n')
        py_lines = []
        for line in lines:
            if line.startswith('" '):
                break
            py_lines.append(line)
        py_code = '\n'.join(py_lines)

        # Unescape shell-escaped characters (embedded in double-quoted string)
        py_code = py_code.replace('\\"', '"')

        # Execute just the function definition in an isolated namespace
        func_start = py_code.find('def get_superseding_task(tid, all_tasks):')
        assert func_start != -1, "Could not find get_superseding_task in monitor.sh Python block"
        # Find the end of the function (next unindented line that isn't blank)
        func_lines = py_code[func_start:].split('\n')
        func_body = []
        for i, line in enumerate(func_lines):
            if i > 0 and line and not line[0].isspace() and not line.startswith('#'):
                break
            func_body.append(line)
        func_code = '\n'.join(func_body)

        ns = {}
        exec(func_code, ns)
        cls._monitor_func = ns['get_superseding_task']

    def _call(self, tid, tasks):
        return self.__class__._monitor_func(tid, tasks)

    def test_higher_version_supersedes(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(self._call('task-v1', tasks), 'task-v2')

    def test_lower_version_does_not_supersede(self):
        tasks = [
            {'id': 'task-v2', 'phase': 'planning'},
            {'id': 'task-v1', 'phase': 'implementing'},
        ]
        self.assertIsNone(self._call('task-v2', tasks))

    def test_lower_phase_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'testing'},
            {'id': 'task-v2', 'phase': 'planning'},
        ]
        self.assertIsNone(self._call('task-v1', tasks))

    def test_failed_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'failed'},
        ]
        self.assertIsNone(self._call('task-v1', tasks))

    def test_split_does_not_supersede(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'split'},
        ]
        self.assertIsNone(self._call('task-v1', tasks))

    def test_parent_link_supersedes(self):
        tasks = [
            {'id': 'old-task', 'phase': 'planning'},
            {'id': 'new-task', 'phase': 'implementing', 'parentTaskId': 'old-task'},
        ]
        self.assertEqual(self._call('old-task', tasks), 'new-task')

    def test_parent_link_phase_check(self):
        tasks = [
            {'id': 'old-task', 'phase': 'testing'},
            {'id': 'new-task', 'phase': 'planning', 'parentTaskId': 'old-task'},
        ]
        self.assertIsNone(self._call('old-task', tasks))

    def test_explicit_superseded_by(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning', 'supersededBy': 'task-v2'},
            {'id': 'task-v2', 'phase': 'implementing'},
        ]
        self.assertEqual(self._call('task-v1', tasks), 'task-v2')

    def test_best_candidate_wins(self):
        tasks = [
            {'id': 'task-v1', 'phase': 'planning'},
            {'id': 'task-v2', 'phase': 'implementing'},
            {'id': 'task-v3', 'phase': 'testing'},
        ]
        self.assertEqual(self._call('task-v1', tasks), 'task-v3')


if __name__ == '__main__':
    unittest.main()
