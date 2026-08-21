#!/usr/bin/env bash
# install/test-snap-node.sh — snap-wrapped node vs NoNewPrivileges.
#
# The defect, measured on 2026-08-07: /snap/bin/node is a symlink to /usr/bin/snap,
# snap re-executes the real interpreter through the setuid-root snap-confine, and
# `NoNewPrivileges=yes` neuters setuid. snap reports nothing. airlock-paseo restarted
# 4,242 times with a journal containing only the restart lines. Isolated with
# systemd-run: identical environment, memory caps, TasksMax and port all start fine;
# adding the one directive reproduces `failed / status=1 / 0 bytes`.
#
# None of that can be reproduced here. The GitHub runner has no snapd, and neither
# does a developer box that installed node any other way. So the detection is written
# as a pure function of three strings the caller measures — install/lib.sh's
# airlock_snap_probe — and this file drives it over a truth table plus the two
# install paths (refuse / override) under AIRLOCK_DRY_RUN with a fabricated snap
# layout on PATH. What is NOT claimed anywhere here is that the kernel behaves as
# described; that was measured on a real box once, and the harness in step 3 of
# docs/tasks/active/live-verification-and-recurrence-gates.md is what keeps measuring it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok   snap-node: $1"; pass=$((pass+1)); }
bad() { echo "FAIL snap-node: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. the classifier, on a truth table ----
# found | resolved | runtime | expected probes (empty = not a snap)
probe() {
  bash -c '. "$1/install/lib.sh" >/dev/null 2>&1; airlock_snap_probe "$2" "$3" "$4"' \
    _ "$ROOT" "$1" "$2" "$3" 2>/dev/null
}
while IFS='|' read -r found real runtime want label; do
  [ -n "$label" ] || continue
  got="$(probe "$found" "$real" "$runtime")"
  if [ "$got" = "$want" ]; then
    ok "classifier: $label -> [${got:-none}]"
  else
    bad "classifier: $label -> got [${got:-none}], want [${want:-none}]"
  fi
done <<'TABLE'
/usr/bin/node|/usr/bin/node||apt node, runtime unreadable
/usr/bin/node|/usr/bin/node|/usr/bin/node|apt node
/home/u/.nvm/versions/node/v20.11.0/bin/node|/home/u/.nvm/versions/node/v20.11.0/bin/node|/home/u/.nvm/versions/node/v20.11.0/bin/node|nvm node
/usr/local/bin/node|/usr/local/bin/node|/usr/local/bin/node|tarball node
|||no node at all
/snap/bin/node|/usr/bin/snap|/snap/node/current/bin/node|path resolved runtime|the real snap layout
/snap/bin/node|/usr/bin/snap||path resolved|snap, runtime unreadable
/snap/bin/node|/snap/bin/node|/snap/bin/node|path resolved runtime|snap wrapper that does not resolve away
/usr/local/bin/node|/usr/bin/snap|/snap/node/current/bin/node|resolved runtime|wrapper installed outside /snap/bin
/usr/local/bin/node|/usr/local/bin/node|/snap/node/current/bin/node|runtime|only the interpreter knows
/opt/snapshot-tools/bin/node|/opt/snapshot-tools/bin/node|/opt/snapshot-tools/bin/node||a path that merely starts with snap
/usr/bin/node|/usr/lib/snapd/snap|/snap/node/current/bin/node|resolved runtime|snapd launcher outside /snap
TABLE

# ---- 2. the refusal ----
# A dry run of the real installer with a fabricated snap layout first on PATH.
# The fixture is a directory, not a mock of the classifier: the thing worth testing
# is that install.sh measures the box and reaches the refusal, not that a function
# returns what it was told to.
make_box() {   # make_box <dir> <node-kind>   ; echoes the PATH to use
  local d="$1" kind="$2"
  mkdir -p "$d/home" "$d/render" "$d/shim" "$d/snapbin" "$d/usrbin" "$d/realnode"
  # A node that satisfies `node -p ...` for both the version gate and the runtime probe.
  cat > "$d/realnode/node" <<EOF
#!/bin/sh
case "\$2" in
  *versions.node*) echo 20 ;;
  *execPath*) echo "$( [ "$kind" = snap ] && echo /snap/node/current/bin/node || echo "$d/realnode/node" )" ;;
  *) echo 20 ;;
