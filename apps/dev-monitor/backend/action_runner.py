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

plan_file JSON: {"cwd": "...", "skill":"..."|"prompt":"..."|"exec":["prog","arg"], "explain": "..."}
  - exec = execute the program directly (does not go through claude, argv elements passed as-is —
    zero shell parsing). exec[0] = absolute path.
    In exec mode the process actually dies when it completes, so no turn marker is needed.
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


def build_argv(plan, settings_file=None):
    """plan → claude argv (element-by-element — no shell parsing).

    permission follows the **owner's normal settings exactly** (no separate mode is forced and no
    re-approval is added). What runs is the owner's own work, approved after the owner (or company)
    reviewed the preview and clicked — writing a note to the spool already requires server write
    access, and anyone with that access could simply open claude directly, so an extra gate on this
    path has no practical benefit. The gate is 'owner access + review the preview and click'.

    Keep only the `--` (end-of-options marker) before the prompt/skill — even if a prompt starts
    with `-`, it is treated as input rather than an option, preventing misparsing (frictionless argv
    correctness). Everything after `--` is positional.
    """
    exec_argv = plan.get('exec')
    if exec_argv:
        return list(exec_argv)                      # direct executable — no claude or '--', argv as-is (zero shell parsing)
    argv = ['claude']
    if settings_file:
        argv += ['--settings', settings_file]       # turn-end marker via Stop hook (merged **in addition** to owner's settings)
    argv.append('--')                               # '--' = end of options (only prevents prompt misparsing)
    skill = plan.get('skill')
    if skill:
        arg = '/' + skill
        if plan.get('args'):
            arg += ' ' + plan['args']
        argv.append(arg)                            # claude's first input = /skill (one argv element)
    else:
        argv.append(plan['prompt'])                 # claude's first input = the original prompt
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
        settings_file = None
        if not plan.get('exec'):      # claude path only — exec really dies when it finishes
            try:
                settings_file = write_turnend_settings(sentinel_dir, run_id)
            except OSError as e:      # continue even if the hook cannot be installed (old behavior = judge by process exit)
                sys.stderr.write('[action_runner] failed to install turn-end hook (completion will be determined when the window closes): %s\n' % e)
        argv = build_argv(plan, settings_file)
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
        if plan.get('explain'):
            print('   reason   : %s' % plan['explain'])
        print('─' * 56)
        sys.stdout.flush()
        env = runtime_env()                         # add ~/.local/bin to PATH (resolve claude)
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
