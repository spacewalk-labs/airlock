#!/usr/bin/env bash
# Worktree mode is hermetic. A configured install switches to live mode and
# validates Docker/runtime absence directly rather than trusting lifecycle rc.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"   # the D5 config entry point sets AIRLOCK_CONFIG_BIN;
                           # reach airlock-config through the ABI var, never $ROOT/bin
CFG="$AIRLOCK_CONFIG_BIN"

docker_cmd=(docker)
docker_ready=0
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then docker_ready=1
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    docker_cmd=(sudo -n docker); docker_ready=1
  fi
fi
docker_run() { "${docker_cmd[@]}" "$@"; }

assert_absent() {
  [ "$docker_ready" = 1 ] || { echo "notes smoke: Docker query UNKNOWN" >&2; return 1; }
  local owned all count
  owned="$(docker_run ps -aq --filter label=io.airlock.package=notes)" \
    || { echo "notes smoke: package-label query UNKNOWN" >&2; return 1; }
  all="$(docker_run ps -a --format '{{.Names}}')" \
    || { echo "notes smoke: name query UNKNOWN" >&2; return 1; }
  count=0
  [ -z "$owned" ] || count=$((count + $(printf '%s\n' "$owned" | sed '/^$/d' | wc -l)))
  while IFS= read -r name; do
    case "$name" in airlock-notes-*) count=$((count+1)) ;; esac
  done <<< "$all"
  if [ "$count" -ne 0 ]; then
    echo "notes smoke: containers=present count=$count" >&2
    return 1
  fi
  echo "notes smoke: containers=absent count=0"
}

if [ "${1:-}" = --assert-absent ]; then
  [ "$#" -eq 1 ] || { echo "usage: $0 [--assert-absent]" >&2; exit 2; }
  assert_absent
  exit $?
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--assert-absent]" >&2; exit 2; }

