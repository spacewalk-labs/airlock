#!/usr/bin/env bash
# live/verify.sh — one full-tree install on a box that has never seen airlock,
# from creating the container to deleting it.
#
# Why this exists: CI cannot do it. On 2026-08-07 six installs on a real 8 GiB
# container turned up six defects and CI had caught none of them — a `set -e` leak
# that silenced nine smokes, discarded npm output, a snap node missing from the
# unit PATH, a `| grep -q` SIGPIPE that failed only when the thing WAS there, a
# backtick executing inside a heredoc, and NoNewPrivileges against a snap wrapper.
# None of those shapes exist on a GitHub runner. So the verification has to happen
# somewhere that has snapd, a real systemd user session, real nginx and real sudo,
# and the only honest way to keep saying "nine apps install on a fresh box" is to
# do it again on a schedule.
#
# Two rules from the security review, both structural rather than advisory:
#
#   1. REPOSITORY CODE NEVER RUNS ON THE HOST. The airlock lifecycle runs arbitrary
#      bash and sudo by contract (SECURITY.md:250-266). This script does container
#      lifecycle and payload delivery; everything the repository ships runs inside
#      the container, which is destroyed afterwards.
#   2. RESULT BEFORE CLEANUP. A run that dies during teardown still publishes what
#      it found. The durable local record is written before anything is deleted and
#      before anything is published.
#
# Nothing site-specific is written down here. The LXD host, the owner identity, the
# tailnet tag and the auth key all arrive through the environment, because this
# tree is mirrored to a public repository and a hostname in it is a leak.
#
#   AIRLOCK_LIVE_SSH        required. ssh destination of the LXD host, e.g. an
#                           alias from ~/.ssh/config. Must reach `lxc` non-interactively.
#   AIRLOCK_LIVE_OWNER      required. The owner identity the gate will accept.
#   AIRLOCK_LIVE_TSKEY_FILE required. Mode-600 file holding a tailscale auth key.
#                           Read, never echoed, never passed on a command line.
#   AIRLOCK_LIVE_TAG        tailscale tag to advertise (default tag:infra)
#   AIRLOCK_LIVE_IMAGE      image to launch (default ubuntu:24.04)
#   AIRLOCK_LIVE_POOL       storage pool (default: the host's default)
#   AIRLOCK_LIVE_MEM        memory limit (default 8GiB) — 8 GiB is not arbitrary: it is
#                           what the students' machines have, and it is the size paseo's
#                           memory share was validated at (11/16 of 8 GiB = 5632M), and
#                           what the 2026-08-07 defects surfaced on. Since the backstop is
#                           a SHARE (2026-08-22) rather than a fixed number, a smaller
#                           container is not refused and not degraded — it simply verifies
#                           a smaller share than the students will get.
#   AIRLOCK_LIVE_CPU        cpu limit (default 4)
#   AIRLOCK_LIVE_DISK       root disk size (default 30GiB)
#   AIRLOCK_LIVE_SOAK       seconds between the two unit readings (default 60)
#   AIRLOCK_LIVE_RESULT_DIR where results are kept (default ~/.local/state/airlock-live)
#   AIRLOCK_LIVE_EVIDENCE_DIR optional directory for a runner-rendered, public-safe
#                           `<run-id>.public.json` suitable for committing
#   AIRLOCK_LIVE_PUBLISH    "gh" (default) publishes to the repo; "none" skips it
#   AIRLOCK_LIVE_KEEP       1 = do not delete the container (debugging only; this
#                           makes the next run's name unique anyway)
#   AIRLOCK_LIVE_DEVMON_MESSAGES
#                           true = start the dev-monitor message console without
#                           adding either Slack webhook (default false)
#   AIRLOCK_LIVE_ALLOW_DIRTY 1 = allow a dirty working tree (the SHA then means less)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

say()  { printf '[live] %s\n' "$*" >&2; }
die()  { printf '[live] FATAL: %s\n' "$*" >&2; exit 1; }

