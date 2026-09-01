#!/usr/bin/env bash
# Mode 644, not 755: the orchestrator runs this with `bash <path>` (install/airlock-install.sh, bin/airlock-smoke), so the executable bit
# does nothing — and the cutline policy refuses a NEW 755 file. Older apps
# carry 755 because they predate that rule, not because they need it.
# learning — a study library: paste a link, get a document in a plain folder,
# share it through publish. Served as a same-origin subpath under the hub.
#
#   browser --> hub (tailscale serve :443) --(identity)--> hub nginx
#     /learning/  -> learning backend 127.0.0.1:BACKEND (loopback only)
#                    --spawn--> the ingest worker's agent CLI (separate unit)
#
# The hub gate ($hub_ok) is asserted ONCE at the server level, so this location
# inherits it. The backend binds loopback, so the gate is the only route in.
#
# What this installer does NOT own: the library folder. It creates it if missing
# and never writes into it — the documents are the user's, produced by ingest and
# edited by them. Deactivating the app leaves the folder exactly as it is.
#
# Config from airlock.toml ([apps.learning]). Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-learning}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

airlock_load learning
PORT="${AIRLOCK_LEARNING_BACKEND_PORT:?}"
LIBRARY_RAW="${AIRLOCK_LEARNING_LIBRARY_DIR:?}"
LISTING="${AIRLOCK_LEARNING_LISTING_PROVIDER:-auto}"
case "$LISTING" in
  auto|builtin|legacy) ;;
  *) die "listing_provider must be auto, builtin or legacy; got '$LISTING'" ;;
esac

