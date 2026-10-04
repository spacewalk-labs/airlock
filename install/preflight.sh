#!/usr/bin/env bash
# Shared prerequisite checker. Source this file; do not source app installers.

AIRLOCK_PREREQUISITES="$AIRLOCK_ROOT/install/prerequisites.tsv"
# System daemons (nginx, nft) live in the sbin directories, which are absent
# from an unprivileged PATH in some sessions. Assigned unconditionally, like
# AIRLOCK_PREREQUISITES above, so an ambient value cannot redirect daemon
# discovery in production; the suite overrides it in-process after sourcing.
AIRLOCK_PREFLIGHT_SBIN_DIRS="/usr/local/sbin /usr/sbin /sbin"

airlock_find_cmd() {
  local hit d base
  # `type -P` admits executable files from PATH, not ambient shell functions or
  # aliases: a resolved prerequisite must name something a fresh lifecycle
  # child can execute too.
  if hit="$(type -P "$1" 2>/dev/null)"; then
    case "$hit" in
      /*) ;;
      */*) d="${hit%/*}"; base="${hit##*/}"
           hit="$(cd -P -- "$d" && printf '%s/%s\n' "$PWD" "$base")" || return 1 ;;
      *)   hit="$(cd -P -- . && printf '%s/%s\n' "$PWD" "$hit")" || return 1 ;;
    esac
    printf '%s\n' "$hit"
    return 0
  fi
  # System daemons (nginx, nft) live in the sbin directories, which are not on
  # an unprivileged PATH in every session. Without this fallback, preflight
  # reports an installed-and-running nginx as "missing" and the installer
  # refuses to run -- the failure looks like a missing package, so the operator
  # is told to apt-get install something that is already there.
  for d in $AIRLOCK_PREFLIGHT_SBIN_DIRS; do
    if [ -x "$d/$1" ]; then printf '%s\n' "$d/$1"; return 0; fi
  done
  return 1
}

# Compatibility name for callers and fixtures written before the resolver was
# shared. There is deliberately no second implementation behind this name.
airlock_preflight_find() { airlock_find_cmd "$@"; }

airlock_load_nvm() {
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
  fi
}

airlock_preflight_table_header() {
  printf '%-14s %-28s %-15s %-42s %s\n' \
    "requirement" "detected value/path" "status" "exact fix" "required by"
}