: "${AIRLOCK_LIVE_SSH:?set AIRLOCK_LIVE_SSH to the ssh destination of the LXD host}"
: "${AIRLOCK_LIVE_OWNER:?set AIRLOCK_LIVE_OWNER to the owner identity}"
: "${AIRLOCK_LIVE_TSKEY_FILE:?set AIRLOCK_LIVE_TSKEY_FILE to a mode-600 file holding a tailscale auth key}"
TAG="${AIRLOCK_LIVE_TAG:-tag:infra}"
IMAGE="${AIRLOCK_LIVE_IMAGE:-ubuntu:24.04}"
MEM="${AIRLOCK_LIVE_MEM:-8GiB}"
CPU="${AIRLOCK_LIVE_CPU:-4}"
DISK="${AIRLOCK_LIVE_DISK:-30GiB}"
SOAK="${AIRLOCK_LIVE_SOAK:-60}"
DEVMON_MESSAGES="${AIRLOCK_LIVE_DEVMON_MESSAGES:-false}"
RESULT_DIR="${AIRLOCK_LIVE_RESULT_DIR:-$HOME/.local/state/airlock-live}"
EVIDENCE_DIR="${AIRLOCK_LIVE_EVIDENCE_DIR:-}"
PUBLISH="${AIRLOCK_LIVE_PUBLISH:-gh}"

case "$DEVMON_MESSAGES" in
  true|false) ;;
  *) die "AIRLOCK_LIVE_DEVMON_MESSAGES must be true or false" ;;
esac
if [ "$DEVMON_MESSAGES" = true ] && { ! [[ "$SOAK" =~ ^[0-9]+$ ]] || [ "$SOAK" -lt 120 ]; }; then
  die "AIRLOCK_LIVE_DEVMON_MESSAGES=true requires AIRLOCK_LIVE_SOAK of at least 120 seconds"
fi

# 🔴 **키는 실행 시각에 만든다.** 2026-08-18 실측 — 여기 놓여 있던 키는 single-use 에 1시간
#    TTL 이었고, 2026-08-16 에 한 번 쓰이고 폐기(revoked)된 상태였다. 즉 이 주간잡은 사람이 손으로
#    새 키를 넣어 주기 전까지 **어떤 주에도 성공할 수 없었고**, 그 사실이 로그 어디에도 없었다.
#    디스크에 놓인 정적 키는 두 방향으로 실패한다 — single-use 면 다음 주에 죽고, reusable 이면
#    오래 사는 자격이 파일로 남는다. 실행 시각에 만들어 쓰고 버리면 둘 다 없다.
#
#    토큰이 없는 곳(개발자 손실행)에서는 기존처럼 파일 키를 쓴다. 그때는 아래에서 그 키가
#    쓸 수 있는 상태인지 보고, 못 재면 **못 쟀다고 말한다** — 없는 것을 초록으로 넘기지 않는다.
#    자격 자체도 같은 병이 있었다. 여기 쓰던 tailnet API key 는 Tailscale 이 90일 상한을 강제하고
#    API 로 재발급할 수도 없어서, 사람이 콘솔에서 안 누르면 조용히 죽는다 — 2026-08-16 에 실제로
#    그렇게 죽었다. 그래서 기본 경로를 **OAuth(trust credential, 무만료)** 로 바꾸고, 토큰 파일은
#    1P 가 없는 손실행용 폴백으로만 남긴다.
MINTED_KEY_FILE=""
TS_MINT_AUTH=()
TS_MINT_SOURCE=""
# 🔴 헬퍼 경로는 여기 박지 않는다. 이 파일은 공개 레포로 미러링되므로 사내 저장소 배치를
#    문서화하게 되고, 유출 가드가(옳게) 막는다. 경로는 박스의 env 파일이 준다
#    (`~/.config/airlock-live/env` → 유닛의 EnvironmentFile). 없으면 아래 파일 토큰으로 간다.
TS_API_HELPER="${AIRLOCK_LIVE_TSAPI_HELPER:-}"
if [ -n "$TS_API_HELPER" ] && [ -x "$TS_API_HELPER" ]; then
  # 🔴 worktree 경로에 걸지 않는다 — 워크트리가 사라지면 이 타이머가 조용히 영영 실패한다.
  ts_oauth_token="$(TS_OAUTH_CLIENT=AIRLOCK "$TS_API_HELPER" --token 2>/dev/null || true)"
  if [ -n "$ts_oauth_token" ]; then
    TS_MINT_AUTH=(-H "Authorization: Bearer $ts_oauth_token")
    TS_MINT_SOURCE="OAuth(TS_OAUTH_AIRLOCK_*, 1P)"
  fi
