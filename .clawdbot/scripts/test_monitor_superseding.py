#!/usr/bin/env python3
"""Tests for get_superseding_task behavior in monitor.sh."""

import pathlib
import unittest


def load_get_superseding_task():
    """Load get_superseding_task directly from monitor.sh's embedded Python."""
    monitor_path = pathlib.Path(__file__).with_name('monitor.sh')
    content = monitor_path.read_text()

    start = content.find('def get_superseding_task(')
    if start == -1:
        raise RuntimeError('Could not find get_superseding_task in monitor.sh')

    end = content.find('\n# --- Main state machine ---', start)
    if end == -1:
        raise RuntimeError('Could not find end marker for get_superseding_task in monitor.sh')

    function_source = content[start:end].replace('\\"', '"')
    namespace = {}
    exec(function_source, namespace)
    return namespace['get_superseding_task']


GET_SUPERSEDING_TASK = load_get_superseding_task()


class TestGetSupersedingTask(unittest.TestCase):
    def test_needs_split_task_does_not_supersede(self):
        """A same-base task in needs_split is terminal and must not supersede."""
        tasks = [
            {'id': 'task-1', 'phase': 'implementing'},
            {'id': 'task-1-v2', 'phase': 'needs_split'},
        ]

        superseding = GET_SUPERSEDING_TASK('task-1', tasks)

        self.assertIsNone(superseding)

    def test_split_task_does_not_supersede(self):
        """A same-base task in split is terminal and must not supersede."""
        tasks = [
            {'id': 'task-1', 'phase': 'implementing'},
            {'id': 'task-1-v2', 'phase': 'split'},
        ]

        superseding = GET_SUPERSEDING_TASK('task-1', tasks)

        self.assertIsNone(superseding)

    def test_failed_task_does_not_supersede(self):
        """A same-base task in failed is terminal and must not supersede."""
        tasks = [
            {'id': 'task-1', 'phase': 'implementing'},
            {'id': 'task-1-v2', 'phase': 'failed'},
        ]

        superseding = GET_SUPERSEDING_TASK('task-1', tasks)

        self.assertIsNone(superseding)


if __name__ == '__main__':
    unittest.main()