esac
EOF
  chmod +x "$d/realnode/node"
  printf '#!/bin/sh\nexit 0\n' > "$d/realnode/npm"; chmod +x "$d/realnode/npm"
  if [ "$kind" = snap ]; then
    # /usr/bin/snap is what /snap/bin/node resolves to. Faked as a real file so
    # `readlink -f` produces the shape the classifier's `resolved` probe looks for.
    mkdir -p "$d/snap-root/snap/bin" "$d/snap-root/usr/bin"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$d/realnode/node" > "$d/snap-root/usr/bin/snap"
    chmod +x "$d/snap-root/usr/bin/snap"
    ln -sf "$d/snap-root/usr/bin/snap" "$d/snap-root/snap/bin/node"
    printf '#!/bin/sh\nexit 0\n' > "$d/snap-root/snap/bin/npm"; chmod +x "$d/snap-root/snap/bin/npm"
    printf '%s\n' "$d/snap-root/snap/bin:$d/shim:$PATH"
  else
    printf '%s\n' "$d/realnode:$d/shim:$PATH"
  fi
}

# A fixture cannot live at /snap/bin, so the `path` probe is unreachable here and is
# covered by the truth table above instead. What the fixture CAN reproduce is the two
# probes that do not depend on the literal prefix: `readlink -f` landing on a
# launcher named `snap`, and the interpreter reporting an execPath under /snap. Those
# are the two that fire below — the installer measures the box, exactly as it will on
# a real one, and is not told the answer.
run_paseo_dry() {   # run_paseo_dry <dir> <path> [VAR=VAL ...]  ; echoes output, sets RC
  local d="$1" pth="$2"; shift 2
  local cfg="$d/airlock.toml" c out
  printf '[site]\nname = "SnapNode"\n\n[auth]\nprovider = "tailscale"\nowner = "owner@example.com"\n\n[apps.paseo]\n' > "$cfg"
  # Shim every prerequisite command this box may lack — a dry run never executes
  # them, it only needs `command -v` to succeed at require_cmd.
  for c in systemctl tailscale ss sudo nginx python3 curl jq openssl; do
    command -v "$c" >/dev/null 2>&1 || {
      printf '#!/bin/sh\nexit 0\n' > "$d/shim/$c"; chmod +x "$d/shim/$c"; }
  done
  out="$(
    env HOME="$d/home" AIRLOCK_CONFIG="$cfg" AIRLOCK_TS_FQDN="box.example.ts.net" \
        AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$d/render" \
        AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368 PATH="$pth" \
        "$@" bash "$ROOT/apps/paseo/install.sh" 2>&1
  )"; local rc=$?
  printf '%s' "$out"
  return "$rc"
}

d="$TMP/refuse"; p="$(make_box "$d" snap)"
out="$(run_paseo_dry "$d" "$p")"; rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q 'paseo install refused' \
   && printf '%s' "$out" | grep -q 'snap-confine'; then
  ok "a snap-wrapped node is refused before anything is installed"
else
  bad "a snap-wrapped node was not refused (rc=$rc)"
  printf '%s\n' "$out" | tail -12 | sed 's/^/    /'
fi
# The refusal must show all three readings. An operator who cannot see which probe
# fired is being asked to trust a verdict instead of checking it.
for field in 'probes=\[' 'found=' 'resolved=' 'runtime='; do
  printf '%s' "$out" | grep -qE "$field" \
    && ok "refusal names $field" \
    || bad "refusal does not name $field"
done
printf '%s' "$out" | grep -q 'AIRLOCK_ALLOW_SNAP_NODE=1' \
  && ok "refusal names the explicit override" \
  || bad "refusal does not tell the operator how to proceed anyway"
printf '%s' "$out" | grep -qi 'snap install node' \
  && bad "refusal still suggests installing node from snap" \
  || ok "refusal does not suggest the thing it just refused"
[ -f "$d/render/units/airlock-paseo.service" ] \
  && bad "the refusal still wrote a unit" \
  || ok "the refusal wrote nothing"

