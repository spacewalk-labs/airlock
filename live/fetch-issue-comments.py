#!/usr/bin/env python3
"""Fetch a tracking issue's comments using nothing but the standard library.

The runner this job runs on has curl, jq, git and python3 3.12, and no `gh` —
that missing binary is the whole of why the one run that got far enough to try
died with `command not found` and exit 127. Installing it would mean changing a
container shared with other repositories, which is an infrastructure change with
an approval gate on it. Reading the API directly is not, and it is the same two
requests `gh issue view --json comments` would have made.

Writes what live-freshness.py already reads: a JSON list of {createdAt, body}.
The key is renamed here because the REST API says `created_at` and `gh` said
`createdAt`, and the judge is the tested half — it should not have to know which
fetcher ran.

It lives here rather than beside the judge in `.github/scripts/` because that directory
is not classified in `docs/airlock/sot-cutline.yaml`, and the cutline guard rejects a
changed path it cannot classify — correctly, that is the whole of its job. The judge only
escapes because it has not changed since the guard was installed. `live/` is where the
weekly verification already lives (`verify.sh`, `alarm.sh`, `verdict.py`, the units), it
is classified, and `install/test-live-timer.sh` already covers it. Classifying
`.github/scripts/` would mean editing a cross-repository migration SoT, which is a larger
and unrelated change than adding one fetcher.

Everything that is not a complete answer raises. A fetch that half-works and
writes a short list is, downstream, indistinguishable from a schedule that
stopped firing; this file lives inside a check whose entire purpose is to tell
those two apart, so it must not be the thing that confuses them. Pagination is
the specific way that happens: the API returns 30 comments per page by default
and the oldest first, so a fetcher that reads one page and stops hands the judge
a list with the newest result missing, and the judge correctly calls that stale.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"


def fetch(url: str, token: str):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "airlock-live-freshness",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r), r.headers.get("Link", "")


def next_link(link_header: str):
    # RFC 5988, as GitHub writes it: <url>; rel="next", <url>; rel="last"
    for part in link_header.split(","):
        m = re.match(r'\s*<([^>]+)>\s*;\s*rel="next"', part)
        if m:
            return m.group(1)
    return None


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <issue-number> <out.json>")
    issue, out = sys.argv[1], sys.argv[2]

    token = os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        sys.exit("::error::GITHUB_TOKEN is empty. Without it this reads nothing and "
                 "an empty list is not a verdict.")

    repo = os.environ.get("GITHUB_REPOSITORY") or ""
    if not repo:
        sys.exit("::error::GITHUB_REPOSITORY is empty; there is no issue to read.")

    url = f"{API}/repos/{repo}/issues/{issue}/comments?per_page=100"
    comments = []
    pages = 0
    while url:
        try:
            page, link = fetch(url, token)
        except urllib.error.HTTPError as e:
            # The 404 note is specific to 404 and used to be printed for every code,
            # which sent a rate-limited 403 looking for a deleted issue.
            hint = ""
            if e.code == 404:
                hint = (f" On a private repository a 404 here means either issue "
                        f"#{issue} is gone or the workflow token lacks `issues: read`.")
            elif e.code in (403, 429):
                hint = " 403/429 here is a rate limit, not a permission problem."
            sys.exit(f"::error::GET {url} -> HTTP {e.code}.{hint}")
        except urllib.error.URLError as e:
            sys.exit(f"::error::GET {url} failed: {e.reason}")
        if not isinstance(page, list):
            sys.exit(f"::error::GET {url} returned {type(page).__name__}, not a list.")
        comments.extend(page)
        pages += 1
        url = next_link(link)

    shaped = [{"createdAt": c["created_at"], "body": c.get("body") or ""}
              for c in comments]
    with open(out, "w") as f:
        json.dump(shaped, f)
    print(f"fetched {len(shaped)} comments from {repo}#{issue} over {pages} page(s)")


if __name__ == "__main__":
    main()
