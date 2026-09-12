"""Turn timestamps in rendered learning documents into YouTube links.

The transform is deliberately applied to rendered HTML, not the saved Markdown or
HTML.  It is deterministic and idempotent: existing anchors and the transcript
section are left untouched.
"""

import re
from urllib.parse import parse_qs, quote, unquote, urlsplit


TS_FULL = re.compile(r"(?<![0-9])[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?![0-9])")
TS_ANY = re.compile(
    r"(?<![0-9])(?:[0-9]{1,2}:[0-9]{2}:[0-9]{2}|[0-9]{1,2}:[0-9]{2})(?![:0-9])"
)
VIDEO_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "www.youtu.be",
}
TRANSCRIPT = re.compile(
    r"<details\b[^>]*\bclass\s*=\s*([\"'])[^\"']*\btranscript\b[^\"']*\1[^>]*>",
    re.IGNORECASE,
)

# The document template does not nest divs inside .doc-meta, so its first closing
# div is the measured boundary.  Tags themselves are skipped last so timestamps in
# attributes are never changed.
SKIP = (
    re.compile(r"<a\b.*?</a\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(
        r"<div\b[^>]*\bclass\s*=\s*([\"'])[^\"']*\bdoc-meta\b[^\"']*\1[^>]*>"
        r".*?</div\s*>",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(r"<pre\b.*?</pre\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<script\b.*?</script\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<style\b.*?</style\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<!--.*?-->", re.DOTALL),
    re.compile(r"<[^>]*>"),
)
CODE = re.compile(r"<code\b[^>]*>.*?</code\s*>", re.IGNORECASE | re.DOTALL)


def timestamp_seconds(text):
    """Convert H:MM:SS or M:SS text to seconds."""
    parts = [int(part) for part in text.split(":")]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return parts[0] * 60 + parts[1]


def youtube_watch_url(url):
    """Return a canonical YouTube watch URL, or ``None`` for an unknown URL."""
    if not isinstance(url, str):
        return None
    try:
        parsed = urlsplit(url.strip())
        hostname = (parsed.hostname or "").lower().rstrip(".")
    except ValueError:
        return None
    if parsed.scheme.lower() not in ("http", "https") or hostname not in YOUTUBE_HOSTS:
        return None

    video_id = ""
    if hostname in {"youtu.be", "www.youtu.be"}:
        video_id = parsed.path.strip("/").split("/", 1)[0]
    else:
        query = parse_qs(parsed.query, keep_blank_values=True)
        if query.get("v"):
            video_id = query["v"][0]
        if not video_id:
            parts = [part for part in parsed.path.split("/") if part]
            if len(parts) >= 2 and parts[0].lower() in {"embed", "live", "shorts"}:
                video_id = parts[1]
    video_id = unquote(video_id)
    if not VIDEO_ID_RE.fullmatch(video_id):
        return None
    return "https://www.youtube.com/watch?v=" + quote(video_id, safe="-_")


def _spans(body, patterns):
    return [match.span() for pattern in patterns for match in pattern.finditer(body)]


def _within(ranges, start, end):
    return any(low <= start and end <= high for low, high in ranges)


def link_timestamps(html, video_url):
    """Link timestamps before the transcript and return ``(html, link_count)``.

    Plain text accepts H:MM:SS only.  M:SS is accepted inside ``code`` because
    ordinary prose also uses that shape for ratios and scores.
    """
    watch_url = youtube_watch_url(video_url)
    if not watch_url:
        return html, 0

    transcript = TRANSCRIPT.search(html)
    boundary = transcript.start() if transcript else len(html)
    body, tail = html[:boundary], html[boundary:]
    skip = _spans(body, SKIP)
    code = _spans(body, (CODE,))
    edits = []
    for found in TS_ANY.finditer(body):
        start, end = found.span()
        if _within(skip, start, end):
            continue
        in_code = _within(code, start, end)
        if not in_code and not TS_FULL.fullmatch(found.group(0)):
            continue
        edits.append((start, end, found.group(0)))

    for start, end, text in reversed(edits):
        anchor = (
            f'<a href="{watch_url}&t={timestamp_seconds(text)}s" '
            f'target="_blank" rel="noopener">{text}</a>'
        )
        body = body[:start] + anchor + body[end:]
    return body + tail, len(edits)
