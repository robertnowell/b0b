#!/usr/bin/env python3
"""Process GitHub comments for @kopi-claw mentions."""
import json, sys

MENTION = "@kopi-claw"

state_file = sys.argv[1]
now = sys.argv[2]
issue_comments_file = sys.argv[3]
review_comments_file = sys.argv[4]

state = json.load(open(state_file))
seen = set(state.get("seenCommentIds", []))

with open(issue_comments_file) as f:
    issue_comments = json.load(f)
with open(review_comments_file) as f:
    review_comments = json.load(f)

new_seen = list(seen)

for c in issue_comments:
    if MENTION in c.get("body", "") and c["id"] not in seen:
        issue_url = c.get("issue_url", "")
        number = issue_url.rstrip("/").split("/")[-1] if issue_url else "unknown"
        print(json.dumps({
            "type": "comment",
            "commentId": c["id"],
            "number": number,
            "author": c["user"]["login"],
            "body": c["body"][:500],
            "url": c["html_url"],
            "created": c["created_at"]
        }))
        new_seen.append(c["id"])

for c in review_comments:
    if MENTION in c.get("body", "") and c["id"] not in seen:
        pr_url = c.get("pull_request_url", "")
        number = pr_url.rstrip("/").split("/")[-1] if pr_url else "unknown"
        print(json.dumps({
            "type": "review_comment",
            "commentId": c["id"],
            "number": number,
            "author": c["user"]["login"],
            "body": c["body"][:500],
            "url": c["html_url"],
            "created": c["created_at"]
        }))
        new_seen.append(c["id"])

# Update state — keep last 200 IDs
state = {"lastChecked": now, "seenCommentIds": new_seen[-200:]}
json.dump(state, open(state_file, "w"), indent=2)