fi
if [ ${#TS_MINT_AUTH[@]} -eq 0 ] && [ -z "$TS_API_HELPER" ]; then
  say "note: AIRLOCK_LIVE_TSAPI_HELPER 가 없어 OAuth 발급을 건너뜁니다 — 파일 토큰으로 갑니다"
fi
if [ ${#TS_MINT_AUTH[@]} -eq 0 ] && [ -n "${AIRLOCK_LIVE_TSAPI_TOKEN_FILE:-}" ] && [ -r "${AIRLOCK_LIVE_TSAPI_TOKEN_FILE}" ]; then
  mint_perm="$(stat -c '%a' "$AIRLOCK_LIVE_TSAPI_TOKEN_FILE" 2>/dev/null || echo '')"
  case "$mint_perm" in 600|400) ;; *) die "API token file is mode ${mint_perm:-unknown}; it must be 600 or 400" ;; esac
  TS_MINT_AUTH=(-u "$(cat "$AIRLOCK_LIVE_TSAPI_TOKEN_FILE"):")
  TS_MINT_SOURCE="API key file $AIRLOCK_LIVE_TSAPI_TOKEN_FILE (레거시 — 90일이면 죽는다)"
fi
if [ ${#TS_MINT_AUTH[@]} -gt 0 ]; then
  say "note: tailnet 키 발급 자격 = $TS_MINT_SOURCE"
  MINTED_KEY_FILE="$(mktemp)" || die "could not create a temp file for the minted auth key"
  chmod 600 "$MINTED_KEY_FILE"
  # 🔴 임시 키 파일은 어떤 종료 경로에서도 지운다. 아래 teardown trap 보다 먼저 걸어 둔다 —
  #    여기와 거기 사이에서 죽으면 키가 디스크에 남는데, 그게 이 블록이 없애려던 상태다.
  trap 'rm -f "$MINTED_KEY_FILE"' EXIT
  # single-use · ephemeral · preauthorized · 이 실행에만 유효한 짧은 수명.
  # ephemeral 이라 컨테이너가 사라지면 노드도 tailnet 에서 자동으로 정리된다.
  mint_out="$(
    curl -sS --max-time 30 "${TS_MINT_AUTH[@]}" \
      -H 'Content-Type: application/json' \
      -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":[\"$TAG\"]}}},\"expirySeconds\":3600,\"description\":\"airlock live verify minted per run\"}" \
      "https://api.tailscale.com/api/v2/tailnet/-/keys" 2>&1
  )"
  printf '%s' "$mint_out" | python3 -c '
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: sys.exit(3)
if "key" not in d: sys.exit(4)
sys.stdout.write(d["key"])
' > "$MINTED_KEY_FILE" 2>/dev/null
  mint_rc=$?
  if [ "$mint_rc" != 0 ] || [ ! -s "$MINTED_KEY_FILE" ]; then
    # 🔴 사유를 싣되 응답 본문은 안 싣는다 — 실패 응답에도 토큰이 되비쳐 올 수 있고, 이 로그는
    #    이슈에 공개될 수 있다. 사람이 볼 것은 "무엇을 확인하라" 이지 응답 덤프가 아니다.
    msg="$(printf '%s' "$mint_out" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("message",""))
except Exception: print("")' 2>/dev/null)"
    die "could not mint a tailnet auth key (rc=$mint_rc${msg:+, API: $msg}) — 자격이 죽었거나 $TAG 발급 권한이 없습니다. 쓴 자격=$TS_MINT_SOURCE"
  fi
  AIRLOCK_LIVE_TSKEY_FILE="$MINTED_KEY_FILE"
  say "auth key minted for this run (single-use · ephemeral · $TAG · 1h)"
fi

[ -f "$AIRLOCK_LIVE_TSKEY_FILE" ] || die "auth key file not found: $AIRLOCK_LIVE_TSKEY_FILE"
perm="$(stat -c '%a' "$AIRLOCK_LIVE_TSKEY_FILE" 2>/dev/null || echo '')"
case "$perm" in 600|400) ;; *) die "auth key file is mode ${perm:-unknown}; it must be 600 or 400" ;; esac

# 정적 키 경로(개발자 손실행)에서는 그 키가 유효한지 **여기서 잴 수 없다** — 그러려면 API 토큰이
# 필요한데, 토큰이 있으면 위에서 이미 새로 만들었다. 못 잰다는 사실을 말해 둔다: 소진된 키라면
# 컨테이너를 만든 뒤 tailnet 합류에서 죽고, 그 사유는 in-container.sh 가 로그에 남긴다(2026-08-18
# 이전에는 그 사유마저 /dev/null 로 갔다).
if [ -z "$MINTED_KEY_FILE" ]; then
  say "note: 발급 자격(OAuth helper·토큰 파일 둘 다)이 없어 키를 새로 만들지 못했습니다 — 파일에 있는 키를 그대로 씁니다(유효성은 못 쟀습니다)"
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$AIRLOCK_LIVE_SSH")
"${SSH[@]}" 'command -v lxc >/dev/null' \
  || die "cannot reach lxc over $AIRLOCK_LIVE_SSH — this path must be non-interactive"

# ------------------------------------------------------------------ identity
SHA="$(git -C "$ROOT" rev-parse HEAD)" || die "not a git checkout: $ROOT"
# Tracked changes only. The payload further down is `git archive "$SHA"` — an untracked
# file was never going to ship, so refusing to run because one exists rejects a run that
# would have been exactly reproducible. Modified *tracked* files are a different story:
# they do not ship either, and that is the point — an operator who edited one and then
# read a green result would be reading it about a tree that is not the one on their disk.
#
# Measured 2026-08-17: the weekly unattended run died on this gate because another
# session had left a worklog draft untracked in the shared checkout. Nothing about the
# run would have differed. A gate that any passer-by can trip is not a gate, it is a
# scheduled outage — and this one cost a week (the timer is weekly).
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] && [ "${AIRLOCK_LIVE_ALLOW_DIRTY:-0}" != 1 ]; then
  die "tracked files are modified — a result recorded against $SHA would be read as a claim about the tree on disk, and the payload is $SHA. Commit, or set AIRLOCK_LIVE_ALLOW_DIRTY=1 and accept that the SHA is approximate."
