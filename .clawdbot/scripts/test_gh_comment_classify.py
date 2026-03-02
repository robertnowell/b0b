#!/usr/bin/env python3
"""Intent classification tests for GitHub comment routing.

Covers the full intent matrix: action_request, approval, rejection,
question, feedback, and other — with multiple keyword variants and
edge cases.
"""

import json
import subprocess
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("gh-comment-classify.py")


def classify(body: str) -> dict:
    payload = json.dumps({"body": body})
    result = subprocess.run(
        ["python3", str(SCRIPT_PATH)],
        input=payload,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# Action request intent
# ---------------------------------------------------------------------------

class TestActionRequest(unittest.TestCase):
    """Action verbs and polite prefixes should classify as action_request."""

    def test_fix_verb(self):
        out = classify("@kopi-claw fix failing tests")
        self.assertEqual(out["intent"], "action_request")
        self.assertEqual(out["confidence"], "high")

    def test_add_verb(self):
        out = classify("@kopi-claw add error handling to the API")
        self.assertEqual(out["intent"], "action_request")

    def test_implement_verb(self):
        out = classify("@kopi-claw implement dark mode toggle")
        self.assertEqual(out["intent"], "action_request")

    def test_refactor_verb(self):
        out = classify("@kopi-claw refactor the auth module")
        self.assertEqual(out["intent"], "action_request")

    def test_update_verb(self):
        out = classify("@kopi-claw update the README")
        self.assertEqual(out["intent"], "action_request")

    def test_remove_verb(self):
        out = classify("@kopi-claw remove deprecated endpoints")
        self.assertEqual(out["intent"], "action_request")

    def test_polite_can_you(self):
        out = classify("@kopi-claw can you fix the tests?")
        self.assertEqual(out["intent"], "action_request")
        self.assertEqual(out["confidence"], "high")

    def test_polite_could_you(self):
        out = classify("@kopi-claw could you add logging")
        self.assertEqual(out["intent"], "action_request")

    def test_polite_please(self):
        out = classify("@kopi-claw please update the config")
        self.assertEqual(out["intent"], "action_request")

    def test_task_description_strips_polite_prefix(self):
        out = classify("@kopi-claw can you fix the tests")
        self.assertNotIn("can you", out["taskDescription"].lower())
        self.assertTrue(out["taskDescription"][0].isupper())

    def test_product_goal_set_for_action(self):
        out = classify("@kopi-claw add a logout button")
        self.assertTrue(len(out["productGoal"]) > 0)


# ---------------------------------------------------------------------------
# Approval intent
# ---------------------------------------------------------------------------

class TestApproval(unittest.TestCase):
    """Approval keywords should classify as approval with high confidence."""

    def test_approve(self):
        out = classify("@kopi-claw approve")
        self.assertEqual(out["intent"], "approval")
        self.assertEqual(out["confidence"], "high")

    def test_approved(self):
        out = classify("@kopi-claw approved")
        self.assertEqual(out["intent"], "approval")

    def test_lgtm(self):
        out = classify("@kopi-claw lgtm")
        self.assertEqual(out["intent"], "approval")

    def test_looks_good(self):
        out = classify("@kopi-claw looks good")
        self.assertEqual(out["intent"], "approval")

    def test_ship_it(self):
        out = classify("@kopi-claw ship it")
        self.assertEqual(out["intent"], "approval")

    def test_plus_one(self):
        out = classify("@kopi-claw +1")
        self.assertEqual(out["intent"], "approval")

    def test_thumbs_up_emoji(self):
        out = classify("@kopi-claw \U0001f44d")
        self.assertEqual(out["intent"], "approval")

    def test_product_goal_empty_for_approval(self):
        out = classify("@kopi-claw approve")
        self.assertEqual(out["productGoal"], "")


# ---------------------------------------------------------------------------
# Rejection intent
# ---------------------------------------------------------------------------

class TestRejection(unittest.TestCase):
    """Rejection keywords should classify as rejection with high confidence."""

    def test_reject(self):
        out = classify("@kopi-claw reject")
        self.assertEqual(out["intent"], "rejection")
        self.assertEqual(out["confidence"], "high")

    def test_needs_work(self):
        out = classify("@kopi-claw needs work")
        self.assertEqual(out["intent"], "rejection")

    def test_need_work(self):
        out = classify("@kopi-claw need work")
        self.assertEqual(out["intent"], "rejection")

    def test_revise(self):
        out = classify("@kopi-claw revise")
        self.assertEqual(out["intent"], "rejection")

    def test_not_ready(self):
        out = classify("@kopi-claw not ready")
        self.assertEqual(out["intent"], "rejection")

    def test_nack(self):
        out = classify("@kopi-claw nack")
        self.assertEqual(out["intent"], "rejection")

    def test_product_goal_empty_for_rejection(self):
        out = classify("@kopi-claw reject")
        self.assertEqual(out["productGoal"], "")


# ---------------------------------------------------------------------------
# Question intent
# ---------------------------------------------------------------------------

class TestQuestion(unittest.TestCase):
    """Questions (trailing ? or interrogative starts) should classify as question."""

    def test_trailing_question_mark(self):
        out = classify("@kopi-claw what changed?")
        self.assertEqual(out["intent"], "question")

    def test_how_question_no_mark(self):
        out = classify("@kopi-claw how does the auth module work")
        self.assertEqual(out["intent"], "question")
        self.assertEqual(out["confidence"], "medium")

    def test_why_question(self):
        out = classify("@kopi-claw why is this test failing?")
        self.assertEqual(out["intent"], "question")

    def test_is_there_question(self):
        out = classify("@kopi-claw is there a config for this")
        self.assertEqual(out["intent"], "question")

    def test_can_i_lowercase(self):
        """'can i' at start should classify as question, not action_request."""
        out = classify("@kopi-claw can i deploy this to prod?")
        self.assertEqual(out["intent"], "question")

    def test_can_i_uppercase(self):
        """'Can I' should also classify as question after normalization."""
        out = classify("@kopi-claw Can I use this approach?")
        self.assertEqual(out["intent"], "question")


# ---------------------------------------------------------------------------
# Feedback intent
# ---------------------------------------------------------------------------

class TestFeedback(unittest.TestCase):
    """References to existing work should classify as feedback."""

    def test_this_pr(self):
        out = classify("@kopi-claw this PR looks great but needs more tests")
        self.assertEqual(out["intent"], "feedback")

    def test_the_implementation(self):
        out = classify("@kopi-claw the implementation could be cleaner")
        self.assertEqual(out["intent"], "feedback")

    def test_this_approach(self):
        out = classify("@kopi-claw this approach is fragile")
        self.assertEqual(out["intent"], "feedback")

    def test_suggestion(self):
        out = classify("@kopi-claw suggestion: use a map instead of filter")
        self.assertEqual(out["intent"], "feedback")

    def test_consider(self):
        out = classify("@kopi-claw consider using a different data structure here")
        self.assertEqual(out["intent"], "feedback")


# ---------------------------------------------------------------------------
# Other / edge cases
# ---------------------------------------------------------------------------

class TestOtherAndEdgeCases(unittest.TestCase):
    """Unclassifiable inputs and edge cases."""

    def test_empty_body(self):
        out = classify("@kopi-claw")
        self.assertEqual(out["intent"], "other")
        self.assertEqual(out["confidence"], "low")

    def test_just_mention_whitespace(self):
        out = classify("@kopi-claw   ")
        self.assertEqual(out["intent"], "other")

    def test_gibberish(self):
        out = classify("@kopi-claw asdf jkl xyz 123")
        self.assertEqual(out["intent"], "other")
        self.assertEqual(out["confidence"], "low")

    def test_approval_priority_over_action(self):
        """Approval is checked before action verbs."""
        out = classify("@kopi-claw approve the changes")
        self.assertEqual(out["intent"], "approval")

    def test_rejection_priority_over_feedback(self):
        """Rejection is checked before feedback patterns."""
        out = classify("@kopi-claw reject this change")
        self.assertEqual(out["intent"], "rejection")


# ---------------------------------------------------------------------------
# Malformed inputs / robustness
# ---------------------------------------------------------------------------

def classify_raw(payload: dict) -> dict:
    """Send a raw dict (not wrapped in {"body": ...}) to the classifier."""
    raw = json.dumps(payload)
    result = subprocess.run(
        ["python3", str(SCRIPT_PATH)],
        input=raw,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


class TestMalformedInputs(unittest.TestCase):
    """Robustness: the classifier must never crash on bad input."""

    def test_missing_body_key(self):
        out = classify_raw({})
        self.assertEqual(out["intent"], "other")

    def test_body_is_none(self):
        out = classify_raw({"body": None})
        self.assertEqual(out["intent"], "other")

    def test_body_is_number(self):
        out = classify_raw({"body": 123})
        self.assertIn(out["intent"], ("other", "question", "feedback", "action_request", "approval", "rejection"))

    def test_partial_word_fixation(self):
        out = classify("@kopi-claw fixation of the code")
        self.assertNotEqual(out["intent"], "action_request")

    def test_partial_word_additional(self):
        out = classify("@kopi-claw additional context here")
        self.assertNotEqual(out["intent"], "action_request")

    def test_partial_word_optimization(self):
        out = classify("@kopi-claw optimization plan")
        self.assertNotEqual(out["intent"], "action_request")

    def test_very_long_body(self):
        body = "@kopi-claw " + "x" * 10000
        out = classify(body)
        self.assertIn(out["intent"], ("other", "question", "feedback", "action_request", "approval", "rejection"))

    def test_unicode_body(self):
        out = classify("@kopi-claw fix the 日本語 emoji 🎉 handling")
        self.assertEqual(out["intent"], "action_request")

    def test_only_whitespace_after_mention(self):
        out = classify("@kopi-claw \n\t ")
        self.assertEqual(out["intent"], "other")


if __name__ == "__main__":
    unittest.main()
