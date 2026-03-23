#!/usr/bin/env python3
"""Classify whether PR feedback needs a tweak (direct fix) or a rethink (re-plan).

Reads JSON from stdin: {"feedback": "...", "taskDescription": "...", "lastPlan": "..."}
Outputs JSON to stdout: {"route": "tweak"|"rethink", "reason": "one sentence"}

Uses Claude Haiku for fast, cheap classification.
"""
import json
import subprocess
import sys


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        # Fallback: treat as rethink if we can't parse
        json.dump({"route": "rethink", "reason": "Failed to parse input"}, sys.stdout)
        sys.stdout.write("\n")
        return

    feedback = input_data.get("feedback", "")
    task_desc = input_data.get("taskDescription", "")
    last_plan = input_data.get("lastPlan", "")

    if not feedback:
        json.dump({"route": "tweak", "reason": "Empty feedback"}, sys.stdout)
        sys.stdout.write("\n")
        return

    prompt = (
        "You are classifying code review feedback to decide the next step.\n\n"
        "Reply with ONLY a JSON object (no markdown, no explanation):\n"
        '{"route": "tweak" or "rethink", "reason": "one sentence why"}\n\n'
        "Definitions:\n"
        '- "tweak": The feedback asks for small, targeted changes — style fixes, '
        "missed edge cases, minor bugs, naming improvements, adding a log line, etc. "
        "The current approach/architecture is correct, just needs adjustments.\n"
        '- "rethink": The feedback says the approach is wrong, the fix didn\'t work, '
        "the root cause is different, or a fundamentally different solution is needed. "
        "Signals: 'this didn't work', 'doesn't solve the root issue', 'wrong approach', "
        "'still failing', 'please do this properly', 'need to rethink'.\n\n"
        "When in doubt, choose rethink — it's safer to re-plan than to ship a bad fix.\n\n"
        f"Original task:\n{task_desc}\n\n"
    )
    if last_plan:
        prompt += f"Current plan:\n{last_plan[:1000]}\n\n"
    prompt += f"Feedback:\n{feedback}"

    try:
        result = subprocess.run(
            ["claude", "--model", "claude-haiku-4-5-20251001", "-p", prompt],
            capture_output=True, text=True, timeout=30
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        # Fallback: rethink is safer
        json.dump({
            "route": "rethink",
            "reason": f"LLM classification failed ({type(e).__name__}), defaulting to rethink"
        }, sys.stdout)
        sys.stdout.write("\n")
        return

    if result.returncode == 0 and result.stdout.strip():
        output = result.stdout.strip()
        # Handle markdown wrapping
        if output.startswith("```"):
            lines = output.split("\n")
            output = "\n".join(lines[1:-1] if lines[-1].startswith("```") else lines[1:])
        try:
            parsed = json.loads(output)
            route = parsed.get("route", "rethink")
            if route not in ("tweak", "rethink"):
                route = "rethink"
            json.dump({"route": route, "reason": parsed.get("reason", "")}, sys.stdout)
            sys.stdout.write("\n")
            return
        except json.JSONDecodeError:
            pass

    # Fallback: rethink is safer
    json.dump({
        "route": "rethink",
        "reason": "LLM classification failed to parse, defaulting to rethink"
    }, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