airlock_preflight_version_ge() {
  local actual="${1:?}" expected="${2:?}" actual_major actual_minor expected_major expected_minor
  [[ "$actual" =~ ^[0-9]{1,6}([.][0-9]{1,6})?$ ]] || return 1
  [[ "$expected" =~ ^[0-9]{1,6}([.][0-9]{1,6})?$ ]] || return 1
  actual_major="${actual%%.*}"; actual_minor="${actual#*.}"
  expected_major="${expected%%.*}"; expected_minor="${expected#*.}"
  [ "$actual_minor" != "$actual" ] || actual_minor=0
  [ "$expected_minor" != "$expected" ] || expected_minor=0
  (( 10#$actual_major > 10#$expected_major )) \
    || { (( 10#$actual_major == 10#$expected_major )) \
      && (( 10#$actual_minor >= 10#$expected_minor )); }
}

airlock_preflight_keyring_pressure() {
  # Docker/LXC may fail to create a session keyring near the per-UID key quota
  # and report the misleading text "disk quota exceeded".  The governing
  # sysctl is host-wide for the container, so this is deliberately diagnostic:
  # an unprivileged in-container installer must never try to change it.
  local proc_root="${1:?}" uid="${2:?}" control="kernel.keys.maxkeys"
  local control_path="$proc_root/sys/kernel/keys/maxkeys"
  local sysctl_limit usage_pair="" row_uid key_fields=()
  local used row_limit limit percent map_inside="" map_outside="" map_count=""
  local namespaced_root=0 uid_description="uid $uid"
  if [ "$uid" = 0 ] && [ -r "$proc_root/self/uid_map" ]; then
    IFS=$' \t' read -r map_inside map_outside map_count < "$proc_root/self/uid_map" || true
    if [[ "$map_inside" = 0 && "$map_outside" =~ ^[1-9][0-9]*$ \
        && "$map_count" =~ ^[1-9][0-9]*$ ]]; then
      namespaced_root=1
      uid_description="uid 0 (mapped host uid $map_outside)"
    fi
  fi
  # Namespace root is an ordinary host UID and consumes maxkeys. Only real
  # initial-namespace root is governed by root_maxkeys.
  if [ "$uid" = 0 ] && [ "$namespaced_root" = 0 ] \
      && [ -r "$proc_root/sys/kernel/keys/root_maxkeys" ]; then
    control="kernel.keys.root_maxkeys"
    control_path="$proc_root/sys/kernel/keys/root_maxkeys"
  fi
  [ -r "$control_path" ] && [ -r "$proc_root/key-users" ] || return 0
  IFS= read -r sysctl_limit < "$control_path" || return 0
  # Do not depend on awk here: this check runs before prerequisite discovery,
  # including in deliberately minimal bootstrap environments.
  while IFS=$' \t' read -r -a key_fields; do
    row_uid="${key_fields[0]:-}"
    usage_pair="${key_fields[3]:-}"
    [ "$row_uid" = "$uid:" ] && break
    usage_pair=""
  done < "$proc_root/key-users"
  [ -n "$usage_pair" ] || return 0
  used="${usage_pair%/*}"; row_limit="${usage_pair#*/}"
  [[ "$sysctl_limit" =~ ^[1-9][0-9]*$ && "$used" =~ ^[0-9]+$ \
    && "$row_limit" =~ ^[1-9][0-9]*$ ]] || return 0
  limit="$sysctl_limit"
  # qnkeys' displayed denominator follows maxkeys even for host root on some
  # kernels; root's enforceable quota is root_maxkeys, so only non-root rows
  # use the smaller displayed bound as a defensive consistency check.
  if [ "$uid" != 0 ] || [ "$namespaced_root" = 1 ]; then
    [ "$row_limit" -ge "$limit" ] || limit="$row_limit"
  fi
  [ "$used" -le "$limit" ] || used="$limit"
  # 90% leaves enough warning room before a container start consumes the last
  # few keys; the observed default-limit failure was 1997/2000.
  (( used * 100 >= limit * 90 )) || return 0
  percent=$((used * 100 / limit))
  log "WARN: kernel key quota for $uid_description is near saturation: $used/$limit (${percent}%; $control=$sysctl_limit). Container startup can fail with 'unable to join session keyring: ... disk quota exceeded'; this is key quota, not disk space. The limit cannot be repaired from inside this container: on its host, raise $control persistently under /etc/sysctl.d/ and apply it with sysctl --system."
}

airlock_preflight_userns_root_host_uid() {
  local proc_root="${1:?}" map_inside="" map_outside="" map_count=""
  [ -r "$proc_root/self/uid_map" ] || return 1
  IFS=$' \t' read -r map_inside map_outside map_count < "$proc_root/self/uid_map" || return 1
  [[ "$map_inside" = 0 && "$map_outside" =~ ^[1-9][0-9]*$ \
    && "$map_count" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$map_outside"
}

airlock_preflight_bootstrap() {
  local py
  py="$(airlock_preflight_find python3)" || py=""
  if [ -z "$py" ]; then
    airlock_preflight_table_header
    printf '%-14s %-28s %-15s %-42s %s\n' \
      "python3 >=3.11" "-" "missing" \
      "sudo apt-get update && sudo apt-get install -y python3" "core"
    return 1
  fi
}

airlock_preflight() {
  local quiet=0
  [ "${1:-}" = "--quiet" ] && quiet=1
  [ "$#" -le 1 ] || { log "preflight: invalid invocation"; return 2; }
  [ "$#" -eq 0 ] || [ "${1:-}" = "--quiet" ] \
    || { log "preflight: invalid option: ${1:-}"; return 2; }
  airlock_preflight_keyring_pressure /proc "$UID"
  # In an LXC user namespace Docker runs as namespace root, which maps to an
  # ordinary host subuid and has its own key quota row. Check that consumer as
  # well as the interactive installer; otherwise a healthy user row masks the
  # exact quota that prevents Docker from creating a session keyring.
  if [ "$UID" != 0 ] && airlock_preflight_userns_root_host_uid /proc >/dev/null; then
    airlock_preflight_keyring_pressure /proc 0
  fi
  [ -r "$AIRLOCK_PREREQUISITES" ] \
    || { log "preflight: declaration file not readable: $AIRLOCK_PREREQUISITES"; return 2; }

  local apps owner cmd predicate expected fix note owner_key owner_label
  apps="$(airlock_config json)" \
    || { log "preflight: could not read enabled apps"; return 2; }

  # Core declarations stay TSV. Package keys and prerequisite arrays are JSON;
  # NUL fields keep every allowed ID intact through the shell reader.
  local tmp_decl tmp_info cleanup
  tmp_decl="$(mktemp)" || { log "preflight: mktemp failed"; return 2; }
  tmp_info="$(mktemp)" || { rm -f -- "$tmp_decl"; return 2; }
  printf -v cleanup 'rm -f -- %q %q; trap - RETURN' "$tmp_decl" "$tmp_info"
  trap "$cleanup" RETURN
  airlock_package_info >"$tmp_info" || return 2
  if ! python3 - "$AIRLOCK_ROOT/bin/airlock-config" "$AIRLOCK_PREREQUISITES" "$apps" "$tmp_info" >"$tmp_decl" <<'PY_PREREQS'
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
tool, path, config_json, package_file = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("_airlock_preflight_config", tool)
spec = importlib.util.spec_from_loader(loader.name, loader)
config = importlib.util.module_from_spec(spec)
loader.exec_module(config)
enabled = set(json.loads(config_json).get("apps", {})) | {"core"}
packages = json.loads(Path(package_file).read_text()).get("packages", {})

def emit(owner, fields):
    command = fields[0]
    if owner not in enabled or not command:
        return
    owner_key = json.dumps([command, owner], ensure_ascii=False)
    owner_label = json.dumps(owner, ensure_ascii=False)[1:-1]
    sys.stdout.write("\0".join([owner, *fields, owner_key, owner_label]) + "\0")

for row in config._prerequisite_rows(packages, Path(path)):
    owner, *values = (row + [""] * 6)[:6]
    emit(owner, values)
PY_PREREQS
  then
    log "preflight: prerequisite assembly failed"
    return 2
  fi

  local -A predicates=() expecteds=() fixes=() owner_set=() owner_display=()
  local select_nvm=0
  while IFS= read -r -d '' owner \
    && IFS= read -r -d '' cmd \
    && IFS= read -r -d '' predicate \
    && IFS= read -r -d '' expected \
    && IFS= read -r -d '' fix \
    && IFS= read -r -d '' note \
    && IFS= read -r -d '' owner_key \
    && IFS= read -r -d '' owner_label; do
    if [ -z "${owner_set[$owner_key]:-}" ]; then
      owner_set[$owner_key]=1
      # Presentation only: IDs are never recovered by splitting this string.
      owner_display[$cmd]="${owner_display[$cmd]:+${owner_display[$cmd]},}$owner_label"
    fi
    [ "$cmd:$owner" != node:paseo ] || select_nvm=1
    if [ -n "${predicates[$cmd]:-}" ]; then
      case "${predicates[$cmd]}:$predicate" in
        present:present) ;;
        present:major-gte) predicates[$cmd]="$predicate"; expecteds[$cmd]="$expected" ;;
        major-gte:present) ;;
        major-gte:major-gte)
          if airlock_preflight_version_ge "$expected" "${expecteds[$cmd]}" \
            && [ "$expected" != "${expecteds[$cmd]}" ]; then
            expecteds[$cmd]="$expected"
          fi ;;
        *) ;;
      esac
    else
      predicates[$cmd]="$predicate"; expecteds[$cmd]="$expected"
      fixes[$cmd]="$fix"
    fi
  done < "$tmp_decl"
  # Runtime selection precedes the version probe. Key this to the effective
  # manifest row, not merely the package id: a package
  # shadowing paseo without a Node prerequisite made no NVM contract.
  [ "$select_nvm" = 0 ] || airlock_load_nvm

  local -a failures=()
  local path version req status detected selected_owners=""
  for cmd in "${!predicates[@]}"; do
    selected_owners="${owner_display[$cmd]}"
    path="$(airlock_find_cmd "$cmd")" || path=""
    status=present; detected="$path"; req="$cmd"
    if [ -z "$path" ]; then
      status=missing; detected="-"
    elif [ "${predicates[$cmd]}" = major-gte ]; then
      version="$("$path" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || version=""
      if [ "$cmd" != python3 ]; then
        version="$("$path" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || version=""
      fi
      [[ "$version" =~ ^[0-9]+([.][0-9]+)?$ ]] || version=""
      detected="${version:-$path}"
      req="$cmd >=${expecteds[$cmd]}"
      airlock_preflight_version_ge "${version:-0}" "${expecteds[$cmd]}" \
        || status=wrong-version
    fi
    [ "$status" = present ] \
      || failures+=("$req"$'\t'"$detected"$'\t'"$status"$'\t'"${fixes[$cmd]}"$'\t'"$selected_owners")
  done

  if [ "${#failures[@]}" -gt 0 ]; then
    airlock_preflight_table_header
    while IFS=$'\t' read -r req detected status fix selected_owners; do
      printf '%-14s %-28s %-15s %-42s %s\n' \
        "$req" "$detected" "$status" "$fix" "$selected_owners"
    done < <(printf '%s\n' "${failures[@]}" | sort)
    return 1
  fi
  [ "$quiet" = 1 ] || log "prerequisite preflight passed"
}