fi
# Said, not enforced: untracked files do not affect the result, but a person comparing a
# green run against their disk deserves to know the disk had more on it than the run did.
untracked_n="$(git -C "$ROOT" ls-files --others --exclude-standard | wc -l)"
if [ "$untracked_n" -gt 0 ]; then
  say "note: $untracked_n untracked file(s) in $ROOT — not shipped (the payload is git archive $SHA), not a reason to stop"
fi

# Advance to the default branch first, but only when asked. The timer asks
# (`AIRLOCK_LIVE_UPDATE=1` in airlock-live-verify.service.in); a person or an agent
# running this against a branch before merging does not, because there the whole point
# is to verify *that* tree.
#
# Without this the unattended run verified whatever was last left in the checkout the
# unit runs from. Measured 2026-08-17: that checkout was 10 commits behind, and two of
# the ten had changed this verification system itself — so it was testing a tree that
# did not contain its own fixes, and reporting green. The result comment always carried
# the SHA, so nothing lied; nothing compared that SHA to anything either, which is the
# same shape as not checking at all (#152).
#
# `--ff-only` is the whole safety story: it cannot discard a commit, and the dirty check
# above has already refused if there is uncommitted work. If the checkout has diverged
# the merge fails and so does this run — a backstop that quietly skipped its update
# would be back to verifying an unknown tree.
if [ "${AIRLOCK_LIVE_UPDATE:-0}" = 1 ]; then
  BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" \
    || die "AIRLOCK_LIVE_UPDATE=1 but $ROOT is on a detached HEAD; there is no branch to advance."
  git -C "$ROOT" fetch --quiet origin "$BRANCH" \
    || die "AIRLOCK_LIVE_UPDATE=1 but fetching origin/$BRANCH failed — refusing to verify a tree of unknown age."
  git -C "$ROOT" merge --ff-only --quiet "origin/$BRANCH" \
    || die "AIRLOCK_LIVE_UPDATE=1 but $ROOT cannot fast-forward to origin/$BRANCH (local commits, or a diverged branch). Reconcile it by hand; this run will not guess."
  SHA="$(git -C "$ROOT" rev-parse HEAD)"
  say "updated $ROOT to origin/$BRANCH ($(git -C "$ROOT" rev-parse --short HEAD))"