standalone() {
  local tmp home entries cfg plan client out fail=0
  tmp="$(mktemp -d)" || return 1
  trap 'rm -rf "$tmp"' RETURN
  home="$tmp/home"
  mkdir -p "$home/vault"; chmod 700 "$home/vault"
  entries='[{"id":"main","label":"Main","path":"$HOME/vault","home_file":"README","writable":true}]'
  plan="$tmp/plan.json"; client="$tmp/client.json"; out="$tmp/render"
  PYTHONPYCACHEPREFIX="$tmp/pycache" python3 -m py_compile \
    "$HERE/bin/config-plan.py" "$HERE/bin/editor-supervisor.py" \
    "$HERE/bin/extract-image-path.py" "$HERE/bin/render.py" || fail=1
  python3 - "$tmp/image.tar" <<'PY' || fail=1
import io, json, tarfile, sys
outer_path=sys.argv[1]
def layer(files):
    payload=io.BytesIO()
    with tarfile.open(fileobj=payload,mode="w") as tf:
        for name,data in files.items():
            info=tarfile.TarInfo(name); info.size=len(data); info.mode=0o644
            tf.addfile(info,io.BytesIO(data))
    return payload.getvalue()
layers=[layer({"var/www/perlite/index.php":b"ok", "var/www/perlite/old":b"old"}),
        layer({"var/www/perlite/.wh.old":b"", "var/www/perlite/helper.php":b"helper"})]
with tarfile.open(outer_path,"w") as tf:
    names=[]
    for i,data in enumerate(layers):
        name=f"layer-{i}.tar"; names.append(name)
        info=tarfile.TarInfo(name); info.size=len(data); tf.addfile(info,io.BytesIO(data))
    manifest=json.dumps([{"Config":"config.json","RepoTags":[],"Layers":names}]).encode()
    info=tarfile.TarInfo("manifest.json"); info.size=len(manifest); tf.addfile(info,io.BytesIO(manifest))
PY
  python3 "$HERE/bin/extract-image-path.py" --archive "$tmp/image.tar" \
    --destination "$tmp/extracted" || fail=1
  [ -f "$tmp/extracted/index.php" ] && [ -f "$tmp/extracted/helper.php" ] \
    && [ ! -e "$tmp/extracted/old" ] || fail=1
  python3 "$HERE/bin/config-plan.py" --entries-json "$entries" --default-vault main \
    --home "$home" --reader-port 19960 --editor-port-base 19961 --vault-slots 2 > "$plan" \
    || fail=1
  python3 "$HERE/bin/config-plan.py" --entries-json "$entries" --default-vault main \
    --home "$home" --reader-port 19960 --editor-port-base 19961 --vault-slots 2 \
    --format client > "$client" || fail=1
  python3 - "$plan" "$client" <<'PY' || fail=1
import json, sys
server=json.load(open(sys.argv[1])); client=json.load(open(sys.argv[2]))
assert server["router_container"] == "airlock-notes-router"
assert server["vaults"][0]["reader_container"] == "airlock-notes-reader-main"
assert server["vaults"][0]["editor_port"] == 19961
assert all("path" not in vault for vault in client["vaults"])
assert client["vaults"][0]["editor_path"] == "/notes/editor/main/"
PY
  mkdir -p "$out"
  : > "$tmp/silverbullet"; : > "$tmp/supervisor.py"
  python3 "$HERE/bin/render.py" --plan "$plan" --out "$out" \
    --unit "$out/editor.service" --fragment "$out/notes.conf" \
    --runtime-plan "$plan" --silverbullet "$tmp/silverbullet" \
    --supervisor "$tmp/supervisor.py" --uid "$(id -u)" --gid "$(id -g)" || fail=1
  [ "$(grep -Fc 'if ($owner_ok = 0) { return 403; }' "$out/notes.conf")" -eq 2 ] || fail=1
  grep -Fq 'listen 127.0.0.1:19960;' "$out/router.conf" || fail=1
  for temp_kind in client_body proxy fastcgi uwsgi scgi; do
    grep -Fq "${temp_kind}_temp_path /tmp/${temp_kind};" "$out/router.conf" || fail=1
  done
  grep -Fq 'SB_URL_PREFIX' "$HERE/bin/editor-supervisor.py" || fail=1
  grep -Fq -- '--pull=never' "$HERE/install.sh" || fail=1
  grep -Fq -- '--restart unless-stopped' "$HERE/install.sh" || fail=1
  grep -Fq -- '--env URI_PATH=/notes/' "$HERE/install.sh" || fail=1
  grep -Fq '/notes/_obs/edit-jump.js' "$out/router.conf" || fail=1
  grep -Fq '<script src="/notes/.js/perlite.js"></script>' "$out/router.conf" || fail=1
  grep -Fq "document.title = 'Notes';" "$out/edit-jump.js" || fail=1
  grep -Fq "'/assets/app-icons/notes.svg'" "$out/edit-jump.js" || fail=1
  grep -Fq "'/assets/app-icons/notes.png'" "$out/edit-jump.js" || fail=1
  if grep -R -E -n 'tailscale[[:space:]]+serve' "$HERE" >/dev/null; then fail=1; fi

  cat > "$tmp/fake-config.py" <<'PY'
import json, os, sys
if sys.argv[1:] == ["env", "notes"]:
    print("export AIRLOCK_NOTES_READER_PORT=19960")
    print("export AIRLOCK_NOTES_EDITOR_PORT_BASE=19961")
    print("export AIRLOCK_NOTES_VAULT_SLOTS=2")
    if os.environ.get("AIRLOCK_DRY_RUN") != "1":
        print("export AIRLOCK_CONTAINER_RECONCILE_MODE=" + os.environ.get("FAKE_RECONCILE_MODE", "fresh"))
        print("export AIRLOCK_CONTAINER_DAEMON_IDENTITY=docker:fake-engine")
        print("export AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001")
elif sys.argv[1:] == ["get", "apps.notes.vaults.default_vault"]:
    print("main")
elif sys.argv[1:] == ["get", "apps.notes.vaults.entries"]:
    print(json.dumps([{"id":"main","label":"Main","path":"$HOME/vault",
                       "home_file":os.environ.get("FAKE_HOME_FILE", "README"),
                       "writable":True}]))
elif sys.argv[1:] == ["container-admit", "notes"]:
    print("\t".join((os.environ.get("FAKE_RECONCILE_MODE", "fresh"),
                     "fake-runtime-nonce-0001", "docker:fake-engine")))
else:
    raise SystemExit(2)
PY
  AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$tmp/install-render" \
    AIRLOCK_INSTALL_NONCE=standalone-nonce-0001 HOME="$home" \
    bash "$HERE/install.sh" >/dev/null 2>&1 || fail=1
  [ -d "$tmp/install-render/opt/perlite-dry-perlite/notes" ] \
    && [ -d "$tmp/install-render/opt/perlite-dry-perlite/_obs" ] || fail=1
  grep -Fq "$tmp/install-render/runtime/runs/standalone-nonce-0001/server-plan.json" \
    "$tmp/install-render/units/airlock-notes-editor.service" || fail=1
  cmp -s "$HERE/reader/app.html" \
    "$tmp/install-render/runtime/runs/standalone-nonce-0001/obs/app.html" || fail=1

  fakebin="$tmp/fakebin"; mkdir -p "$fakebin"
  fake_state="$tmp/fake-docker-state.json"
  printf '[]\n' > "$fake_state"
  cat > "$fakebin/docker" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys

state_path=pathlib.Path(os.environ["DOCKER_STATE"])
log_path=pathlib.Path(os.environ["DOCKER_LOG"])
argv=sys.argv[1:]
objects=json.loads(state_path.read_text())

def save():
    state_path.write_text(json.dumps(objects, sort_keys=True))

def log():
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(argv) + "\n")

