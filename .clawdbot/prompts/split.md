# Task Split Planning

## Original Task
{TASK_DESCRIPTION}

## Product Goal
{PRODUCT_GOAL}

## Task ID
{TASK_ID}

## Previous Findings (why this task failed)
{FINDINGS}

## Instructions

This task exceeded its iteration budget and could not be completed as a single unit.
Your job is to analyze WHY it failed and split it into 2-4 smaller, independently
completable subtasks.

### Rules
1. Each subtask must be self-contained and independently testable
2. Subtasks should not depend on each other (can run in parallel)
3. Each subtask must be simpler than the original task
4. Aim for 2-3 subtasks (4 only if truly necessary)
5. Each subtask description must be specific and actionable

### Output Format

Output a JSON array with this exact structure at the end of your response:

```
SPLIT_RESULT:[
  {"suffix": "part1", "description": "Specific description of subtask 1"},
  {"suffix": "part2", "description": "Specific description of subtask 2"}
]
```

The `SPLIT_RESULT:` prefix must appear on its own line, followed immediately by the JSON array.
The `suffix` will be appended to the parent task ID (e.g., `my-task-part1`).
Use short, descriptive suffixes like `ui`, `api`, `tests`, `refactor`, etc.
