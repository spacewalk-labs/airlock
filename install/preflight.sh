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
  # aliases. A prerequisite receipt must name something a fresh lifecycle child
  # can execute too.
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

airlock_prerequisite_receipt_lookup() {
  local name="${1:?}" file="${AIRLOCK_PREREQ_RECEIPT:-}" row_cmd row_path predicate expected owners
  [ -n "$file" ] && [ -r "$file" ] || return 1
  while IFS=$'\t' read -r row_cmd row_path predicate expected owners; do
    case "$row_cmd" in ''|\#*) continue ;; esac
    if [ "$row_cmd" = "$name" ]; then
      printf '%s\t%s\t%s\t%s\n' "$row_path" "$predicate" "$expected" "$owners"
      return 0
    fi
  done < "$file"
  return 1
}

airlock_prerequisite_path_is_current() {
  local name="${1:?}" recorded="${2:?}" current=""
  current="$(airlock_find_cmd "$name")" || return 1
  [ "$current" = "$recorded" ] && [ -x "$recorded" ]
}

airlock_verify_prerequisite_receipt() {
  local file="${AIRLOCK_PREREQ_RECEIPT:-}" row_cmd row_path predicate expected owners
  local count=0 version="" context_seen=0 line=""
  [ -n "$file" ] && [ -r "$file" ] || {
    log "prerequisite receipt is missing or unreadable: ${file:-<unset>}"
    return 2
  }
  while IFS= read -r line; do
    case "$line" in
      '# context='*)
        [ "$line" = "# context=${AIRLOCK_PREREQ_CONTEXT:-standalone}" ] || {
          log "prerequisite receipt belongs to a different install candidate"
          return 1
        }
        context_seen=1
        continue ;;
    esac
    IFS=$'\t' read -r row_cmd row_path predicate expected owners <<< "$line"
    case "$row_cmd" in ''|\#*) continue ;; esac
    count=$((count + 1))
    airlock_prerequisite_path_is_current "$row_cmd" "$row_path" || {
      log "prerequisite changed after preflight: $row_cmd (was $row_path)"
      return 1
    }
    if [ "$predicate" = major-gte ]; then
      version="$("$row_path" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || version=""
      if [ "$row_cmd" != python3 ]; then
        version="$("$row_path" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || version=""
      fi
      [[ "$version" =~ ^[0-9]+([.][0-9]+)?$ ]] || version=""
      airlock_preflight_version_ge "${version:-0}" "$expected" || {
        log "prerequisite version changed after preflight: $row_cmd (found ${version:-unknown}, need $expected)"
        return 1
      }
    fi
  done < "$file"
  [ "$context_seen" = 1 ] || { log "prerequisite receipt has no candidate context"; return 2; }
  [ "$count" -gt 0 ] || { log "prerequisite receipt contains no commands: $file"; return 2; }
}