fi
# The run id has to be unique per run and legal as a tailnet hostname: lowercase,
# no underscores. Derived from the clock and the short SHA rather than random, so a
# result and a container can be matched up by eye afterwards.
RUN_ID="$(date -u +%Y%m%dt%H%M%S)-$(git -C "$ROOT" rev-parse --short HEAD)"
NAME="airlock-live-$RUN_ID"
RUN_NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
  || die "could not generate the per-run container ownership nonce"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$RESULT_DIR"
RESULT="$RESULT_DIR/$RUN_ID.json"
INNER_FILE="$RESULT_DIR/$RUN_ID.inner.json"
LOGFILE="$RESULT_DIR/$RUN_ID.log"

say "run $RUN_ID"
say "commit $SHA"
say "container $NAME on $AIRLOCK_LIVE_SSH"
say "result $RESULT"

# Every state this run can end in, so that "it did not finish" is a value and not
# an absence. `never_started` is the initial one on purpose: if this script is
# killed between here and the first write, the dead-man has nothing to find, which
# is exactly the case the weekly watcher exists to catch.
STAGE=never_started
CONTAINER_MADE=0
CONTAINER_LAUNCH_ATTEMPTED=0
CLEANUP_OK=null
IMAGE_FP=""
INNER='{}'
INNER_RC=-1

write_result() {
  # Written repeatedly: after the run, and again after cleanup. The first write is
  # the one that matters — a run that dies during teardown has already recorded
  # what it found.
  #
  # The inner document goes to its own file and is read from there rather than
  # being interpolated into this heredoc. It carries install and smoke output,
  # which is arbitrary text; a quoted heredoc plus argv is the only version of
  # this that cannot be broken by something a log line happened to contain.
  printf '%s' "$INNER" > "$INNER_FILE"
  RUN_ID="$RUN_ID" SHA="$SHA" STARTED="$STARTED" \
  HOST="$AIRLOCK_LIVE_SSH" NAME="$NAME" IMAGE="$IMAGE" IMAGE_FP="$IMAGE_FP" \
  MEM="$MEM" CPU="$CPU" DISK="$DISK" STAGE="$STAGE" \
  DEVMON_MESSAGES="$DEVMON_MESSAGES" \
  INNER_RC="$INNER_RC" CLEANUP_OK="$CLEANUP_OK" \
  python3 "$HERE/mkresult.py" "$RESULT" "$INNER_FILE"
}

container_owned_by_run() {
  local marker
  marker="$("${SSH[@]}" "lxc config get $NAME user.airlock_live_owner_nonce" 2>/dev/null | tr -d '\r\n')" \
    || return 1
  [ "$marker" = "$RUN_NONCE" ]
}

