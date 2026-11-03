# SPDX-License-Identifier: MIT
import csv
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
from common import APPLICATIONS, ROOTS, load, name

def retained():
    result = subprocess.check_output(['rpm-ostree', 'status', '--json'], text=True)
    roots = [APPLICATIONS]
    for deployment in json.loads(result)['deployments']:
        checksum = deployment['checksum']
        osname = name(deployment['osname'])
        serial = deployment['serial']
        if not re.fullmatch('[0-9a-f]{64}', checksum) or not isinstance(serial, int) or serial < 0:
            raise ValueError('invalid native deployment identity')
        roots.append(Path('/sysroot/ostree/deploy') / osname / 'deploy' / (checksum + '.' + str(serial)) / APPLICATIONS.relative_to('/'))
    identities = set()
    for root in roots:
        if root.is_dir():
            for descriptor in root.glob('*/application.json'):
                _, identity = load(descriptor.parent)
                identities.add(identity)
    return identities

def prune(owner=None):
    ROOTS.mkdir(parents=True, exist_ok=True)
    with (ROOTS / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        identities = retained()
        for state in ROOTS.iterdir():
            if re.fullmatch('[0-9a-f]{64}', state.name) and state.name not in identities:
                shutil.rmtree(state)
    if owner:
        account = pwd.getpwnam(owner)
        def drop():
            os.initgroups(account.pw_name, account.pw_gid)
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
        environment = dict(os.environ, HOME=account.pw_dir, USER=owner, LOGNAME=owner)
        environment.pop('XDG_STATE_HOME', None)
        subprocess.run([sys.executable, str(Path(__file__).with_name('user-prune.py')), json.dumps(sorted(identities))], check=True, env=environment, preexec_fn=drop)