airlock_load_nvm() {
  # An orchestrated lifecycle must keep the exact runtime preflight recorded.
  # Re-sourcing nvm here can replace an approved system node with a different
  # nvm node; require_cmd then correctly rejects our own path change as drift.
  # Direct app invocation has no receipt authority and retains nvm discovery.
  if [ -n "${AIRLOCK_INSTALL_PKG_INFO_SHA256:-}" ] \
    && [ -n "${AIRLOCK_PREREQ_RECEIPT:-}" ]; then
    return 0
  fi
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
  local py version
  py="$(airlock_preflight_find python3)" || py=""
  if [ -z "$py" ]; then
    airlock_preflight_table_header
    printf '%-14s %-28s %-15s %-42s %s\n' \
      "python3 >=3.11" "-" "missing" \
      "sudo apt-get update && sudo apt-get install -y python3" "core"
    return 1
  fi
  version="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || version=""
  [[ "$version" =~ ^[0-9]{1,6}[.][0-9]{1,6}$ ]] || version=""
  if ! airlock_preflight_version_ge "${version:-0}" 3.11; then
    airlock_preflight_table_header
    printf '%-14s %-28s %-15s %-42s %s\n' \
      "python3 >=3.11" "${version:-$py}" "wrong-version" \
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

  local enabled app apps line_no=0 declaration_line owner cmd predicate expected fix note extra
  enabled=$'\ncore\n'
  apps="$(airlock_config apps)" \
    || { log "preflight: could not read enabled apps"; return 2; }
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    enabled+="$app"$'\n'
  done <<<"$apps"

  # F11: with [packages.*] configured, airlock-config OWNS assembly (steps
  # 1-4: TSV pass-through, shadowed-owner row replacement, manifest rows,
  # per-row validity) and this function keeps evaluation — every cross-row
  # rule below runs unchanged on the assembled inventory. Without packages
  # the raw TSV is read exactly as before (byte-identical path).
  local packaged=$'\n' decl_file="$AIRLOCK_PREREQUISITES" decl_name="$AIRLOCK_PREREQUISITES" tmp_decl=""
  if [ -n "${AIRLOCK_PKG_INFO:-}" ]; then
    local pkg_id_lines
    pkg_id_lines="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c \
      'import sys, json; print("\n".join(sorted(json.load(sys.stdin)["packages"])))')" \
      || { log "preflight: could not read package ids from package-info"; return 2; }
    while IFS= read -r app; do
      [ -n "$app" ] || continue
      packaged+="$app"$'\n'
    done <<<"$pkg_id_lines"
  fi
  if [ "$packaged" != $'\n' ]; then
    tmp_decl="$(mktemp)" || { log "preflight: mktemp failed"; return 2; }
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_decl'; trap - RETURN" RETURN
    # Capture to a file and test the exit status DIRECTLY: process
    # substitution would discard the producer's failure and evaluate a
    # truncated inventory as if it were complete.
    if ! AIRLOCK_PREREQUISITES="$AIRLOCK_PREREQUISITES" airlock_config prereqs > "$tmp_decl"; then
      log "preflight: prerequisite assembly failed (airlock-config prereqs)"
      return 2
    fi
    decl_file="$tmp_decl"
    decl_name="airlock-config prereqs"
  fi

  local declaration_count=0
  local row_key
  local -A predicates=() expecteds=() fixes=() owners=() seen_rows=() all_fixes=() resolved_paths=()
  while IFS= read -r declaration_line || [ -n "$declaration_line" ]; do
    line_no=$((line_no + 1))
    case "$declaration_line" in ""|\#*) continue ;; esac
    # Bash treats tab as IFS whitespace and collapses adjacent delimiters. Reject
    # empty fields before splitting so a missing remediation cannot shift the
    # following columns left and masquerade as a complete declaration.
    case "$declaration_line" in
      $'\t'*|*$'\t'|*$'\t\t'*)
        log "preflight: invalid declaration at $decl_name:$line_no"
        return 2 ;;
    esac
    owner='' cmd='' predicate='' expected='' fix='' note='' extra=''
    IFS=$'\t' read -r owner cmd predicate expected fix note extra <<<"$declaration_line"
    if [ -n "${extra:-}" ] || [ -z "$cmd" ] || [ -z "$predicate" ] \
      || [ -z "$expected" ] || [ -z "$fix" ] || [ -z "$note" ]; then
      log "preflight: invalid declaration at $decl_name:$line_no"
      return 2
    fi
    [[ "$owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
      || { log "preflight: invalid owner at $decl_name:$line_no"; return 2; }
    case "$owner" in
      core) ;;
      *)
        # A package owner is legitimated by package-info alone (child 4/P3:
        # every non-core owner is a shipped or explicit package now — the
        # legacy $AIRLOCK_ROOT/apps/<owner> tree escape for a not-yet-
        # packaged built-in TSV row is retired).
        case "$packaged" in *$'\n'"$owner"$'\n'*) ;; *)
          log "preflight: unknown declaration owner '$owner' at $decl_name:$line_no"; return 2 ;;
        esac ;;
    esac
    [[ "$cmd" =~ ^[a-zA-Z0-9._+-]+$ ]] \
      || { log "preflight: invalid command at $decl_name:$line_no"; return 2; }
    case "$predicate" in
      present) [ "$expected" = "-" ] \
        || { log "preflight: invalid predicate at $decl_name:$line_no"; return 2; } ;;
      major-gte)
        [[ "$expected" =~ ^[0-9]{1,6}([.][0-9]{1,6})?$ ]] \
          || { log "preflight: invalid predicate at $decl_name:$line_no"; return 2; }
        case "$cmd" in python3|node) ;; *)
          log "preflight: major-gte has no version probe for $cmd at $decl_name:$line_no"
          return 2 ;;
        esac ;;
      *) log "preflight: invalid predicate at $decl_name:$line_no"; return 2 ;;
    esac
    row_key="$owner"$'\t'"$cmd"
    [ -z "${seen_rows[$row_key]:-}" ] \
      || { log "preflight: duplicate declaration for $owner/$cmd"; return 2; }
    seen_rows[$row_key]=1
    if [ -n "${all_fixes[$cmd]:-}" ] && [ "${all_fixes[$cmd]}" != "$fix" ]; then
      log "preflight: conflicting remediation for $cmd"
      return 2
    fi
    all_fixes[$cmd]="$fix"
    declaration_count=$((declaration_count + 1))

    case "$enabled" in *$'\n'"$owner"$'\n'*) ;; *) continue ;; esac
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
        *) log "preflight: conflicting predicates for $cmd"; return 2 ;;
      esac
      owners[$cmd]="${owners[$cmd]},$owner"
    else
      predicates[$cmd]="$predicate"; expecteds[$cmd]="$expected"
      fixes[$cmd]="$fix"; owners[$cmd]="$owner"
    fi
  done < "$decl_file"
  [ "$declaration_count" -gt 0 ] \
    || { log "preflight: declaration file contains no requirements"; return 2; }
  for cmd in python3 nginx sudo systemctl tailscale curl flock; do
    [ -n "${predicates[$cmd]:-}" ] && case ",${owners[$cmd]}," in *,core,*) continue ;; esac
    log "preflight: required core declaration missing: $cmd"
    return 2
  done
  # Runtime selection precedes both the version probe and receipt publication.
  # Key this to the effective manifest row, not merely the package id: a package
  # shadowing paseo without a Node prerequisite made no NVM contract.
  case ",${owners[node]:-}," in *,paseo,*) airlock_load_nvm ;; esac

  local -a failures=()
  local path version req status detected selected_owners=""
  for cmd in "${!predicates[@]}"; do
    selected_owners=""
    IFS=',' read -ra _owners <<<"${owners[$cmd]}"
    for owner in "${_owners[@]}"; do
      case "$enabled" in *$'\n'"$owner"$'\n'*) selected_owners="${selected_owners:+$selected_owners,}$owner" ;; esac
    done
    [ -n "$selected_owners" ] || continue
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
    if [ "$status" = present ]; then
      resolved_paths[$cmd]="$path"
    else
      failures+=("$req"$'\t'"$detected"$'\t'"$status"$'\t'"${fixes[$cmd]}"$'\t'"$selected_owners")
    fi
  done

  if [ "${#failures[@]}" -gt 0 ]; then
    airlock_preflight_table_header
    while IFS=$'\t' read -r req detected status fix selected_owners; do
      printf '%-14s %-28s %-15s %-42s %s\n' \
        "$req" "$detected" "$status" "$fix" "$selected_owners"
    done < <(printf '%s\n' "${failures[@]}" | sort)
    return 1
  fi
  if [ -n "${AIRLOCK_PREREQ_RECEIPT:-}" ]; then
    local receipt_tmp
    receipt_tmp="$(mktemp "${AIRLOCK_PREREQ_RECEIPT}.XXXXXX")" \
      || { log "preflight: could not create prerequisite receipt"; return 2; }
    chmod 0600 "$receipt_tmp" || { rm -f "$receipt_tmp"; return 2; }
    {
      printf '# airlock-prerequisite-receipt-v1\n'
      printf '# context=%s\n' "${AIRLOCK_PREREQ_CONTEXT:-standalone}"
      for cmd in "${!resolved_paths[@]}"; do
        case "${resolved_paths[$cmd]}" in *$'\t'*|*$'\n'*)
          log "preflight: resolved command path contains a control separator: $cmd"
          rm -f "$receipt_tmp"
          return 2 ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$cmd" "${resolved_paths[$cmd]}" \
          "${predicates[$cmd]}" "${expecteds[$cmd]}" "${owners[$cmd]}"
      done | LC_ALL=C sort
    } > "$receipt_tmp" || { rm -f "$receipt_tmp"; return 2; }
    mv -f "$receipt_tmp" "$AIRLOCK_PREREQ_RECEIPT" \
      || { rm -f "$receipt_tmp"; log "preflight: could not publish prerequisite receipt"; return 2; }
  fi
  [ "$quiet" = 1 ] || log "prerequisite preflight passed"
}