cleanup() {
  local rc=$?
  # 🔴 이 실행을 위해 만든 인증키를 먼저 지운다. 위쪽 mint 블록도 EXIT trap 을 걸지만
  #    `trap cleanup EXIT` 가 그것을 **덮어쓴다** — 여기서 안 지우면 컨테이너를 만든 뒤의
  #    모든 종료 경로에서 키가 디스크에 남고, 그게 mint 가 없애려던 상태 그대로다.
  [ -n "${MINTED_KEY_FILE:-}" ] && rm -f "$MINTED_KEY_FILE"
  # `lxc launch` can create the instance and still return non-zero. The old
  # success-only flag then made EXIT forget the instance entirely. The custom
  # user key is part of the create request, so it lets this run recover only its
  # own partial launch without deleting an unrelated instance with the same name.
  if [ "$CONTAINER_MADE" != 1 ] && [ "$CONTAINER_LAUNCH_ATTEMPTED" = 1 ] \
      && container_owned_by_run; then
    CONTAINER_MADE=1
    say "recovering partially launched $NAME"
  fi
  if [ "$CONTAINER_MADE" = 1 ] && ! container_owned_by_run; then
    CLEANUP_OK=false
    say "WARNING: refusing to delete $NAME — its ownership marker no longer belongs to this run"
  elif [ "$CONTAINER_MADE" = 1 ] && [ "${AIRLOCK_LIVE_KEEP:-0}" != 1 ]; then
    say "deleting $NAME (container and tailnet identity)"
    # `tailscale logout` first so the node leaves the tailnet rather than lingering
    # as an offline entry somebody has to reap by hand later. </dev/null because a
    # `lxc exec` inherits this shell's stdin and tailscale will sit on it.
    "${SSH[@]}" "lxc exec $NAME -- tailscale logout </dev/null" >/dev/null 2>&1 || true
    if "${SSH[@]}" "lxc delete --force $NAME" >/dev/null 2>&1; then
      CLEANUP_OK=true
    else
      CLEANUP_OK=false
      say "WARNING: could not delete $NAME — it is still on the host and still on the tailnet"
    fi
  elif [ "$CONTAINER_MADE" = 1 ]; then
    CLEANUP_OK=false
    say "AIRLOCK_LIVE_KEEP=1 — $NAME left running. Delete it when you are done."
  fi
  write_result
  if [ -n "$EVIDENCE_DIR" ]; then
    mkdir -p "$EVIDENCE_DIR"
    if ! python3 "$HERE/mkpublicresult.py" "$RESULT" \
        "$EVIDENCE_DIR/$RUN_ID.public.json"; then
      say "WARNING: could not render tracked public evidence"
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

# ------------------------------------------------------------------ container
STAGE=creating
say "launching $IMAGE"
CONTAINER_LAUNCH_ATTEMPTED=1
"${SSH[@]}" "lxc launch $IMAGE $NAME \
  -c limits.memory=$MEM -c limits.cpu=$CPU \
  -c user.airlock_live_owner_nonce=$RUN_NONCE \
  ${AIRLOCK_LIVE_POOL:+-s $AIRLOCK_LIVE_POOL} -d root,size=$DISK" >/dev/null 2>&1 \
  || die "lxc launch failed"
CONTAINER_MADE=1
# The image fingerprint, not just the alias. "ubuntu:24.04" is a moving target; a
# result that cannot say which build it ran on cannot be compared with last week's.
IMAGE_FP="$("${SSH[@]}" "lxc config get $NAME volatile.base_image" 2>/dev/null | tr -d '\r\n')"
say "image fingerprint ${IMAGE_FP:-<unreadable>}"

say "waiting for the container to finish booting"
booted=0
for _ in $(seq 1 60); do
  if "${SSH[@]}" "lxc exec $NAME -- systemctl is-system-running --wait" >/dev/null 2>&1; then
    booted=1; break
  fi
  # is-system-running exits non-zero for `degraded`, which a fresh container often
  # is and which does not stop anything here. Accept any answer that means systemd
  # has finished starting up.
  state="$("${SSH[@]}" "lxc exec $NAME -- systemctl is-system-running" 2>/dev/null | tr -d '\r\n')"
  case "$state" in running|degraded) booted=1; break ;; esac
  sleep 2
done
[ "$booted" = 1 ] || die "container never finished booting"

# ------------------------------------------------------------------ payload
STAGE=delivering
say "delivering the tree at $SHA"
# git archive, not the working tree: the payload is exactly the commit named in the
# result. A harness that shipped uncommitted edits would attest to a commit that
# never ran.
git -C "$ROOT" archive --format=tar --prefix=airlock-src/ "$SHA" \
  | "${SSH[@]}" "cat > /tmp/$NAME.tar" || die "could not stage the repo payload on the host"
"${SSH[@]}" "lxc file push /tmp/$NAME.tar $NAME/tmp/src.tar >/dev/null && rm -f /tmp/$NAME.tar" \
  || die "could not push the payload into the container"
