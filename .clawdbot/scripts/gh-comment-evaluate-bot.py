#!/usr/bin/env python3
"""Evaluate whether a bot review comment requires actual code changes.

Reads comment body from stdin, outputs JSON to stdout:
  {"needsChanges": true/false, "taskDescription": "...", "reason": "..."}

Uses Claude Haiku for fast, cheap evaluation.
"""
import json
import subprocess
import sys


def main():
    body = sys.stdin.read().strip()
    if not body:
        json.dump({"needsChanges": False, "taskDescription": "", "reason": "Empty body"}, sys.stdout)
        sys.stdout.write("\n")
        return

    prompt = (
        "You are evaluating a code review bot's comment. Determine if it identifies "
        "real bugs or suggests changes that would genuinely improve the code.\n\n"
        "Reply with ONLY a JSON object (no markdown, no explanation):\n"
        '{"needsChanges": true or false, "taskDescription": "brief description of what needs to change (empty if no changes)", "reason": "one sentence why"}\n\n'
        "Rules:\n"
        "- needsChanges=true ONLY if the review identifies real bugs, security issues, or clearly beneficial improvements\n"
        "- needsChanges=false for style-only suggestions, nitpicks, or 'no issues found' messages\n"
        '- taskDescription should be actionable (e.g. "Fix variable shadowing bug in spawn-agent.sh")\n\n'
        "Bot comment:\n"
        f"{body}"
    )

    try:
        result = subprocess.run(
            ["claude", "--model", "claude-haiku-4-5-20251001", "-p", prompt],
            capture_output=True, text=True, timeout=30
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        # Fallback: if Claude CLI unavailable or times out, dispatch anyway
        json.dump({
            "needsChanges": True,
            "taskDescription": body[:200],
            "reason": f"LLM evaluation failed ({type(e).__name__}), dispatching as precaution"
        }, sys.stdout)
        sys.stdout.write("\n")
        return

    if result.returncode == 0 and result.stdout.strip():
        # Try to extract JSON from the response (handle markdown wrapping)
        output = result.stdout.strip()
        if output.startswith("```"):
            lines = output.split("\n")
            output = "\n".join(lines[1:-1] if lines[-1].startswith("```") else lines[1:])
        try:
            parsed = json.loads(output)
            json.dump(parsed, sys.stdout)
            sys.stdout.write("\n")
            return
        except json.JSONDecodeError:
            pass

    # Fallback: dispatch anyway if we can't parse
    json.dump({
        "needsChanges": True,
        "taskDescription": body[:200],
        "reason": "LLM evaluation failed to parse, dispatching as precaution"
    }, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
