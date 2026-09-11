#!/usr/bin/env python3
"""Run a message prompt as argv in a tmux pane.

Messages use --message ROOT PROMPT AGENT_JSON and create no plan or sentinel.
The three-argument executable runner remains for updates/harness, whose existing
plan and completion-file contract is independent of message execution.
"""
import json
import os
import shutil
import subprocess
import sys


def write_sentinel(sentinel_dir, run_id, exit_code):
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

AGENT_SELECT_TIMEOUT = 15

AGENT_FALLBACK = {'provider': 'claude', 'command': 'claude', 'binary': None, 'reason': 'no platform agent key in this plan'}

AGENT_SPELLING = {'claude': {'command': 'claude'}, 'codex': {'command': 'codex'}}

def _agent_fallback(why):
    sys.stderr.write('[action_runner] %s — running %s\n' % (why, AGENT_FALLBACK['command']))
    return dict(AGENT_FALLBACK)

def resolve_agent(spec):
    spec = spec if isinstance(spec, dict) else {}
    preference = str(spec.get('provider') or '').strip()
    select_bin = str(spec.get('select_bin') or '').strip()
    if not preference and (not select_bin):
        return dict(AGENT_FALLBACK)
    if not preference or not select_bin:
        return _agent_fallback('the plan carries %s but not %s' % ('an agent provider' if preference else 'an agent selector', 'a selector' if preference else 'a provider'))
    try:
        proc = subprocess.run([sys.executable, select_bin, 'select', '--json', '--prefer', preference], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=AGENT_SELECT_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return _agent_fallback('agent selection failed (%s: %s)' % (select_bin, e))
    if proc.returncode != 0:
        return _agent_fallback('agent selection exited %d (%s)' % (proc.returncode, proc.stderr.decode('utf-8', 'replace').strip()))
    try:
        answer = json.loads(proc.stdout.decode('utf-8'))
    except (UnicodeDecodeError, ValueError) as e:
        return _agent_fallback('agent selection returned no usable JSON (%s)' % e)
    if not isinstance(answer, dict) or type(answer.get('schema_version')) is not int or answer['schema_version'] != 1:
        return _agent_fallback('agent selection spoke an unknown schema')
    provider = answer.get('provider')
    if provider is None:
        raise FileNotFoundError(answer.get('reason') or 'no agent CLI is available')
    if provider not in AGENT_SPELLING:
        return _agent_fallback('agent %r has no argv form in this runner' % (provider,))
    spelling = AGENT_SPELLING[provider]
    binary = answer.get('binary')
    if binary is not None and (not _usable_binary(binary)):
        sys.stderr.write('[action_runner] agent selection named %r, which is not an executable file — looking for %s on PATH instead\n' % (binary, spelling['command']))
        binary = None
    return {'provider': provider, 'command': spelling['command'], 'binary': binary, 'reason': str(answer.get('reason') or '')}

def _usable_binary(path):
    return isinstance(path, str) and os.path.isabs(path) and os.path.isfile(path) and os.access(path, os.X_OK)

def runtime_env():
    env = dict(os.environ)
    parts = [p for p in env.get('PATH', '').split(os.pathsep) if p]
    userbin = os.path.join(os.path.expanduser('~'), '.local', 'bin')
    if userbin not in parts:
        parts.insert(0, userbin)
    env['PATH'] = os.pathsep.join(parts)
    return env

def resolve_exe(argv, env):
    exe = shutil.which(argv[0], path=env['PATH'])
    if not exe:
        raise FileNotFoundError('%s (PATH=%s)' % (argv[0], env['PATH']))
    return exe

def resolve_cwd_under_root(cwd, cwd_root):
    os.chdir(cwd)
    real = os.path.realpath(os.getcwd())
    if cwd_root:
        rroot = os.path.realpath(os.path.expanduser(cwd_root))
        if real != rroot and (not real.startswith(rroot + os.sep)):
            raise ValueError('cwd escaped the allowed root at execution time: %s' % real)
    return real

def build_argv(plan, agent=None):
    agent = agent or AGENT_FALLBACK
    argv = [agent.get('binary') or agent['command']]
    if agent['provider'] == 'codex':
        argv.append('exec')
    return argv + ['--', plan['prompt']]


def main():
    message = len(sys.argv) == 5 and sys.argv[1] == '--message'
    if not message and len(sys.argv) != 4:
        sys.exit('usage: action_runner.py --message ROOT PROMPT AGENT_JSON | RUN_ID PLAN SENTINEL_DIR')
    rc = 1
    try:
        if message:
            root, prompt, raw_agent = sys.argv[2:]
            resolve_cwd_under_root(os.getcwd(), root)
            argv = build_argv({'prompt': prompt}, json.loads(raw_agent))
        else:
            # Updates/harness still own their plans, completion records and windows.
            with open(sys.argv[2]) as stream:
                plan = json.load(stream)
            resolve_cwd_under_root(plan['cwd'], plan.get('cwd_root'))
            argv = plan['exec']
        env = runtime_env()
        argv[0] = resolve_exe(argv, env)
        rc = subprocess.call(argv, env=env)
    except FileNotFoundError as error:
        sys.stderr.write('[action_runner] executable not found: %s\n' % error)
        rc = 127
    except Exception as error:
        sys.stderr.write('[action_runner] error: %s\n' % error)
    finally:
        if not message:
            write_sentinel(sys.argv[3], sys.argv[1], rc)
    print('\nExited (rc=%d). Continue working or close this window.' % rc, flush=True)
    try:
        os.execvp('bash', ['bash', '-l'])
    except OSError:
        sys.exit(rc)


if __name__ == '__main__':
    main()