if argv == ["info"]:
    raise SystemExit(0)
if argv == ["info", "--format", "{{.ID}}"]:
    print(os.environ.get("FAKE_ENGINE_ID", "fake-engine"))
    raise SystemExit(0)
if argv[:2] == ["image", "inspect"]:
    if "--format" in argv:
        print("sha256:fake-perlite")
    raise SystemExit(0)
if argv and argv[0] == "ps":
    filters=[]
    for i, value in enumerate(argv[:-1]):
        if value == "--filter": filters.append(argv[i+1])
    for obj in objects:
        labels=obj["Config"]["Labels"]
        if all(not f.startswith("label=") or labels.get(f[6:].split("=",1)[0]) == f[6:].split("=",1)[1]
               for f in filters):
            print(obj["Id"])
    raise SystemExit(0)
if argv and argv[0] == "inspect":
    fmt=None
    ids=[]
    i=1
    while i < len(argv):
        if argv[i] == "--format": fmt=argv[i+1]; i += 2
        else: ids.append(argv[i]); i += 1
    selected=[obj for obj in objects if obj["Id"] in ids]
    if len(selected) != len(ids):
        missing=next(ident for ident in ids if not any(obj["Id"] == ident for obj in selected))
        print(f"Error: No such object: {missing}", file=sys.stderr)
        raise SystemExit(1)
    if fmt is not None:
        for obj in selected:
            labels=obj["Config"]["Labels"]
            print(obj["Id"], labels.get("io.airlock.package", ""),
                  labels.get("io.airlock.install-nonce", ""))
    else:
        print(json.dumps(selected))
    raise SystemExit(0)
if argv and argv[0] == "run":
    log()
    prior=sum(1 for line in log_path.read_text().splitlines()
              if line and json.loads(line)[0] == "run")
    if prior == int(os.environ.get("DOCKER_FAIL_RUN_AT", "0")):
        raise SystemExit(1)
    name=argv[argv.index("--name")+1]
    labels={}
    for i, value in enumerate(argv[:-1]):
        if value == "--label":
            key, label_value=argv[i+1].split("=", 1); labels[key]=label_value
    ident=f"{len(objects)+1:064x}"
    objects.append({
        "Id": ident, "Name": "/"+name, "State": {"Running": True},
        "Config": {"Labels": labels}, "Mounts": [],
        "HostConfig": {"NetworkMode": argv[argv.index("--network")+1]},
    })
    save(); print(ident)
    raise SystemExit(0)
if argv[:2] == ["rm", "-f"] and len(argv) == 3:
    log()
    ident=argv[2]
    if len(ident) != 64: raise SystemExit(2)
    remaining=[obj for obj in objects if obj["Id"] != ident]
    if len(remaining) == len(objects): raise SystemExit(1)
    objects[:]=remaining; save()
    raise SystemExit(0)
raise SystemExit(91)
PY
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 "$fakebin/docker" "$fakebin/curl" "$fakebin/systemctl"
  fake_opt="$home/.local/opt/airlock-notes"
  mkdir -p "$fake_opt/perlite-fake-perlite" "$fake_opt/silverbullet-2.10.0"
  echo sha256:fake-perlite > "$fake_opt/perlite-fake-perlite/.airlock-image-id"
  : > "$fake_opt/perlite-fake-perlite/index.php"
  cat > "$fake_opt/silverbullet-2.10.0/silverbullet" <<'SH'
