#!/usr/bin/env python3
"""action_runner — the runner operating inside a tmux pane.

usage: action_runner.py <run_id> <plan_file> <sentinel_dir>

Contract (why this way):
  - Prompts/skills are read from **plan_file (JSON)** and passed to claude as **argv elements**.
    → They never pass through a tmux command line or shell, so shell metacharacters in a prompt
      cannot cause injection.
  - claude runs with the owner's normal settings (no separate permission mode is forced). What
    runs is the owner's own work, which they approved by reviewing the preview and clicking.
    Gate = owner access + click.
  - On exit, it leaves a sentinel using **fsync + rename** (atomic) → the backend watcher decides
    done/failed. After leaving the sentinel, it execs into a login shell → the pane stays alive so
    the owner can inspect the result and do follow-up work. The backend retains a completed Claude
    pane for 24 hours after turn end, unless the owner explicitly chooses Keep, then reclaims the
    pane and this run's sentinel files together.
  - 🔴 **claude does not exit even when the work is done** (interactive REPL — it waits at the
    prompt when a turn ends). If we wait only for "process exit", the run stays `running` forever
    and the card remains locked (observed 2026-07-30: still `running` 43 minutes after completion).
    **Turn end = work complete** must therefore be signaled separately — claude's `Stop` hook
    (`--settings` = **additional** merge into the owner's settings) writes a marker, and the
    watcher thread writes the sentinel at that point. The window stays alive (preserving follow-up
    work and output).

plan_file JSON: {"cwd": "...", "skill":"..."|"prompt":"..."|"exec":["prog","arg"], "explain": "...",
                 "agent": {"provider": "auto|claude|codex", "select_bin": "/…/bin/airlock-agent"}}
  - exec = execute the program directly (does not go through an agent CLI, argv elements passed
    as-is — zero shell parsing). exec[0] = absolute path.
    In exec mode the process actually dies when it completes, so no turn marker is needed.
  - agent = the platform's `[agent].provider` key plus the platform CLI that resolves it. It
    arrives in the PLAN rather than the environment because it cannot arrive any other way: a
    tmux window inherits the tmux SERVER's environment (whatever started the server, often a
    login shell from hours earlier), not the environment of the backend that called
    `tmux new-window`. Measured 2026-09-01 — server started with FOO=first, new-window called
    with FOO=second, the window sees FOO=first. This is the same mechanism as the rc=127
    incident recorded under runtime_env() below.
    Absent or empty = claude, exactly as before the key existed. A box that never set it must
    keep running what it was running.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time

def write_sentinel(sentinel_dir, run_id, exit_code):
    """Atomic sentinel: tmp write + fsync → rename(<run_id>.done)."""
    try:
        os.makedirs(sentinel_dir, exist_ok=True)
        tmp = os.path.join(sentinel_dir, run_id + '.tmp')
        final = os.path.join(sentinel_dir, run_id + '.done')
        with open(tmp, 'w') as f:
            json.dump({'run_id': run_id, 'exit_code': exit_code}, f)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, final)
    except OSError as e:
        sys.stderr.write('[action_runner] sentinel write failed: %s\n' % e)


# The selector reads two small files and scans a handful of directories. If it has not answered
# in this long it is wedged, and waiting longer only delays a run the owner already approved.
AGENT_SELECT_TIMEOUT = 15

# What runs when the plan says nothing about an agent. Not a preference — the value this
# file had written into its argv before `[agent].provider` existed. Compatibility is the
# whole reason it is spelled out here instead of being read from the platform.
AGENT_FALLBACK = {'provider': 'claude', 'command': 'claude', 'binary': None,
                  'reason': 'no platform agent key in this plan', 'turnend_hook': True}

# The providers this runner can spell an argv for, and what it spells. The COMMAND NAME is
# read from here and never from the selector's answer: the runner has to know each provider
# it accepts anyway (to know whether to install a turn-end hook), so taking the name from its
# own table costs nothing and removes a way for a wrong answer to name a different program.
# turnend_hook: only claude needs it. `claude -p` is a REPL that waits at the prompt when a
# turn ends (see the module docstring), while `codex exec` exits when the work is done — so
# for codex the process exit IS the completion signal, the same way exec mode already works.
AGENT_SPELLING = {
    'claude': {'command': 'claude', 'turnend_hook': True},
    'codex': {'command': 'codex', 'turnend_hook': False},
}


def _agent_fallback(why):
    """AGENT_FALLBACK, after saying on stderr why we are not doing what was configured.

    Falling back to claude rather than refusing to run is deliberate — a broken selector must
    not take away a capability the box had yesterday. Doing it QUIETLY is not: the pane stays
    open after the run, so this line is where a person who wonders why claude started reads it.
    """
    sys.stderr.write('[action_runner] %s — running %s\n' % (why, AGENT_FALLBACK['command']))
    return dict(AGENT_FALLBACK)


def resolve_agent(spec):
    """plan['agent'] → {provider, command, binary, reason, turnend_hook}.

    Silence is correct in exactly one case: the plan names NEITHER a provider nor a selector.
    That is a box that never set `[agent].provider`, which is the ordinary state and not an
    event. Everything else that ends up on claude says so.

    The one case that does not fall back at all is a selector that answered "nothing is
    installed". That is an answer, and honouring it gives the owner its sentence instead of a
    bare rc=127.
    """
    spec = spec if isinstance(spec, dict) else {}
    preference = str(spec.get('provider') or '').strip()
    select_bin = str(spec.get('select_bin') or '').strip()
    if not preference and not select_bin:
        return dict(AGENT_FALLBACK)         # the unconfigured box — not an event, so no line
    if not preference or not select_bin:
        # HALF configured. The likeliest cause is a unit rendered before this feature and not
        # re-rendered since, and the consequence is a box whose airlock.toml says codex quietly
        # running claude. That is exactly the failure this whole change exists to remove.
        return _agent_fallback(
            'the plan carries %s but not %s'
            % ('an agent provider' if preference else 'an agent selector',
               'a selector' if preference else 'a provider'))
    try:
        # Through the interpreter, not as an executable: bin/airlock-agent is mode 100644 on
        # purpose (a new executable under bin/ needs an explicit cutline catalog entry, and
        # this tool does not need one). install/lib.sh spawns bin/airlock-config the same way.
        proc = subprocess.run([sys.executable, select_bin, 'select', '--json',
                               '--prefer', preference],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=AGENT_SELECT_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return _agent_fallback('agent selection failed (%s: %s)' % (select_bin, e))
    if proc.returncode != 0:
        return _agent_fallback('agent selection exited %d (%s)'
                               % (proc.returncode,
                                  proc.stderr.decode('utf-8', 'replace').strip()))
    try:
        answer = json.loads(proc.stdout.decode('utf-8'))
    except (UnicodeDecodeError, ValueError) as e:
        return _agent_fallback('agent selection returned no usable JSON (%s)' % e)
    # `is int` and not `== 1`: in Python `True == 1`, so a selector answering
    # `"schema_version": true` would otherwise pass a version check as version 1.
    if (not isinstance(answer, dict)
            or type(answer.get('schema_version')) is not int
            or answer['schema_version'] != 1):
        return _agent_fallback('agent selection spoke an unknown schema')
    provider = answer.get('provider')
    if provider is None:
        raise FileNotFoundError(answer.get('reason') or 'no agent CLI is available')
    if provider not in AGENT_SPELLING:
        # The platform grew a CLI this runner does not know how to spell an argv for. Guessing
        # would produce a command line nobody wrote; say so and run what we do know.
        return _agent_fallback('agent %r has no argv form in this runner' % (provider,))
    spelling = AGENT_SPELLING[provider]
    binary = answer.get('binary')
    if binary is not None and not _usable_binary(binary):
        # Keep the provider, drop the path. Falling back to claude here would be worse than
        # useless on a box configured for codex — it would run the wrong CLI over a stale
        # path. Without the path, resolve_exe searches by name and, if that fails too, says
        # exactly what it looked for and where.
        sys.stderr.write('[action_runner] agent selection named %r, which is not an executable '
                         'file — looking for %s on PATH instead\n' % (binary, spelling['command']))
        binary = None
    return {'provider': provider, 'command': spelling['command'], 'binary': binary,
            'reason': str(answer.get('reason') or ''),
            'turnend_hook': spelling['turnend_hook']}


def _usable_binary(path):
    """Absolute, existing, executable. Deliberately NOT "its basename is the command name":
    a native claude install lives at `~/.local/share/claude/versions/<version>`, where the
    file is named after the version, and bin_discovery returns exactly that path.

    What this check is and is not. It catches a selector that answers with a stale or
    misspelled path — the realistic failure. It does not make the selector's answer
    untrusted input: the selector is named by the unit file, so anything able to forge its
    answer can already rewrite the unit, the plan and this runner. That is the same trust
    the runner already places in `plan['cwd']` and in its own path.
    """
    return (isinstance(path, str) and os.path.isabs(path)
            and os.path.isfile(path) and os.access(path, os.X_OK))


def build_argv(plan, settings_file=None, agent=None):
    """plan → agent-CLI argv (element-by-element — no shell parsing).

    permission follows the **owner's normal settings exactly** (no separate mode is forced and no
    re-approval is added). What runs is the owner's own work, approved after the owner (or company)
    reviewed the preview and clicked — writing a note to the spool already requires server write
    access, and anyone with that access could simply open claude directly, so an extra gate on this
    path has no practical benefit. The gate is 'owner access + review the preview and click'.

    Keep only the `--` (end-of-options marker) before the prompt/skill — even if a prompt starts
    with `-`, it is treated as input rather than an option, preventing misparsing (frictionless argv
    correctness). Everything after `--` is positional. That holds for every provider: the first
    input is one argv element and it is positional, so which CLI runs never changes whether a
    prompt can reach an option slot.

    🔴 No provider gets a `--model`, and none gets a sandbox or permission flag this file invents.
    Owner decision 5: the model is the CLI's to pick. The permission posture is the owner's own
    configuration for that CLI, the same way the claude path has always taken the owner's
    settings — a flag here would quietly override what the owner set for their own tool.
    """
    exec_argv = plan.get('exec')
    if exec_argv:
        return list(exec_argv)                      # direct executable — no agent CLI or '--', argv as-is (zero shell parsing)
    agent = agent or AGENT_FALLBACK
    argv = [agent.get('binary') or agent['command']]
    if agent['provider'] == 'codex':
        argv.append('exec')                         # codex's non-interactive verb; it exits when the work is done
    elif settings_file:
        argv += ['--settings', settings_file]       # turn-end marker via Stop hook (merged **in addition** to owner's settings)
    argv.append('--')                               # '--' = end of options (only prevents prompt misparsing)
    skill = plan.get('skill')
    if skill:
        arg = '/' + skill
        if plan.get('args'):
            arg += ' ' + plan['args']
        argv.append(arg)                            # the CLI's first input = /skill (one argv element)
    else:
        argv.append(plan['prompt'])                 # the CLI's first input = the original prompt
    return argv


def runtime_env():
    """Execution env — add `~/.local/bin` to PATH.

    🔴 Why this is needed (2026-07-30, observed rc=127): this runner starts directly in a tmux
    window **without going through a login shell**, and the tmux server's global env retains the PATH
    from the `systemd --user` process that started dev-monitor (`/usr/local/sbin:…:/snap/bin`) — it
    does not contain `~/.local/bin`. But `claude` exists only at `~/.local/bin/claude`, so every
    approved run died with FileNotFoundError → 127 (both approval clicks). Explicitly adding it at
    this layer, which does not depend on shell rc files, is the fundamental fix.
    """
    env = dict(os.environ)
    parts = [p for p in env.get('PATH', '').split(os.pathsep) if p]
    userbin = os.path.join(os.path.expanduser('~'), '.local', 'bin')
    if userbin not in parts:
        parts.insert(0, userbin)
    env['PATH'] = os.pathsep.join(parts)
    return env


def resolve_exe(argv, env):
    """Resolve argv[0] to the actual path. If missing, say what was sought and where, then raise FileNotFoundError."""
    exe = shutil.which(argv[0], path=env['PATH'])
    if not exe:
        raise FileNotFoundError('%s (PATH=%s)' % (argv[0], env['PATH']))
    return exe


def turnend_paths(sentinel_dir, run_id):
    """(marker, settings file) — keep both inside sentinel_dir (0700, owner-only)."""
    return (os.path.join(sentinel_dir, run_id + '.turnend'),
            os.path.join(sentinel_dir, run_id + '.settings.json'))


RUN_SENTINEL_SUFFIXES = ('.done', '.tmp', '.turnend', '.settings.json', '.settings.json.tmp')


def run_sentinel_paths(sentinel_dir, run_id):
    """Return every temporary or completion file owned by one run."""
    return tuple(os.path.join(sentinel_dir, run_id + suffix)
                 for suffix in RUN_SENTINEL_SUFFIXES)


def cleanup_run_sentinels(sentinel_dir, run_id):
    """Remove one run's sentinel files and return any removal failures.

    This is deliberately scoped to the exact run id. The lifecycle reaper calls it after
    killing the run's tmux window so a forced close cannot leave the turn-end settings file
    behind forever.
    """
    failures = []
    for path in run_sentinel_paths(sentinel_dir, run_id):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            failures.append((path, exc))
    return failures


def write_turnend_settings(sentinel_dir, run_id):
    """Write an **additional** settings file that makes claude's `Stop` hook (turn end) touch the marker. Return: path.

    `--settings` does not replace the owner's settings; it **additionally merges** them (claude
    --help: "load additional settings from"), so the normal permission and hook settings remain
    in effect. The marker path lives in this file rather than argv, so a shell-mediated string path
    cannot mix with the prompt.
    """
    marker, settings_file = turnend_paths(sentinel_dir, run_id)
    os.makedirs(sentinel_dir, exist_ok=True)
    payload = {'hooks': {'Stop': [{'hooks': [
        {'type': 'command',
         # Create only the marker (no contents) — the hook runs every user turn, so this is the cheapest form with no side effects.
         'command': "touch -- '%s'" % marker.replace("'", "'\\''"),
         'timeout': 5}]}]}}
    tmp = settings_file + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(payload, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, settings_file)
    return settings_file


def watch_turnend(sentinel_dir, run_id, on_complete, stop_event, poll=1.0):
    """Call on_complete() **once** when the marker appears, then exit. claude remains alive.

    Why poll — the hook creates the file in the claude process while the runner is blocked waiting
    for that process. The frequency is low (one second), so inotify is not worth a dependency; zero
    dependencies is part of this file's contract.
    """
    marker, _ = turnend_paths(sentinel_dir, run_id)
    while not stop_event.is_set():
        if os.path.exists(marker):
            try:
                os.remove(marker)
            except OSError:
                pass
            on_complete()
            return True
        stop_event.wait(poll)
    return False


def cleanup_turnend(sentinel_dir, run_id, sweep_older_than=7 * 86400):
    """Clean up leftover marker/settings files — harmless if left behind, but sentinel_dir should not become a trash can.

    If the window is forcibly closed (kill-session), this cleanup never runs and another run's files
    remain → sweep old `*.settings.json` files too to prevent unbounded growth (my own cleanup alone
    cannot close that gap).
    """
    for p in turnend_paths(sentinel_dir, run_id):
        try:
            os.remove(p)
        except OSError:
            pass
    now = time.time()
    try:
        names = os.listdir(sentinel_dir)
    except OSError:
        return
    for name in names:
        if not name.endswith('.settings.json'):
            continue
        p = os.path.join(sentinel_dir, name)
        try:
            if now - os.path.getmtime(p) > sweep_older_than:
                os.remove(p)
        except OSError:
            pass


def resolve_cwd_under_root(cwd, cwd_root):
    """Recheck that the actual location after chdir is under root (act-then-verify) — protects against a symlink swap after approval.
    Return: real path. Raises ValueError if it escaped.
    """
    os.chdir(cwd)
    real = os.path.realpath(os.getcwd())            # actual path resolved after chdir
    if cwd_root:
        rroot = os.path.realpath(os.path.expanduser(cwd_root))
        if real != rroot and not real.startswith(rroot + os.sep):
            raise ValueError('cwd escaped the allowed root at execution time: %s' % real)
    return real


def main():
    if len(sys.argv) != 4:
        sys.stderr.write('usage: action_runner.py <run_id> <plan_file> <sentinel_dir>\n')
        sys.exit(2)
    run_id, plan_file, sentinel_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    rc = 1
    reported = threading.Event()      # whether completion was already reported by turn end
    stop_watch = threading.Event()
    try:
        with open(plan_file) as f:
            plan = json.load(f)
        cwd = plan['cwd']
        if not os.path.isdir(cwd):
            raise ValueError('cwd disappeared: %s' % cwd)
        agent = resolve_agent(plan.get('agent')) if not plan.get('exec') else AGENT_FALLBACK
        settings_file = None
        # The hook is claude-only: exec and codex both really die when they finish, and for them
        # completion is the process exit. Installing a Stop hook they never fire would leave the
        # watcher waiting for a marker that cannot arrive.
        if not plan.get('exec') and agent['turnend_hook']:
            try:
                settings_file = write_turnend_settings(sentinel_dir, run_id)
            except OSError as e:      # continue even if the hook cannot be installed (old behavior = judge by process exit)
                sys.stderr.write('[action_runner] failed to install turn-end hook (completion will be determined when the window closes): %s\n' % e)
        argv = build_argv(plan, settings_file, agent)
        cwd = resolve_cwd_under_root(cwd, plan.get('cwd_root'))   # chdir + root recheck (#6 TOCTOU)
        print('▶ dev-monitor execution  [%s]' % run_id)
        print('   cwd    : %s' % cwd)
        if plan.get('exec'):
            run_label = 'Executable: ' + ' '.join(plan['exec'])
        elif plan.get('skill'):
            run_label = '/' + plan['skill']
        else:
            run_label = 'Prompt'
        print('   execution   : %s' % run_label)
        if not plan.get('exec'):
            # WHICH CLI is running, printed next to what it is running. The owner configured a
            # box-wide default they may not remember, `auto` can change answer between two runs
            # of the same card, and the pane is the only place either fact is visible.
            print('   agent   : %s%s' % (agent['command'],
                                         '  (%s)' % agent['reason'] if agent['reason'] else ''))
        if plan.get('explain'):
            print('   reason   : %s' % plan['explain'])
        print('─' * 56)
        sys.stdout.flush()
        env = runtime_env()                         # add ~/.local/bin to PATH (resolve the agent CLI)
        argv[0] = resolve_exe(argv, env)            # if missing, record what and where, then return 127
        if settings_file:
            # Report completion the moment the turn ends — claude and the window remain alive.
            def _on_turnend():
                write_sentinel(sentinel_dir, run_id, 0)
                reported.set()
                print('\n─ Reported completion (card closed). This window is still available. ─',
                      flush=True)
            threading.Thread(target=watch_turnend,
                             args=(sentinel_dir, run_id, _on_turnend, stop_watch),
                             daemon=True, name='turnend').start()
        rc = subprocess.call(argv, env=env)         # argv-only → no shell injection
    except FileNotFoundError as e:
        sys.stderr.write('[action_runner] executable not found: %s\n' % e)
        rc = 127
    except Exception as e:                           # noqa: BLE001 — any failure still leaves a sentinel
        sys.stderr.write('[action_runner] error: %s\n' % e)
        rc = 1
    finally:
        stop_watch.set()
        # If turn end already reported done, do not overwrite it with the process rc — a person
        # closing the window with Ctrl-C or exit is NOT the work failing. (The backend will not
        # re-transition a terminal state either, but we avoid creating a contradictory signal in
        # the first place.)
        if not reported.is_set():
            write_sentinel(sentinel_dir, run_id, rc)
        cleanup_turnend(sentinel_dir, run_id)
    # Preserve the result and allow follow-up work — switch the pane to a login shell (closing it ends the session).
    print('\n─ Exited (rc=%d). Continue working or close this window. ─' % rc)
    sys.stdout.flush()
    try:
        os.execvp('bash', ['bash', '-l'])
    except OSError:
        sys.exit(rc)


if __name__ == '__main__':
    main()
