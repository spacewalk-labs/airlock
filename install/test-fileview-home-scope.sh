#!/usr/bin/env bash
# Above home is not reachable — measured against the real filebrowser, not argued.
#
# fileview runs `filebrowser --root %h`: the tree is the home directory of the
# account the user service runs as, and the operator asked for home to be a hard
# scope rather than a starting position (2026-09-04). "There is a --root flag" is
# not that claim. What is asserted here is the claim itself: a request for a file
# above home returns no file — over `..` chains, encoded `..`, absolute paths, and
# symlinks that leave the tree — while the ordinary case still works.
#
# The positive control is the point of the file: every negative below runs in the
# same server, in the same session, next to a read of a file INSIDE home that must
# succeed. Without it, a server that answers nothing at all would pass.
#
# The binary: the one this box installed (~/.local/bin/filebrowser) or $FILEBROWSER
# if set; otherwise the pinned release is downloaded and sha256-verified with the
# same version and digests apps/fileview/install.sh uses. There is deliberately no
# skip path — a scope test that quietly does not run is the failure it is meant to
# catch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

FB_VER=2.63.18
TMP="$(mktemp -d)"
FBPID=""
cleanup() {
  [ -n "$FBPID" ] && kill "$FBPID" 2>/dev/null
  [ -n "$FBPID" ] && wait "$FBPID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- the binary, and the version it must be ---------------------------------
FB="${FILEBROWSER:-$HOME/.local/bin/filebrowser}"
if [ ! -x "$FB" ]; then FB="$(command -v filebrowser || true)"; fi
if [ -z "$FB" ] || [ ! -x "$FB" ]; then
  case "$(uname -m)" in
    x86_64)  asset=linux-amd64-filebrowser.tar.gz; sha=cd599c34afad0e8e61c577d1061c820bccb7feaa3c5a4477a12db586a1cd93ff ;;
    aarch64) asset=linux-arm64-filebrowser.tar.gz; sha=29b3935c222d91522874e98dfa33195ee7d2acdac5dfbf37c1361a73704a28de ;;
    *) echo "FAIL unsupported arch $(uname -m) — no pinned filebrowser to fetch"; exit 1 ;;
  esac
  url="https://github.com/filebrowser/filebrowser/releases/download/v${FB_VER}/${asset}"
  curl -fsSL --max-time 90 -o "$TMP/fb.tgz" "$url" \
    || { echo "FAIL could not download the pinned filebrowser ($url)"; exit 1; }
  got="$(sha256sum "$TMP/fb.tgz" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { echo "FAIL filebrowser sha256 mismatch got=$got want=$sha"; exit 1; }
  tar -xzf "$TMP/fb.tgz" -C "$TMP" filebrowser || { echo "FAIL filebrowser extract failed"; exit 1; }
  FB="$TMP/filebrowser"; chmod +x "$FB"
fi
# The pinned version is part of the measurement: followExternalSymlinks is the flag
# that closes the symlink door, and it is a property of this version.
"$FB" version 2>/dev/null | grep -q "$FB_VER" \
  && ok "filebrowser $FB_VER under test ($FB)" \
  || bad "filebrowser under test is not $FB_VER ($FB: $("$FB" version 2>&1 | head -1))"

# --- a home to serve, and things above it to reach for ----------------------
HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR/sub"
printf 'inside-home\n' > "$HOMEDIR/sub/in.md"
printf 'DOTFILE=1\n'    > "$HOMEDIR/.env"
# The file that must never come back. It is not /etc/passwd itself — a test that
# depends on a system file is a test that changes meaning per box — it is a file
# ABOVE the served root with a marker nothing inside home carries.
printf 'SECRET-ABOVE-HOME\n' > "$TMP/above.txt"
mkdir -p "$TMP/outside"; printf 'SECRET-ABOVE-HOME\n' > "$TMP/outside/deep.txt"
ln -s "$TMP/outside"     "$HOMEDIR/outlink"
ln -s "$TMP/above.txt"   "$HOMEDIR/filelink"
ln -s /etc               "$HOMEDIR/etclink"

PORT=19943
"$FB" --database "$TMP/fb.db" --root "$HOMEDIR" --address 127.0.0.1 --port "$PORT" \
      --noauth --followExternalSymlinks=false --disableTypeDetectionByHeader \
      >"$TMP/fb.log" 2>&1 &
FBPID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/api/login" && break
  sleep 0.25
done
JWT="$(curl -s --max-time 5 -X POST -H 'content-type: application/json' -d '{}' \
        "http://127.0.0.1:$PORT/api/login")"
[ -n "$JWT" ] && ok "filebrowser is up and issued a token" || bad "no token from filebrowser (see $TMP/fb.log)"

