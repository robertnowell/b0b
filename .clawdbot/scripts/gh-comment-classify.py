#!/usr/bin/env python3
"""Classify a GitHub @kopi-claw comment by intent.

Reads a single JSON comment from stdin, outputs classification JSON to stdout.

Intent categories:
  action_request — Work request (implement, fix, add, etc.)
  feedback       — Feedback on existing PR/issue work
  approval       — Plan approval signal
  rejection      — Plan rejection signal
  question       — Question, no action needed
  other          — Can't classify confidently
"""
import json
import re
import sys


def classify(comment: dict) -> dict:
    body = comment.get("body") or ""
    if not isinstance(body, str):
        body = str(body)
    # Strip the @kopi-claw mention
    cleaned = re.sub(r"@kopi-claw\b\s*", "", body, flags=re.IGNORECASE).strip()
    lower = cleaned.lower()

    # 1. Approval keywords (exact/near-exact)
    approval_patterns = [
        r"^approve\b", r"^approved\b", r"^lgtm\b", r"^looks good\b",
        r"^ship it\b", r"^\+1\b", r"^👍$",
    ]
    if any(re.match(p, lower) for p in approval_patterns):
        return _result("approval", cleaned, "high")

    # 2. Rejection keywords
    rejection_patterns = [
        r"^reject\b", r"^rejected\b", r"^needs? work\b", r"^revise\b",
        r"^not ready\b", r"^nack\b",
    ]
    if any(re.match(p, lower) for p in rejection_patterns):
        return _result("rejection", cleaned, "high")

    # 3. Action request — action verbs or polite request phrases
    action_verbs = (
        r"(?:add|fix|implement|create|update|refactor|change|remove|delete|"
        r"move|rename|extract|split|merge|optimize|build|set up|configure|"
        r"write|make|migrate|convert|replace|install|enable|disable|upgrade)\b"
    )
    polite_prefixes = r"(?:can you|could you|would you|please)\b"
    if re.match(polite_prefixes, lower):
        return _result("action_request", _extract_task(cleaned), "high")
    if re.match(action_verbs, lower):
        return _result("action_request", _extract_task(cleaned), "high")

    # 4. Question markers
    if lower.rstrip().endswith("?"):
        return _result("question", cleaned, "high")
    question_starts = (
        r"^(?:what|how|why|where|when|is there|does|do you|have you|"
        r"are there|can i|should)"
    )
    if re.match(question_starts, lower):
        return _result("question", cleaned, "medium")

    # 5. Feedback — references existing work
    feedback_patterns = [
        r"this pr\b", r"this change\b", r"the implementation\b",
        r"the code\b", r"this approach\b", r"this looks\b",
        r"nice work\b", r"one thing\b", r"consider\b",
        r"instead of\b", r"might want to\b", r"suggestion\b",
    ]
    if any(re.search(p, lower) for p in feedback_patterns):
        return _result("feedback", cleaned, "medium")

    # 6. Default
    return _result("other", cleaned, "low")


def _extract_task(text: str) -> str:
    """Remove politeness prefixes and normalize for task description."""
    desc = re.sub(
        r"^(?:can you|could you|would you|please)\s+",
        "", text, flags=re.IGNORECASE,
    ).strip()
    # Capitalize first letter
    if desc:
        desc = desc[0].upper() + desc[1:]
    return desc[:200]


def _result(intent: str, text: str, confidence: str) -> dict:
    task_desc = text
    if intent == "action_request":
        task_desc = _extract_task(text)
    elif intent in ("approval", "rejection"):
        task_desc = text
    return {
        "intent": intent,
        "taskDescription": task_desc,
        "productGoal": task_desc if intent == "action_request" else "",
        "confidence": confidence,
    }


def main():
    comment = json.load(sys.stdin)
    body = comment.get("body") or ""
    if not isinstance(body, str):
        body = str(body)
    body = body.strip()
    # Empty body after stripping mention
    cleaned = re.sub(r"@kopi-claw\b\s*", "", body, flags=re.IGNORECASE).strip()
    if not cleaned:
        result = {"intent": "other", "taskDescription": "", "productGoal": "", "confidence": "low"}
    else:
        result = classify(comment)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
