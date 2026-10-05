#!/usr/bin/python3
"""Maintained legacy Git updater. Installation never enables scheduling."""
import argparse
import configparser
import fcntl
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import urllib.parse
import urllib.request

MODE = 'pull'
NAME = 'git_auto_' + MODE

def command(args, capture=False, timeout=180):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    return subprocess.run(args, check=True, text=True, env=env, cwd='/',
                          stdout=subprocess.PIPE if capture else None, timeout=timeout)

def git(path, *args, user=None, hooks=False):
    cmd = ['git']
    if not hooks:
        cmd += ['-c', 'core.hooksPath=/dev/null']
    cmd += ['-C', str(path), *args]
    if user and pwd.getpwnam(user).pw_uid != os.geteuid():
        cmd = ['sudo', '-n', '-H', '-u', user, '--', *cmd]
    return command(cmd, capture=True).stdout.strip()

def update(path, branch, user=None, hooks=False):
    git(path, 'check-ref-format', '--branch', branch, user=user)
    if branch.startswith('-'):
        raise ValueError('Invalid branch')
    current = git(path, 'symbolic-ref', '--quiet', '--short', 'HEAD', user=user)
    if current != branch:
        raise ValueError(f'Wrong branch: {current}; expected {branch}')
    if git(path, 'status', '--porcelain', '--untracked-files=all', user=user):
        raise ValueError('Working tree is not clean')
    git(path, 'fetch', '--no-tags', 'origin',
        f'+refs/heads/{branch}:refs/remotes/origin/{branch}', user=user)
    before = git(path, 'rev-parse', 'HEAD', user=user)
    target = git(path, 'rev-parse', f'refs/remotes/origin/{branch}', user=user)
    if before == target:
        return 'UNCHANGED'
    git(path, 'merge-base', '--is-ancestor', before, target, user=user)
    # Recheck after fetch. The updater lock serializes this tool, not manual Git use.
    if git(path, 'status', '--porcelain', '--untracked-files=all', user=user):
        raise ValueError('Working tree changed during fetch')
    git(path, 'merge', '--ff-only', target, user=user, hooks=hooks)
    if git(path, 'rev-parse', 'HEAD', user=user) != target:
        raise ValueError('Unexpected HEAD after merge')
    return 'UPDATED'

def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value

def read_config(path):
    c = configparser.ConfigParser(interpolation=None, strict=True)
    c.optionxform = str
    with open(path) as f:
        c.read_file(f)
    settings = {k.lstrip('$'): unquote(v) for k,v in c.items('var')}
    projects = dict(c.items('projects')) if c.has_section('projects') else {}
    result = []
    import re
    ids = set()
    for key in projects:
        match = re.fullmatch(r'project([0-9]+)_(path|branch)', key)
        if not match:
            raise ValueError('Unknown project key: ' + key)
        ids.add(int(match[1]))
    for i in sorted(ids):
        p = unquote(projects[f'project{i}_path'])
        b = unquote(projects[f'project{i}_branch'])
        if not os.path.isabs(p) or not b:
            raise ValueError('Absolute project path and branch are required')
        result.append((p,b))
    return settings, result

def notify(settings, message):
    failures = []
    for channel in ('TELEGRAM', 'SIGNAL', 'XMPP'):
        if settings.get('SEND_' + channel, '0') != '1':
            continue
        try:
            if channel == 'TELEGRAM':
                data = urllib.parse.urlencode({'chat_id': settings['CHAT_ID'], 'text': message}).encode()
                url = 'https://api.telegram.org/bot' + settings['BOT_TOKEN'] + '/sendMessage'
                with urllib.request.urlopen(url, data=data, timeout=20) as response:
                    if not json.load(response).get('ok'):
                        raise ValueError('Telegram rejected message')
            elif channel == 'SIGNAL':
                command(['signal-cli', '-a', settings['SIGNAL_SENDER'], 'send',
                         '-m', message, settings['SIGNAL_RECIPIENT']], timeout=30)
            else:
                subprocess.run(['sendxmpp', '-t', settings['XMPP_RECIPIENT']],
                               input=message, text=True, check=True, timeout=30, cwd='/')
        except Exception:
            # Do not print exception arguments: URLs/commands may contain credentials.
            failures.append(channel)
    if failures:
        print('NOTIFICATION_FAILED: ' + ','.join(failures), file=sys.stderr)
    return not failures

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config', default='/etc/' + NAME + '.conf')
    p.add_argument('--lock', default='/run/lock/' + NAME + '.lock')
    p.add_argument('--msg', '--telegram', nargs='+', help='Send through configured notification channels only')
    args = p.parse_args()
    fd = os.open(args.lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('SKIPPED: updater already running')
            return 0
        failed = False
        if MODE == 'fetch':
            if args.msg:
                raise ValueError('Notifications are supported by git_auto_pull only')
            for line in Path(args.config).read_text().splitlines():
                path = line.strip()
                if not path or path.startswith('#'):
                    continue
                try:
                    if not os.path.isabs(path):
                        raise ValueError('Absolute path required')
                    git(path, 'fetch', '--prune', '--all', '--tags')
                    print('FETCH_OK: ' + path, flush=True)
                except Exception as error:
                    print('FETCH_FAILED: ' + path + ': ' + type(error).__name__, file=sys.stderr)
                    failed = True
        else:
            settings, projects = read_config(args.config)
            if args.msg:
                return 0 if notify(settings, ' '.join(args.msg)) else 1
            if all(os.environ.get(k) for k in ('PAM_USER','PAM_SERVICE','PAM_TYPE')):
                message = 'PAM: ' + ' '.join(os.environ[k] for k in ('PAM_TYPE','PAM_USER','PAM_SERVICE'))
                return 0 if notify(settings, message) else 1
            user = settings.get('GIT_USER', settings.get('USER', ''))
            if not user:
                raise ValueError('Set GIT_USER (legacy USER is also accepted)')
            pwd.getpwnam(user)
            for path, branch in projects:
                try:
                    result = update(path, branch, user, settings.get('RUN_HOOKS', '0') == '1')
                    print(result + ': ' + path, flush=True)
                    if result == 'UPDATED' and not notify(settings, result + ': ' + path):
                        failed = True
                except Exception as error:
                    print('UPDATE_FAILED: ' + path + ': ' + type(error).__name__, file=sys.stderr)
                    notify(settings, 'UPDATE_FAILED: ' + path)
                    failed = True
        return int(failed)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(NAME + ': ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
