# SPDX-License-Identifier: MIT
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from archive import extract
from common import APPLICATIONS, ROOTS, load, name
from prune import prune

parser = argparse.ArgumentParser()
commands = parser.add_subparsers(dest='operation', required=True)
for operation in ['install', 'prepare', 'remove']:
    commands.add_parser(operation).add_argument('subject')
commands.add_parser('prune').add_argument('--owner')
args = parser.parse_args()
if os.geteuid() != 0:
    parser.error('deployment preparation and pruning require root')
if args.operation == 'prune':
    prune(args.owner)
    sys.exit(0)
if args.operation == 'remove':
    status = subprocess.call(['rpm-ostree', 'uninstall', 'impurified-' + name(args.subject)])
    prune()
    sys.exit(status)
archive = Path(args.subject).resolve(strict=True)
nix_store = shutil.which('nix-store')
if not nix_store:
    parser.error('the host must provide Nix')
ROOTS.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.source-', dir=ROOTS) as temporary:
    # Read a stable copy: the bytes prepared are the bytes handed to the manager.
    copied = Path(temporary) / 'application.rpm'
    shutil.copyfile(archive, copied)
    tree = Path(temporary) / 'payload'
    tree.mkdir()
    extract(copied, tree)
    application_root = tree / APPLICATIONS.relative_to('/')
    entries = list(application_root.iterdir())
    if len(entries) != 1:
        raise ValueError('expected one application descriptor')
    implementation = entries[0]
    config, identity = load(implementation)
    if implementation.name != config['name']:
        raise ValueError('application identity does not match its directory')
    actual_name = subprocess.check_output(['rpm', '-qp', '--qf', '%{NAME}', str(copied)], text=True)
    if actual_name != 'impurified-' + name(config['name']):
        raise ValueError('native RPM name does not match application')
    scripts = subprocess.check_output(['rpm', '-qp', '--scripts', '--triggers', '--filetriggers', str(copied)], text=True)
    if scripts.strip():
        raise ValueError('impurifier application RPMs must not contain scriptlets')
    with (ROOTS / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix='.prepare-', dir=ROOTS) as staged:
            for field, cache_name in [('sdk', 'sdk-cache'), ('installable', 'cache')]:
                command = [nix_store, '--realise', config[field], '--add-root', staged + '/' + field]
                cache = implementation / cache_name
                if cache.is_dir():
                    command += ['--option', 'substituters', cache.as_uri(), '--option', 'require-sigs', 'false']
                subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            (Path(staged) / 'source.json').write_text(json.dumps({'name': config['name'], 'identity': identity}))
            if not (ROOTS / identity).exists():
                os.rename(staged, ROOTS / identity)
    if args.operation == 'prepare':
        sys.exit(0)
    deployments = json.loads(subprocess.check_output(['rpm-ostree', 'status', '--json'], text=True))['deployments']
    booted = next(deployment for deployment in deployments if deployment.get('booted'))
    selected = next(deployment for deployment in deployments if deployment['osname'] == booted['osname'])
    requested = selected.get('requested-local-packages', [])
    replacing = actual_name in selected.get('requested-packages', []) or any(nevra.rsplit('-', 2)[0] == actual_name for nevra in requested)
    command = ['rpm-ostree', 'install']
    if replacing:
        command.append('--uninstall=' + actual_name)
    command.append(str(copied))
    status = subprocess.call(command)
    prune()
    sys.exit(status)
