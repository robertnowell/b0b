#!/usr/bin/env python3
"""Process GitHub comments for @kopi-claw mentions."""
import json, sys

MENTION = "@kopi-claw"

state_file = sys.argv[1]
now = sys.argv[2]
issue_comments_file = sys.argv[3]
review_comments_file = sys.argv[4]


def get_comment_body(comment):
    body = comment.get("body", "")
    return body if isinstance(body, str) else ""


def get_comment_author(comment):
    user = comment.get("user")
    if isinstance(user, dict):
        login = user.get("login", "unknown")
        return login if isinstance(login, str) and login else "unknown"
    return "unknown"

state = json.load(open(state_file))
seen = set(state.get("seenCommentIds", []))

with open(issue_comments_file) as f:
    issue_comments = json.load(f)
with open(review_comments_file) as f:
    review_comments = json.load(f)

new_seen = list(seen)

for c in issue_comments:
    comment_id = c.get("id")
    body = get_comment_body(c)
    if comment_id is None:
        continue
    if MENTION in body and comment_id not in seen:
        issue_url = c.get("issue_url", "")
        number = issue_url.rstrip("/").split("/")[-1] if issue_url else "unknown"
        if not number.isdigit():
            number = "unknown"
        is_pr = "/pulls/" in issue_url or "/pull/" in issue_url
        print(json.dumps({
            "type": "comment",
            "commentId": comment_id,
            "number": number,
            "author": get_comment_author(c),
            "body": body[:500],
            "url": c.get("html_url", ""),
            "created": c.get("created_at", ""),
            "isPR": is_pr
        }))
        seen.add(comment_id)
        new_seen.append(comment_id)

for c in review_comments:
    comment_id = c.get("id")
    body = get_comment_body(c)
    if comment_id is None:
        continue
    if MENTION in body and comment_id not in seen:
        pr_url = c.get("pull_request_url", "")
        number = pr_url.rstrip("/").split("/")[-1] if pr_url else "unknown"
        if not number.isdigit():
            number = "unknown"
        print(json.dumps({
            "type": "review_comment",
            "commentId": comment_id,
            "number": number,
            "author": get_comment_author(c),
            "body": body[:500],
            "url": c.get("html_url", ""),
            "created": c.get("created_at", ""),
            "isPR": True
        }))
        seen.add(comment_id)
        new_seen.append(comment_id)

# Update state — keep last 200 IDs
state = {"lastChecked": now, "seenCommentIds": new_seen[-200:]}
json.dump(state, open(state_file, "w"), indent=2)