"${SSH[@]}" "lxc exec $NAME -- tar -xf /tmp/src.tar -C /opt && lxc exec $NAME -- rm -f /tmp/src.tar" \
  || die "could not unpack the payload inside the container"
"${SSH[@]}" "lxc exec $NAME -- test -f /opt/airlock-src/install/airlock-install.sh" \
  || die "payload did not land at /opt/airlock-src"

# The auth key goes in over stdin, into a mode-600 file, and is deleted by the
# in-container script the moment it has been used. It never appears in argv, in
# this host's process table, or in the container's.
say "delivering the auth key"
"${SSH[@]}" "cat > /tmp/$NAME.key && chmod 600 /tmp/$NAME.key" < "$AIRLOCK_LIVE_TSKEY_FILE" \
  || die "could not stage the auth key"
"${SSH[@]}" "lxc file push /tmp/$NAME.key $NAME/run/live-tskey --mode=0600 >/dev/null; rm -f /tmp/$NAME.key" \
  || die "could not push the auth key into the container"

# ------------------------------------------------------------------ the run
STAGE=running
say "installing and smoking inside the container (soak ${SOAK}s) — this takes a while"
INNER_RC=0
INNER="$(
  "${SSH[@]}" "lxc exec $NAME \
    --env LIVE_USER=airlock \
    --env LIVE_OWNER='$AIRLOCK_LIVE_OWNER' \
    --env LIVE_HOSTNAME='$NAME' \
    --env LIVE_TAG='$TAG' \
    --env LIVE_SHA='$SHA' \
    --env LIVE_SOAK='$SOAK' \
    --env LIVE_DEVMON_MESSAGES='$DEVMON_MESSAGES' \
    -- bash /opt/airlock-src/live/in-container.sh </dev/null" 2>>"$LOGFILE"
)" || INNER_RC=$?
[ -n "$INNER" ] || INNER='{}'
STAGE=ran
say "inner run exited $INNER_RC (transcript: $LOGFILE)"

# Result first, then anything that can fail.
write_result
say "result written: $RESULT"

# ------------------------------------------------------------------ verdict
# The denominator is stated, not implied. bin/airlock-smoke does not count hub in
# its own summary (:42-62), so "9/10" and "10/10" mean different things depending
# on who is counting; the record carries the item list so a reader never has to
# guess which convention a number used.
python3 - "$RESULT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
inner = r.get("inner") or {}
smoke_rc = inner.get("smoke_rc")
lines = inner.get("smoke_lines") or []
late = inner.get("units_late") or []
acceptance = inner.get("acceptance") or {}

def is_down(u):
    # A oneshot that has run and exited is `inactive/dead`, and that is its healthy
    # state — airlock-publish-cleanup.service is driven by a timer and would
    # otherwise be reported as a failure on every single run.
    if u.get("active") == "active":
        return False
    if u.get("type") == "oneshot" and u.get("sub") == "dead" and (u.get("exec_status") or "0") == "0":
        return False
    return True

restarting = [u for u in late if is_down(u)]
churn = [u for u in late if (u.get("restarts") or "0") not in ("0", "")]
print(f"stage={r['stage']} install_rc={inner.get('install_rc')} smoke_rc={smoke_rc}")
print(f"units={len(late)} down={len(restarting)} with-restarts={len(churn)}")
print(f"external_packages={inner.get('external_packages')}")
print(f"external_gate_line_found={inner.get('external_gate_line_found', False)}")
print(f"dev_monitor_messages_requested={r.get('dev_monitor_messages_requested')} "
      f"no_webhook_gate={inner.get('devmon_no_webhook')}")
print(f"acceptance=rc={acceptance.get('rc', 'n/a')} "
      f"passed={acceptance.get('passed', 'n/a')} failed={acceptance.get('failed', 'n/a')}")
for u in restarting:
    print(f"  DOWN  {u['id']} type={u.get('type')} active={u.get('active')} sub={u.get('sub')} status={u.get('exec_status')} restarts={u.get('restarts')}")
for u in churn:
    print(f"  CHURN {u['id']} restarts={u.get('restarts')}")