#!/usr/bin/env bash
echo '2.10.0 test'
SH
  chmod 755 "$fake_opt/silverbullet-2.10.0/silverbullet"
  : > "$tmp/docker.log"
  DOCKER_LOG="$tmp/docker.log" PATH="$fakebin:$PATH" \
    DOCKER_STATE="$fake_state" \
    AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_CONFD="$tmp/live-confd" AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001 \
    HOME="$home" bash "$HERE/install.sh" >/dev/null 2>&1 || fail=1
  python3 - "$tmp/docker.log" <<'PY' || fail=1
import json, sys
runs=[json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert len(runs)==2, runs
for argv in runs:
    assert argv[0]=="run" and "--pull=never" in argv
    assert "--restart" in argv and argv[argv.index("--restart")+1]=="unless-stopped"
    assert "--label" in argv and "io.airlock.package=notes" in argv
    assert "io.airlock.install-nonce=fake-runtime-nonce-0001" in argv
    assert "--volume" not in argv and "-v" not in argv
    assert not any(value in {"network", "volume", "build", "pull"} for value in argv[:2])
    mounts=[argv[i+1] for i,value in enumerate(argv[:-1]) if value=="--mount"]
    assert any("dst=/var/www/perlite" in mount and "readonly" in mount for mount in mounts)
reader=next(argv for argv in runs if "--name" in argv and argv[argv.index("--name")+1].startswith("airlock-notes-reader-"))
router=next(argv for argv in runs if "--name" in argv and argv[argv.index("--name")+1]=="airlock-notes-router")
assert reader[reader.index("--network")+1]=="none"
assert "--read-only" in reader and "--user" in reader
assert router[router.index("--network")+1]=="host"
assert not any("/vaults/" in value for value in router)
PY

  python3 - "$fake_state" <<'PY' || fail=1
import json, re, sys
objects=json.load(open(sys.argv[1]))
assert {o["Name"] for o in objects} == {
    "/airlock-notes-reader-main", "/airlock-notes-router"}
assert len({o["Id"] for o in objects}) == 2
assert all(re.fullmatch(r"[0-9a-f]{64}", o["Id"]) for o in objects)
assert all(o["Config"]["Labels"] == {
    "io.airlock.package": "notes",
    "io.airlock.install-nonce": "fake-runtime-nonce-0001",
} for o in objects)
PY
  : > "$tmp/docker.log"
  DOCKER_LOG="$tmp/docker.log" DOCKER_STATE="$fake_state" PATH="$fakebin:$PATH" \
    FAKE_RECONCILE_MODE=reuse-required \
    AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_CONFD="$tmp/live-confd" AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001 \
    HOME="$home" bash "$HERE/install.sh" >/dev/null 2>&1 || fail=1
  [ ! -s "$tmp/docker.log" ] || fail=1

  # Same code digest + changed vault config is not an upgrade. D9 requires the
  # committed ids to survive such a reconcile, so the installer must refuse
  # before issuing any Docker mutation instead of recreating with the same
  # nonce and failing at ledger commit afterwards.
  : > "$tmp/docker.log"
  changed_err="$tmp/changed-plan.err"
  if DOCKER_LOG="$tmp/docker.log" DOCKER_STATE="$fake_state" PATH="$fakebin:$PATH" \
    FAKE_HOME_FILE=INDEX FAKE_RECONCILE_MODE=reuse-required \
    AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_CONFD="$tmp/live-confd" AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001 \
    HOME="$home" bash "$HERE/install.sh" >/dev/null 2>"$changed_err"; then
    fail=1
  fi
  grep -Fq 'remove the [apps.notes] subtree and run the normal installer once' \
    "$changed_err" || fail=1
  [ ! -s "$tmp/docker.log" ] || fail=1

  : > "$tmp/docker.log"
  identity_err="$tmp/identity.err"
  if DOCKER_LOG="$tmp/docker.log" DOCKER_STATE="$fake_state" PATH="$fakebin:$PATH" \
    FAKE_RECONCILE_MODE=reuse-required FAKE_ENGINE_ID=other-engine \
    AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_CONFD="$tmp/live-confd" AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001 \
    HOME="$home" bash "$HERE/install.sh" >/dev/null 2>"$identity_err"; then
    fail=1
  fi
  grep -Fq 'Docker daemon identity changed during Notes lifecycle' "$identity_err" || fail=1
  [ ! -s "$tmp/docker.log" ] || fail=1

  # A partial create must be rolled back by immutable full id, and success is
  # the runtime-observed absence of the exact two-label set rather than rm's rc.
  printf '[]\n' > "$fake_state"
  : > "$tmp/docker.log"
  rollback_err="$tmp/rollback.err"
  if DOCKER_LOG="$tmp/docker.log" DOCKER_STATE="$fake_state" DOCKER_FAIL_RUN_AT=2 \
    PATH="$fakebin:$PATH" \
    AIRLOCK_CONFIG_BIN="$tmp/fake-config.py" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$HERE" \
    AIRLOCK_CONFD="$tmp/live-confd" AIRLOCK_INSTALL_NONCE=fake-runtime-nonce-0001 \
    HOME="$home" bash "$HERE/install.sh" >/dev/null 2>"$rollback_err"; then
    fail=1
  fi
  python3 - "$fake_state" "$tmp/docker.log" <<'PY' || fail=1
import json, re, sys
assert json.load(open(sys.argv[1])) == []
calls=[json.loads(line) for line in open(sys.argv[2]) if line.strip()]
assert [call[0] for call in calls] == ["run", "run", "rm"], calls
assert calls[-1][:2] == ["rm", "-f"]
assert re.fullmatch(r"[0-9a-f]{64}", calls[-1][2])
PY

  cfg="$tmp/airlock.toml"
  cat > "$cfg" <<EOF
[auth]
provider = "tailscale"
owner = "owner@example.com"
[apps.hub]
[apps.notes]
reader_port = 19960
editor_port_base = 19961
vault_slots = 2
[apps.notes.vaults]
default_vault = "main"
entries = [{ id = "main", label = "Main", path = "\$HOME/vault", home_file = "README", writable = true }]
EOF
  manifest_out="$(AIRLOCK_CONFIG="$cfg" HOME="$home" python3 "$CFG" validate 2>&1)" \
    || { printf '  manifest: %s\n' "$manifest_out" >&2; fail=1; }
  if [ "$fail" = 0 ]; then
    echo "notes smoke: standalone ok (config, registry, same-origin gate, container arguments)"
  else
    echo "notes smoke: standalone FAILED" >&2
    return 1
  fi
}