# ---- 3. the override ----
d="$TMP/override"; p="$(make_box "$d" snap)"
out="$(run_paseo_dry "$d" "$p" AIRLOCK_ALLOW_SNAP_NODE=1)"; rc=$?
unit="$d/render/units/airlock-paseo.service"
if [ "$rc" -eq 0 ] && [ -f "$unit" ]; then
  ok "AIRLOCK_ALLOW_SNAP_NODE=1 lets the install proceed"
  grep -qx 'NoNewPrivileges=no' "$unit" \
    && ok "the override renders NoNewPrivileges=no" \
    || { bad "the override did not turn the directive off"; grep -n 'NoNewPrivileges' "$unit" | sed 's/^/    /'; }
  grep -q 'deliberately OFF for this unit' "$unit" \
    && ok "the unit says the directive is off on purpose" \
    || bad "the unit turns the directive off without saying why"
  grep -q 'snap-confine' "$unit" \
    && ok "the unit names the mechanism, not just the decision" \
    || bad "the unit does not say what snap does that breaks under the directive"
  # Defect 5's shape must not come back through this door: the reason text is
  # assembled by the installer and passed as one argument precisely so it is never
  # re-scanned. If anything in it had been substituted, words would be missing.
  grep -q 'command not found' <<<"$out" \
    && bad "rendering the override reason executed something" \
    || ok "the reason text reached the unit literally"
  grep -qx 'MemoryMax=14G' "$unit" \
    && ok "the override changed only the one directive (memory backstop intact)" \
    || { bad "the override moved something else"; grep -E '^(Memory|Tasks)' "$unit" | sed 's/^/    /'; }
  printf '%s' "$out" | grep -q 'WARNING: paseo is being installed against a snap-wrapped node' \
    && ok "the override is loud in the install log too" \
    || bad "the override is silent in the log"
else
  bad "the override did not produce a unit (rc=$rc)"
  printf '%s\n' "$out" | tail -12 | sed 's/^/    /'
fi

# ---- 4. a native node is untouched ----
d="$TMP/native"; p="$(make_box "$d" native)"
out="$(run_paseo_dry "$d" "$p")"; rc=$?
unit="$d/render/units/airlock-paseo.service"
if [ "$rc" -eq 0 ] && [ -f "$unit" ] && grep -qx 'NoNewPrivileges=yes' "$unit"; then
  ok "a non-snap node installs normally and keeps NoNewPrivileges=yes"
else
  bad "a non-snap node did not take the ordinary path (rc=$rc)"
  printf '%s\n' "$out" | tail -12 | sed 's/^/    /'
fi

# ---- 5. the inventory of units that set the directive ----
# paseo is exonerated by measurement; code-server is exonerated structurally (the
# directive is on the Python manager unit, and the slot unit that actually runs
# code-server carries none); orca is NOT exonerated — its unit execs an extracted
# AppImage AppRun and Electron ships a setuid chrome-sandbox. It passed once on
# 2026-08-07, which is evidence about that run and not about the interaction.
#
# So this is a named list, not a count. A fourth unit appearing means somebody has
# to decide which of those three sentences applies to it.
expected='code-server/installer-path/unit-manager.service
code-server/slots1/unit-manager.service
code-server/slots3/unit-manager.service
orca/default/unit-serve.service
orca/installer-path/unit-serve.service
paseo/default/unit.service
paseo/installer-path/unit.service'
actual="$(cd "$HERE/golden/render" && grep -rlx 'NoNewPrivileges=yes' . 2>/dev/null | sed 's|^\./||' | sort)"
if [ "$actual" = "$expected" ]; then
  ok "exactly the seven known goldens set NoNewPrivileges=yes"
else
  bad "the set of units setting NoNewPrivileges=yes changed — classify the exec chain of each new one"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/    /'
fi
# And the override golden is the one place it is off.
off="$(cd "$HERE/golden/render" && grep -rlx 'NoNewPrivileges=no' . 2>/dev/null | sed 's|^\./||' | sort)"
[ "$off" = "paseo/snap-override/unit.service" ] \
  && ok "the directive is off in exactly one golden, the snap override" \
  || bad "NoNewPrivileges=no appears in an unexpected set of goldens: ${off:-none}"

# ---- 6. the manifests no longer prescribe what the installer refuses ----
if grep -rq 'snap install node' "$ROOT/apps"/*/airlock-app.toml; then
  bad "a manifest still tells the operator to install node from snap"
  grep -rn 'snap install node' "$ROOT/apps"/*/airlock-app.toml | sed 's/^/    /'
else
  ok "no manifest prescribes a snap node"
fi
# One command, one fix: install/preflight.sh:160 rejects two apps declaring
# different fixes for the same command, so paseo and markwand have to agree.
nfix="$(grep -h -A1 'command = "node"' "$ROOT/apps"/*/airlock-app.toml | grep '^fix = ' | sort -u | wc -l)"
[ "$nfix" -le 1 ] \
  && ok "paseo and markwand prescribe the same node fix" \
  || bad "the two node prerequisites disagree on their fix ($nfix distinct) — preflight will reject this"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