# --path-as-is: without it curl collapses `../` in the CLIENT, and the request the
# server sees is not the one being tested.
body() { curl -sL --path-as-is --max-time 5 -H "X-Auth: $JWT" "http://127.0.0.1:$PORT$1"; }
code() { curl -s  --path-as-is --max-time 5 -o /dev/null -w '%{http_code}' -H "X-Auth: $JWT" "http://127.0.0.1:$PORT$1"; }

# --- POSITIVE CONTROL: the ordinary case works ------------------------------
[ "$(body '/api/raw/sub/in.md?algo=none')" = "inside-home" ] \
  && ok "control: a file inside home reads back" \
  || bad "control: a file inside home did NOT read back — every negative below is meaningless"
list="$(body '/api/resources/')"
case "$list" in *'"name":".env"'*) ok "control: the home listing answers (and hides no dotfile)" ;;
                *) bad "control: the home listing did not answer with .env (got: ${list:0:80})" ;; esac
# ...and the marker itself is readable when it IS inside the tree, so "no marker in
# the response" below means "refused", not "the marker never appears anywhere".
cp "$TMP/above.txt" "$HOMEDIR/sub/marker-inside.txt"
case "$(body '/api/raw/sub/marker-inside.txt?algo=none')" in *SECRET-ABOVE-HOME*)
  ok "control: the marker string IS returned when the file is inside home" ;;
  *) bad "control: the marker file inside home did not read back" ;; esac

# --- THE NEGATIVES: nothing above home comes back ---------------------------
# Every shape a request can take to name something above the root.
ATTEMPTS=(
  '/api/raw/../above.txt?algo=none'
  '/api/raw/../../above.txt?algo=none'
  '/api/raw/sub/../../above.txt?algo=none'
  '/api/raw/%2e%2e/above.txt?algo=none'
  '/api/raw/..%2fabove.txt?algo=none'
  '/api/raw/%2e%2e%2f%2e%2e%2fabove.txt?algo=none'
  '/api/resources/../'
  '/api/resources/%2e%2e/'
  '/api/raw/outlink/deep.txt?algo=none'
  '/api/raw/filelink?algo=none'
  '/api/resources/outlink/'
  '/api/resources/etclink/'
  '/api/raw/etclink/passwd?algo=none'
)
leaked=0
for a in "${ATTEMPTS[@]}"; do
  out="$(body "$a")"
  c="$(code "$a")"
  case "$out" in
    *SECRET-ABOVE-HOME*|*'root:x:'*)
      bad "LEAK: $a returned content from above home (http $c)"; leaked=1 ;;
    *) : ;;
  esac
done
[ "$leaked" = 0 ] && ok "no attempt above home returned content (${#ATTEMPTS[@]} shapes: .., encoded .., symlink out, /etc symlink)"

# Symlinks leaving the tree are refused outright, not merely emptied — the 403 is
# what --followExternalSymlinks=false does, and it is the assertion that would go
# red if the flag were dropped.
for a in '/api/raw/filelink?algo=none' '/api/resources/outlink/' '/api/resources/etclink/'; do
  c="$(code "$a")"
  [ "$c" = 403 ] && ok "symlink out of home refused with 403: $a" \
                 || bad "symlink out of home was not refused with 403: $a (http $c)"
done

# An absolute host path offered as an API path names nothing.
c="$(code "/api/resources$TMP/home/sub/")"
[ "$c" = 404 ] && ok "an absolute host path is not an API path (404)" \
               || bad "an absolute host path answered $c (want 404)"

# The listing is home's, not the filesystem's — the root is where we think it is.
case "$list" in *'"name":"etc"'*|*'"name":"usr"'*) bad "the served root looks like /, not home" ;;
                *) ok "the served root is home (no /etc, /usr in the root listing)" ;; esac

# --- control: the harness can SEE a leak ------------------------------------
# Re-run the same body check against a server rooted one level higher. If this does
# not report a leak, the loop above proves nothing.
PORT2=19944
"$FB" --database "$TMP/fb2.db" --root "$TMP" --address 127.0.0.1 --port "$PORT2" \
      --noauth --followExternalSymlinks=false --disableTypeDetectionByHeader \
      >"$TMP/fb2.log" 2>&1 &
FB2=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT2/api/login" && break
  sleep 0.25
done
JWT2="$(curl -s --max-time 5 -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT2/api/login")"
out2="$(curl -sL --path-as-is --max-time 5 -H "X-Auth: $JWT2" "http://127.0.0.1:$PORT2/api/raw/above.txt?algo=none")"
kill "$FB2" 2>/dev/null; wait "$FB2" 2>/dev/null
case "$out2" in *SECRET-ABOVE-HOME*)
  ok "control: with the root one level higher the same check DOES report the file" ;;
  *) bad "control: a server that can serve above.txt did not return it — the leak check may be blind" ;; esac

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
