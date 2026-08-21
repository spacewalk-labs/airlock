#!/usr/bin/env bash
# Shared prerequisite checker. Source this file; do not source app installers.

AIRLOCK_PREREQUISITES="$AIRLOCK_ROOT/install/prerequisites.tsv"

airlock_preflight_find() {
  command -v "$1" 2>/dev/null
}

airlock_load_nvm() {
  # Paseo supports a default nvm installation. Preflight and the installer must
  # resolve the same node/npm pair or an ambient Ubuntu node can produce a false
  # wrong-version result before the installer switches to nvm.
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
  local -A predicates=() expecteds=() fixes=() owners=() seen_rows=() all_fixes=()
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
  # Child 4/P3: the row-required rule ("an enabled built-in must own a TSV
  # row") and the paseo nvm-preflight hook were both legacy-built-in-only
  # escapes — a manifest IS the declaration (a zero-prereq package, including
  # one shadowing a built-in tree, is complete without rows), and a packaged
  # paseo resolves its own runtime via its own install.sh (which calls
  # airlock_load_nvm itself; install/test-preflight.sh pins that call site).
  # Every enabled non-hub app is a package now, so both retire.

  local -a failures=()
  local path version req status detected selected_owners=""
  for cmd in "${!predicates[@]}"; do
    selected_owners=""
    IFS=',' read -ra _owners <<<"${owners[$cmd]}"
    for owner in "${_owners[@]}"; do
      case "$enabled" in *$'\n'"$owner"$'\n'*) selected_owners="${selected_owners:+$selected_owners,}$owner" ;; esac
    done
    [ -n "$selected_owners" ] || continue
    path="$(airlock_preflight_find "$cmd")" || path=""
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
    [ "$status" = present ] || failures+=("$req"$'\t'"$detected"$'\t'"$status"$'\t'"${fixes[$cmd]}"$'\t'"$selected_owners")
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