live() {
  # shellcheck source=/dev/null
  . "$ROOT/install/lib.sh"
  airlock_load notes
  local reader_port="${AIRLOCK_NOTES_READER_PORT:?}" runtime plan expected ids inspect_json fail=0
  runtime="$HOME/.local/share/airlock/notes/current"
  plan="$runtime/server-plan.json"
  [ -f "$plan" ] || { echo "notes smoke: installed plan missing" >&2; return 1; }
  expected="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["vaults"])+1)' "$plan")"
  [ "$docker_ready" = 1 ] || { echo "notes smoke: Docker query UNKNOWN" >&2; return 1; }
  ids="$(docker_run ps -aq --filter label=io.airlock.package=notes)" \
    || { echo "notes smoke: package-label query UNKNOWN" >&2; return 1; }
  [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)" -eq "$expected" ] || fail=1
  local -a id_array
  mapfile -t id_array < <(printf '%s\n' "$ids" | sed '/^$/d')
  inspect_json="$(docker_run inspect "${id_array[@]}")" || return 1
  python3 - "$plan" "$inspect_json" <<'PY' || fail=1
import json, re, sys
plan=json.load(open(sys.argv[1])); objects=json.loads(sys.argv[2])
expected={"airlock-notes-router", *(v["reader_container"] for v in plan["vaults"])}
names={o["Name"].removeprefix("/") for o in objects}
assert names == expected, (names, expected)
nonces={o["Config"]["Labels"].get("io.airlock.install-nonce") for o in objects}
assert len(nonces)==1 and re.fullmatch(r"[A-Za-z0-9_-]{16,128}", next(iter(nonces)) or "")
for obj in objects:
    name=obj["Name"].removeprefix("/")
    assert obj["Config"]["Labels"].get("io.airlock.package")=="notes"
    assert obj["State"]["Running"] is True
    assert not any(m["Type"]=="volume" for m in obj["Mounts"])
    assert obj["HostConfig"]["NetworkMode"] == ("host" if name=="airlock-notes-router" else "none")
PY
  local owner other no_header hub hdr owner_id client_body default_vault
  code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
  [ "$(code "http://127.0.0.1:$reader_port/")" = 200 ] || fail=1
  client_body="$(curl -fsS --max-time 6 "http://127.0.0.1:$reader_port/_obs/vaults.json")" || fail=1
  [[ "$client_body" != *'"path"'* ]] || fail=1
  airlock_load hub
  hub="${AIRLOCK_HUB_NGINX_PORT:?}"; hdr="${AIRLOCK_IDENTITY_HEADER:-Tailscale-User-Login}"
  owner_id="${AIRLOCK_OWNER%%,*}"
  owner="$(code -H "$hdr: $owner_id" "http://127.0.0.1:$hub/notes/")"
  other="$(code -H "$hdr: nobody@example.com" "http://127.0.0.1:$hub/notes/")"
  no_header="$(code "http://127.0.0.1:$hub/notes/")"
  [ "$owner" = 200 ] || fail=1
  [ "$other" = 403 ] || fail=1
  [ "$no_header" = 403 ] || fail=1
  default_vault="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["default_vault"])' "$plan")"
  [ "$(code "http://127.0.0.1:$reader_port/notes/__airlock_missing__.png?vault=$default_vault")" = 404 ] || fail=1
  [ "$(code -H "$hdr: $owner_id" "http://127.0.0.1:$hub/notes/notes/__airlock_missing__.png?vault=$default_vault")" = 404 ] || fail=1
  [ "$(code -H "$hdr: nobody@example.com" "http://127.0.0.1:$hub/notes/notes/__airlock_missing__.png?vault=$default_vault")" = 403 ] || fail=1
  systemctl --user is-active --quiet airlock-notes-editor.service || fail=1
  while IFS=$'\t' read -r _ editor_port editor_path; do
    [ "$(code "http://127.0.0.1:$editor_port$editor_path")" = 200 ] || fail=1
    [ "$(code -H "$hdr: $owner_id" "http://127.0.0.1:$hub$editor_path")" = 200 ] || fail=1
    [ "$(code -H "$hdr: nobody@example.com" "http://127.0.0.1:$hub$editor_path")" = 403 ] || fail=1
    [ "$(code "http://127.0.0.1:$hub$editor_path")" = 403 ] || fail=1
  done < <(python3 -c 'import json,sys
for v in json.load(open(sys.argv[1]))["vaults"]:
  if v["writable"]: print("\t".join((v["id"],str(v["editor_port"]),v["editor_path"])))' "$plan")
  supervisor_pid="$(systemctl --user show airlock-notes-editor.service -p MainPID --value 2>/dev/null)"
  python3 - "$supervisor_pid" "$plan" <<'PY' || fail=1
import json, pathlib, sys
pid=sys.argv[1]; plan=json.load(open(sys.argv[2]))
expected={v["editor_path"].rstrip("/") for v in plan["vaults"] if v["writable"]}
children=pathlib.Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
seen=set()
for child in children:
    env=dict(item.split("=",1) for item in pathlib.Path(f"/proc/{child}/environ").read_bytes().split(b"\0") if b"=" in item)
    env={key.decode(): value.decode() for key,value in env.items()}
    assert env.get("SB_SHELL_BACKEND")=="off"
    assert env.get("SB_RUNTIME_API")=="0"
    seen.add(env.get("SB_URL_PREFIX"))
assert seen == expected, (seen, expected)
PY
  if [ "$fail" = 0 ]; then
    echo "notes smoke: live ok containers=$expected owner=200 collaborator=403 no-header=403"
  else
    echo "notes smoke: live FAILED containers=$expected owner=$owner collaborator=$other no-header=$no_header" >&2
    return 1
  fi
}

if [ -L "$HOME/.local/share/airlock/notes/current" ]; then
  live
elif AIRLOCK_CONFIG_BIN="$CFG" "$CFG" get apps.notes.vaults.entries >/dev/null 2>&1; then
  live
else
  standalone
fi