for l in lines:
    print(f"  {l}")
PY

INNER_FQDN="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("inner") or {}).get("fqdn") or "")' "$RESULT")"
VERDICT="$(python3 "$HERE/verdict.py" "$RESULT")" \
  || die "could not calculate the live verdict"
say "verdict $VERDICT"

# ------------------------------------------------------------------ publish
# Publishing is its own failure domain and must be distinguishable from the run
# failing. Three states have to stay apart: never started (no result file at all),
# ran and failed (result file, bad verdict), ran but could not publish (result
# file, good verdict, and the marker below). The dead-man in the weekly wiring
# reads exactly those.
#
# It goes to a comment on a tracking issue, not to a branch: a push to any branch
# runs CI, and CI's leak guard would fail on a result containing a tailnet name.
# Issues do not trigger it, they are where people already look, and the scheduled
# watcher can read the latest comment's timestamp and verdict without checking
# anything out.
#
# What gets published is REDACTED. The local record keeps the tailnet FQDN, the ssh
# destination and the full logs; the published one carries the run id, the commit,
# the verdict, the exit codes, the per-unit facts and the smoke lines with the
# FQDN removed. This repository is mirrored publicly and the guard that stops
# internal names getting there is a scan, not a habit.
if [ "$PUBLISH" = gh ]; then
  STAGE=publishing
  : "${AIRLOCK_LIVE_ISSUE:?AIRLOCK_LIVE_PUBLISH=gh needs AIRLOCK_LIVE_ISSUE (the tracking issue number)}"
  BODY="$RESULT_DIR/$RUN_ID.comment.md"
  VERDICT="$VERDICT" python3 "$HERE/mkcomment.py" "$RESULT" > "$BODY" \
    || die "could not render the published comment"
  # The redaction is asserted, not trusted: if the tailnet name survived into the
  # comment, do not post it. A leak is worse than a missed heartbeat, and the
  # heartbeat has its own alarm below.
  if [ -n "${INNER_FQDN:-}" ] && grep -qF "$INNER_FQDN" "$BODY"; then
    die "refusing to publish: the container's tailnet name survived redaction"
  fi
  pub_ok=0
  for attempt in 1 2 3; do
    if gh issue comment "$AIRLOCK_LIVE_ISSUE" --body-file "$BODY" >/dev/null 2>>"$LOGFILE"; then
      pub_ok=1; break
    fi
    say "publish attempt $attempt failed; retrying"
    sleep $(( attempt * 10 ))
  done
  if [ "$pub_ok" = 1 ]; then
    STAGE=published
    rm -f "$RESULT_DIR/PUBLISH-FAILING"
  else
    STAGE=publish_failed
    # A local alarm, because the thing that would have carried the alarm is the
    # thing that just failed. The weekly watcher and a human both look here.
    {
      printf 'run %s could not publish its result at %s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'the run itself finished with verdict %s — this is a publishing failure, not a verification failure\n' "$VERDICT"
      printf 'see %s\n' "$LOGFILE"
    } > "$RESULT_DIR/PUBLISH-FAILING"
    say "WARNING: the run finished but its result could not be published — $RESULT_DIR/PUBLISH-FAILING"
  fi
fi
write_result

# The heartbeat is written last and only on a clean verdict, so "the job ran" and
# "the job passed" are not the same file.
if [ "$VERDICT" = 0 ] || [ "$VERDICT" = 3 ]; then
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SHA" "$VERDICT" > "$RESULT_DIR/LAST-GREEN"
  # And retract the alarm. `FAILING` is written by alarm.sh and, until this line, by
  # nothing that could ever remove it: one bad week left a marker that outlived every
  # green run after it. A watchdog reading that file then reports a failure that has
  # already been fixed, every hour, until somebody deletes it by hand — which trains
  # people to ignore it, which is worse than not having it. `PUBLISH-FAILING` is
  # cleared the same way above, on the same principle.
  rm -f "$RESULT_DIR/FAILING" "$RESULT_DIR/LAST-FAILURE"
fi
printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SHA" "$VERDICT" > "$RESULT_DIR/LAST-RUN"

exit "$VERDICT"
