#!/usr/bin/env bash
# Static seams that must hold even when CI has no graphical display.
# shellcheck disable=SC2016 # grep assertions intentionally match literal shell source.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUI="$HERE/gui-installer.py"
CORE_TEST="$HERE/test-gui-installer.py"
HELPER="$HERE/gui-provisioner-entrypoint.sh"
PROVISIONER="$HERE/gui-provisioner.sh"
DESKTOP="$HERE/org.airlock.Installer.desktop"
POLICY="$HERE/org.airlock.Installer.policy"

pass=0 fail=0
ok() { printf 'ok   gui-installer: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL gui-installer: %s\n' "$1"; fail=$((fail + 1)); }

if python3 -m py_compile "$GUI" "$HERE/gui_installer_core.py" "$HERE/gui_selection.py" "$CORE_TEST" \
  && bash -n "$HELPER" "$PROVISIONER"; then
  ok "Python and Bash entrypoints parse"
else
  bad "entrypoint syntax check failed"
fi

if (cd "$HERE" && python3 "$(basename "$CORE_TEST")") >/dev/null; then
  ok "headless bundle/request/event contracts pass"
else
  bad "headless bundle/request/event contracts failed"
fi

if grep -Fq '["pkexec", str(self.inputs.helper)]' "$GUI" \
  && grep -Fq 'orientation=Gtk.Orientation.VERTICAL' "$GUI" \
  && grep -Fq 'Gtk.Expander(label="자세히")' "$GUI" \
  && ! grep -Eq 'gnome-terminal|xterm|bash[[:space:]]+-c' "$GUI"; then
  ok "window launches only the fixed helper and keeps raw output behind Details"
else
  bad "GUI command or Details boundary drifted"
fi

if grep -Fq 'Terminal=false' "$DESKTOP" \
  && grep -Fq 'Exec=/usr/bin/python3 /usr/libexec/airlock-gui-installer/gui-installer.py' "$DESKTOP" \
  && ! grep -Eq 'gnome-terminal|xterm' "$DESKTOP" \
  && ! grep -Fq 'org.freedesktop.policykit.exec.allow_gui' "$POLICY" \
  && python3 - "$POLICY" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
action = root.find("./action[@id='org.airlock.installer.run']")
assert action is not None
annotations = {node.attrib["key"]: (node.text or "") for node in action.findall("annotate")}
assert annotations["org.freedesktop.policykit.exec.path"] == "/usr/libexec/airlock-gui-installer-helper"
assert action.findtext("defaults/allow_active") == "auth_admin_keep"
PY
then
  ok "desktop entry opens no terminal and policy pins the one root helper"
else
  bad "desktop or PolicyKit contract drifted"
fi

if grep -Fq 'CONFIG=/etc/airlock-gui-installer.json' "$HELPER" \
  && ! grep -Fq 'AIRLOCK_GUI_INSTALLER_CONFIG:-' "$HELPER" \
  && grep -Fq 'dd bs=65537 count=1' "$HELPER" \
  && grep -Fq 'selected_optional_apps' "$HELPER"; then
  ok "root helper trusts fixed config and accepts one bounded stdin request"
else
  bad "root helper trust boundary drifted"
fi

validation_line="$(grep -n 'Everything above this line precedes the first persistent/package mutation' "$PROVISIONER" | cut -d: -f1)"
apt_line="$(grep -n '^apt-get update' "$PROVISIONER" | head -1 | cut -d: -f1)"
if [ -n "$validation_line" ] && [ -n "$apt_line" ] && [ "$validation_line" -lt "$apt_line" ] \
  && grep -Fq 'set(request) != {"schema", "selected_optional_apps"}' "$HERE/gui_selection.py" \
  && grep -Fq 'selection directly names locked app' "$HERE/gui_selection.py" \
  && grep -Fq 'python3 "$selection_helper"' "$PROVISIONER"; then
  ok "root provisioner revalidates selection before first package mutation"
else
  bad "selection validation no longer precedes mutation"
fi

if grep -Fq 'mktemp -d "/opt/airlock-gui/releases/.${source_sha}.XXXXXX"' "$PROVISIONER" \
  && grep -Fq 'mv "$release_staging" "$release"' "$PROVISIONER" \
  && ! grep -Fq 'mv "$payload" "$release"' "$PROVISIONER"; then
  ok "release publication stages and renames on the destination filesystem"
else
  bad "release publication can leave a cross-filesystem partial release"
fi

if grep -Fq '"event": "failed"' "$PROVISIONER" \
  && grep -Fq '"message": os.environ["MESSAGE"]' "$PROVISIONER" \
  && grep -Fq '"remedy": os.environ["REMEDY"]' "$PROVISIONER" \
  && grep -Fq 'doc["log"]' "$PROVISIONER"; then
  ok "terminal failures carry code, human message, remedy and optional log reference"
else
  bad "structured human-readable failure contract drifted"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
