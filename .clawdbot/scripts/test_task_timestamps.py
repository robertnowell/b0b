#!/usr/bin/env python3
"""Tests for pipeline task timestamp features.

Covers:
  - Age computation logic (check-agents.sh)
  - createdAt preservation across respawns (spawn-agent.sh)
  - JSONL outbox started_at inclusion (notify.sh)
"""

import json
import unittest
from datetime import datetime, timedelta, timezone


# ---------------------------------------------------------------------------
# Helpers — replicate the logic from the shell/Python blocks under test
# ---------------------------------------------------------------------------

def compute_age(started, now):
    """Replicate the age computation from check-agents.sh."""
    elapsed_seconds = None
    age_str = ''
    if started:
        try:
            start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
            elapsed = (now - start_dt).total_seconds()
            elapsed_seconds = int(elapsed)
            if elapsed < 60:
                age_str = f'{int(elapsed)}s'
            elif elapsed < 3600:
                age_str = f'{int(elapsed // 60)}m'
            elif elapsed < 86400:
                h, m = int(elapsed // 3600), int((elapsed % 3600) // 60)
                age_str = f'{h}h {m}m'
            else:
                d, h = int(elapsed // 86400), int((elapsed % 86400) // 3600)
                age_str = f'{d}d {h}h'
        except (ValueError, TypeError):
            pass
    return age_str, elapsed_seconds


def register_task(tasks, task_id, started_at, existing=None):
    """Replicate the createdAt logic from spawn-agent.sh."""
    created_at = started_at
    iteration = 0
    findings = []
    fix_target = 'auditing'

    if existing:
        iteration = existing.get('iteration', 0)
        findings = existing.get('findings', [])
        fix_target = existing.get('fixTarget', 'auditing')
        created_at = existing.get('createdAt', existing.get('startedAt', started_at))
        tasks = [t for t in tasks if t.get('id') != task_id]

    entry = {
        'id': task_id,
        'startedAt': started_at,
        'createdAt': created_at,
        'iteration': iteration,
        'findings': findings,
        'fixTarget': fix_target,
    }
    tasks.append(entry)
    return entry, tasks


def build_outbox_entry(task_id, phase, product_goal, next_step, plan_file, started_at):
    """Replicate the JSONL outbox entry logic from notify.sh."""
    entry = {
        'task_id': task_id,
        'phase': phase,
        'message': 'test message',
        'product_goal': product_goal,
        'next_step': next_step,
        'text': 'notification text',
    }
    if plan_file:
        entry['planFile'] = plan_file
    if started_at:
        entry['started_at'] = started_at
    return entry


# ---------------------------------------------------------------------------
# Tests — Age computation (check-agents.sh logic)
# ---------------------------------------------------------------------------

class TestAgeComputation(unittest.TestCase):
    """Test the age/elapsedSeconds computation from check-agents.sh."""

    def test_age_seconds(self):
        """30 seconds elapsed → '30s', elapsedSeconds=30."""
        now = datetime(2026, 3, 1, 12, 0, 30, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '30s')
        self.assertEqual(elapsed, 30)

    def test_age_minutes(self):
        """5 minutes elapsed → '5m', elapsedSeconds=300."""
        now = datetime(2026, 3, 1, 12, 5, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '5m')
        self.assertEqual(elapsed, 300)

    def test_age_hours_minutes(self):
        """2h 15m elapsed → '2h 15m', elapsedSeconds=8100."""
        now = datetime(2026, 3, 1, 14, 15, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '2h 15m')
        self.assertEqual(elapsed, 8100)

    def test_age_days_hours(self):
        """1d 3h elapsed → '1d 3h', elapsedSeconds=97200."""
        now = datetime(2026, 3, 2, 15, 0, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '1d 3h')
        self.assertEqual(elapsed, 97200)

    def test_age_missing_started_at(self):
        """No startedAt → empty age, None elapsed."""
        now = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('', now)
        self.assertEqual(age, '')
        self.assertIsNone(elapsed)

    def test_age_none_started_at(self):
        """None startedAt → empty age, None elapsed."""
        now = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age(None, now)
        self.assertEqual(age, '')
        self.assertIsNone(elapsed)

    def test_age_malformed_timestamp(self):
        """Malformed timestamp → empty age, None elapsed."""
        now = datetime(2026, 3, 1, 12, 0, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('not-a-date', now)
        self.assertEqual(age, '')
        self.assertIsNone(elapsed)

    def test_age_boundary_60s(self):
        """Exactly 60 seconds → '1m' (not '60s')."""
        now = datetime(2026, 3, 1, 12, 1, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '1m')
        self.assertEqual(elapsed, 60)

    def test_age_boundary_1h(self):
        """Exactly 3600 seconds → '1h 0m'."""
        now = datetime(2026, 3, 1, 13, 0, 0, tzinfo=timezone.utc)
        age, elapsed = compute_age('2026-03-01T12:00:00Z', now)
        self.assertEqual(age, '1h 0m')
        self.assertEqual(elapsed, 3600)


# ---------------------------------------------------------------------------
# Tests — createdAt preservation (spawn-agent.sh logic)
# ---------------------------------------------------------------------------

class TestCreatedAtPreservation(unittest.TestCase):
    """Test createdAt field logic in spawn-agent.sh."""

    def test_created_at_new_task(self):
        """New task: createdAt == startedAt."""
        tasks = []
        entry, tasks = register_task(tasks, 'task-1', '2026-03-01T10:00:00Z')
        self.assertEqual(entry['createdAt'], '2026-03-01T10:00:00Z')
        self.assertEqual(entry['startedAt'], entry['createdAt'])

    def test_created_at_preserved_on_respawn(self):
        """Respawned task keeps original createdAt."""
        existing = {
            'id': 'task-1',
            'startedAt': '2026-03-01T10:00:00Z',
            'createdAt': '2026-03-01T10:00:00Z',
            'iteration': 1,
        }
        tasks = [existing]
        entry, tasks = register_task(
            tasks, 'task-1', '2026-03-01T11:00:00Z', existing=existing
        )
        self.assertEqual(entry['createdAt'], '2026-03-01T10:00:00Z')
        self.assertEqual(entry['startedAt'], '2026-03-01T11:00:00Z')

    def test_created_at_fallback_to_started_at(self):
        """Legacy task without createdAt falls back to startedAt."""
        existing = {
            'id': 'task-1',
            'startedAt': '2026-03-01T09:00:00Z',
            'iteration': 2,
        }
        tasks = [existing]
        entry, tasks = register_task(
            tasks, 'task-1', '2026-03-01T12:00:00Z', existing=existing
        )
        self.assertEqual(entry['createdAt'], '2026-03-01T09:00:00Z')
        self.assertEqual(entry['startedAt'], '2026-03-01T12:00:00Z')

    def test_created_at_fallback_to_new_started_at(self):
        """Legacy task without createdAt or startedAt falls back to new startedAt."""
        existing = {
            'id': 'task-1',
            'iteration': 1,
        }
        tasks = [existing]
        entry, tasks = register_task(
            tasks, 'task-1', '2026-03-01T14:00:00Z', existing=existing
        )
        self.assertEqual(entry['createdAt'], '2026-03-01T14:00:00Z')


# ---------------------------------------------------------------------------
# Tests — JSONL outbox (notify.sh logic)
# ---------------------------------------------------------------------------

class TestOutboxEntry(unittest.TestCase):
    """Test JSONL outbox entry construction from notify.sh."""

    def test_outbox_includes_started_at(self):
        """JSONL entry includes started_at when provided."""
        entry = build_outbox_entry(
            'task-1', 'implementing', 'Goal', 'Next', '', '2026-03-01T10:00:00Z'
        )
        self.assertEqual(entry['started_at'], '2026-03-01T10:00:00Z')

    def test_outbox_empty_started_at(self):
        """JSONL entry omits started_at when not provided."""
        entry = build_outbox_entry(
            'task-1', 'implementing', 'Goal', 'Next', '', ''
        )
        self.assertNotIn('started_at', entry)

    def test_outbox_includes_plan_file(self):
        """JSONL entry includes planFile when provided."""
        entry = build_outbox_entry(
            'task-1', 'plan_review', 'Goal', 'Next', '/tmp/plan.md', ''
        )
        self.assertEqual(entry['planFile'], '/tmp/plan.md')

    def test_outbox_basic_fields(self):
        """JSONL entry always has core fields."""
        entry = build_outbox_entry(
            'task-1', 'implementing', 'Goal', 'Next', '', ''
        )
        self.assertEqual(entry['task_id'], 'task-1')
        self.assertEqual(entry['phase'], 'implementing')
        self.assertEqual(entry['product_goal'], 'Goal')
        self.assertEqual(entry['next_step'], 'Next')


if __name__ == '__main__':
    unittest.main()