# ~ is not expanded by the TOML reader, and a unit file cannot expand it either.
# shellcheck disable=SC2088  # the tilde is DATA here, not a path to expand: these
# patterns match the literal "~" the TOML reader handed us, and the body is what
# expands it. Quoting is required — an unquoted ~ pattern would expand to $HOME
# and stop matching the string we are trying to recognise.
case "$LIBRARY_RAW" in
  "~") LIBRARY="$HOME" ;;
  "~/"*) LIBRARY="$HOME/${LIBRARY_RAW#\~/}" ;;
  /*) LIBRARY="$LIBRARY_RAW" ;;
  *) die "library_dir must be absolute or start with ~/; got '$LIBRARY_RAW'" ;;
esac

CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
APP_DIR_LOCAL="$HOME/.local/share/airlock-learning"
STATE_DIR="$HOME/.local/state/airlock-learning"

# Where a shared document lands. 🔴 This is publish's share directory, read from
# publish's own resolved config — NOT a path this app decides. Hardcoding
# ~/public_html looked right on a box where publish is unpackaged (its backend
# falls back to exactly that), and was wrong on a packaged one: publish's unit
# gets /opt/airlock/share, so a document Learning "published" was invisible to
# publish's list and could never be made public. The dependency edge in the
# manifest is what guarantees publish's config exists by the time we read it.
PUBLISH_SHARE="$(airlock_config get apps.publish.share_dir 2>/dev/null || true)"
[ -n "$PUBLISH_SHARE" ] \
  || die "could not read apps.publish.share_dir — learning shares documents through publish, so publish must be configured (see [dependencies] in apps/learning/airlock-app.toml)"
# shellcheck disable=SC2088  # same as library_dir above: the tilde is DATA here
case "$PUBLISH_SHARE" in
  "~") PUBLISH_SHARE="$HOME" ;;
  "~/"*) PUBLISH_SHARE="$HOME/${PUBLISH_SHARE#\~/}" ;;
  /*) ;;
  *) die "apps.publish.share_dir must be absolute or start with ~/; got '$PUBLISH_SHARE'" ;;
esac
UNIT_DIR="$HOME/.config/systemd/user"
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
fi

require_cmd python3 systemctl curl

# The ingest unit's PATH. The worker spawns an agent CLI, and that CLI arrives in
# the user's own bin directory — usually AFTER Airlock is installed. So every
# candidate directory goes on the PATH whether or not it exists yet: a directory
# that does not exist costs a PATH entry nothing, while a missing one costs a
# worker that reports "not found" for a CLI the user did install. This is the
# same reasoning apps/paseo/install.sh records, and the same failure.
INGEST_PATH="$HOME/.local/bin:$HOME/.npm-global/bin"
while IFS= read -r _d; do
  [ -n "$_d" ] || continue
  case ":${INGEST_PATH}:" in *":${_d}:"*) continue ;; esac
  INGEST_PATH="${INGEST_PATH}:${_d}"
done <<EOF
$(airlock_cmd_dirs claude)
$(airlock_cmd_dirs codex)
EOF
INGEST_PATH="${INGEST_PATH}:/usr/local/bin:/usr/bin:/bin"
# 🔴 이 PATH 는 **두 유닛 모두**에 간다. 워커만 주면, 링크를 붙여넣을 때 CLI 를 찾는
# 서버가 빈손이 되어 모든 적재 요청이 거절된다 — CLI 가 둘 다 깔려 있어도.
# systemd 사용자 유닛의 기본 PATH 에는 `~/.local/bin` 이 없다(실측 2026-08-22).
UNSAFE_ENV="$(python3 "$HERE/backend/providers.py" --unsafe-env)" \
  || die "could not read the billing-env list from the provider adapter"
PROVIDER="${AIRLOCK_LEARNING_PROVIDER:-auto}"
# The platform path is a handed-in D5 capability, not something this package derives
# from AIRLOCK_ROOT. Resolve it once so both units keep working across cwd changes.
case "$AIRLOCK_ACCOUNTS_STATUS_BIN" in
  /*) ;;
  *) die "AIRLOCK_ACCOUNTS_STATUS_BIN must be an absolute D5 platform path" ;;
esac
[ -f "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] && [ -x "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] \
  || die "AIRLOCK_ACCOUNTS_STATUS_BIN does not name an executable platform file"
ACCOUNTS_STATUS_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "$AIRLOCK_ACCOUNTS_STATUS_BIN")"
case "$PROVIDER" in
  auto|claude|codex) ;;
  *) die "provider must be auto, claude or codex; got '$PROVIDER'" ;;
esac

# --- 1. the library folder ---
# Created, never populated. An empty library is a valid state: the app opens on
# it and invites a first link. It is deliberately NOT an [artifacts] entry, so
# deactivate never removes it.
airlock_run mkdir -p "$LIBRARY"
airlock_run mkdir -p "$STATE_DIR"

# --- 2. app code into the share dir ---
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install backend + frontend -> $APP_DIR_LOCAL/"
else
  install -d "$APP_DIR_LOCAL/backend" "$APP_DIR_LOCAL/frontend"
  install -m644 "$HERE/backend/airlock-learning.py" "$APP_DIR_LOCAL/backend/airlock-learning.py"
  install -m644 "$HERE/backend/ingest_runner.py"    "$APP_DIR_LOCAL/backend/ingest_runner.py"
  install -m644 "$HERE/backend/save_document.py"   "$APP_DIR_LOCAL/backend/save_document.py"
  install -m644 "$HERE/backend/providers.py"       "$APP_DIR_LOCAL/backend/providers.py"
  # 플랫폼 선택 규칙의 vendored 사본. providers.py 가 **파일 경로로** 읽으므로 같은
  # 디렉터리에 있어야 한다 — 빠뜨리면 백엔드가 임포트에서 죽고, 그때는 "적재가 안 된다"
  # 가 아니라 앱 전체가 안 뜬다. bin/agent_provider.py 와 바이트 동일성은
  # install/test-agent-provider.sh 가 잡는다.
  install -m644 "$HERE/backend/agent_provider.py"  "$APP_DIR_LOCAL/backend/agent_provider.py"
  install -d "$APP_DIR_LOCAL/skill"
  install -m644 "$HERE/skill/SKILL.md"             "$APP_DIR_LOCAL/skill/SKILL.md"
  install -m644 "$HERE/skill/transcript.py"        "$APP_DIR_LOCAL/skill/transcript.py"
  install -m644 "$HERE/frontend/learning.html"      "$APP_DIR_LOCAL/frontend/learning.html"
fi

# --- 3. units ---
# The dry-run branch is not cosmetic: `dry-run-exec` is one of this repo's bundle
# certifications, so a dry run must not write a unit file into a real HOME.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-learning.service (127.0.0.1:$PORT, library=$LIBRARY)"
  log "[dry] write $UNIT_DIR/airlock-learning-ingest.service"
else
install -d "$UNIT_DIR"
render_learning_unit_server "$LIBRARY" "$PUBLISH_SHARE" "$STATE_DIR" "$PORT" "$LISTING" \
  "$APP_DIR_LOCAL/backend" "$INGEST_PATH" "$ACCOUNTS_STATUS_BIN" \
  > "$UNIT_DIR/airlock-learning.service"
render_learning_unit_ingest "$LIBRARY" "$STATE_DIR" "$PROVIDER" "$INGEST_PATH" \
  "$APP_DIR_LOCAL/backend" "$UNSAFE_ENV" "$ACCOUNTS_STATUS_BIN" \
  > "$UNIT_DIR/airlock-learning-ingest.service"
fi
log "wrote units: airlock-learning.service, airlock-learning-ingest.service"

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-learning.service airlock-learning-ingest.service
airlock_run systemctl --user restart airlock-learning.service airlock-learning-ingest.service

# --- 4. nginx subpath fragment (included inside the hub server block) ---
frag="$CONFD/hub-locations.d/learning.conf"
install -d "$CONFD/hub-locations.d"
render_learning_nginx "$PORT" > "$frag"
log "wrote nginx fragment: $frag"

# --- 5b. one-time notice: documents shared by the pre-6b build are stranded ---
# The old build linked into ~/public_html unconditionally. If that is not the
# share directory publish uses, those links are now invisible to BOTH apps: the
# app shows the document as unshared and publish never listed it. Nothing here
# deletes or moves them — they point into the user's library and are the user's
# to keep — but silence would let the count quietly disagree with the screen.
if [ "$PUBLISH_SHARE" != "$HOME/public_html" ] && [ -d "$HOME/public_html" ]; then
  stranded=$(find "$HOME/public_html" -maxdepth 1 -type l -name 'learning-*' 2>/dev/null | wc -l)
  if [ "${stranded:-0}" -gt 0 ]; then
    log "note: ${stranded} link(s) from an earlier build remain in ~/public_html and are not part of ${PUBLISH_SHARE}. Re-share those documents from the app to move them; nothing was deleted."
  fi
fi

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
# --- 5. the ingest skill, where each agent CLI looks for one ---
# A symlink, not a copy: the skill and the save helper it calls have to move together,
# and a copy drifts from the package the moment either changes.
#
# 🔴 Never clobber. `learning-ingest` is a name a user could already own — the reference
# box has one in its content repository. If something is already there and it is not our
# link, we leave it and say so. Installing over somebody's skill would be the app
# deciding it knows better about a file it did not write.
skill_link() {   # skill_link <dir>
  local root="$1" target="$1/learning-ingest"
  [ -n "$root" ] || return 0
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" = "$APP_DIR_LOCAL/skill" ]; then return 0; fi
    log "note: ${target} is a symlink to something else — leaving it alone; ingest will use whatever it points at"
    return 0
  fi
  if [ -e "$target" ]; then
    log "note: ${target} already exists and is not ours — leaving it alone"
    return 0
  fi
  # 🔴 `install -d` 가 아니라 `mkdir -p` 다. `install -d` 는 **이미 있는 디렉터리의 모드도
  # 바꾼다** — 사용자가 0700 으로 잠가 둔 스킬 디렉터리가 링크 하나 걸었다고 0755 가 된다.
  mkdir -p "$root" || { log "note: could not create ${root} — ingest skill not linked there"; return 0; }
  ln -s "$APP_DIR_LOCAL/skill" "$target" \
    || { log "note: could not link the ingest skill into ${root} — that CLI will not find it"; return 0; }
  log "linked ingest skill: ${target}"
}

# 🔴 자리는 어댑터가 안다. 여기 다시 적으면 새 CLI 를 붙일 때 한쪽만 고치게 되고,
# 그 CLI 는 스킬을 못 찾는데 아무 데서도 실패하지 않는다.
# 🔴 스킬을 못 걸어도 **설치를 죽이지 않는다.** 이 절은 유닛·nginx 조각을 이미 쓴 뒤에
# 오므로, 여기서 죽으면 절반만 설치된 상태로 끝나고 성공 줄도 안 찍힌다. 그리고 적재는
# 이 앱의 절반일 뿐이다 — 열람과 공유는 스킬 없이 완전히 돈다. 이 절 전체가 non-fatal 이다.
SKILL_ROOTS="$(python3 "$HERE/backend/providers.py" --skill-roots 2>/dev/null || true)"
[ -n "$SKILL_ROOTS" ] \
  || log "note: could not read the skill directories from the provider adapter — ingest skill not linked"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] link ingest skill into: $(echo "$SKILL_ROOTS" | tr '\n' ' ')"
else
  while IFS= read -r _root; do
    [ -n "$_root" ] && skill_link "$_root"
  done <<EOF
$SKILL_ROOTS
EOF
fi

# --- 5c. an agent CLI is not required to install, but say so when there is none ---
# 🔴 There is no prerequisite row for it on purpose (see the manifest). Silence would
# be worse than the blocked install it replaced: the tile would open, the link box
# would accept a paste, and the refusal would arrive as a red card.
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  log "note: no agent CLI (claude/codex) found on PATH — browsing, reading and sharing work, but pasting a link cannot produce a document until one is installed and logged in."
fi

log "learning installed (library: ${LIBRARY}, shares via publish: ${PUBLISH_SHARE}, listing: ${LISTING}, ingest: ${PROVIDER}, owner: ${AIRLOCK_OWNER})"
