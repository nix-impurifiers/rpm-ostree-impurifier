# SPDX-License-Identifier: MIT
"""Read regular RPM payload files without executing scripts or following links."""
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess


def extract(archive, destination):
    subprocess.run(['rpm', '--checksig', '--nosignature', str(archive)], check=True, stdout=subprocess.DEVNULL)
    process = subprocess.Popen(['rpm2cpio', str(archive)], stdout=subprocess.PIPE)
    stream = process.stdout
    def read(size):
        value = stream.read(size)
        if len(value) != size:
            raise ValueError('truncated native archive')
        return value
    try:
        while True:
            header = read(110)
            if header[:6] not in [b'070701', b'070702']:
                raise ValueError('unsupported CPIO payload')
            fields = [int(header[i:i+8], 16) for i in range(6, 110, 8)]
            mode, size, namesize = fields[1], fields[6], fields[11]
            if namesize < 1 or namesize > 4096:
                raise ValueError('invalid archive name')
            raw_name = read(namesize)
            if not raw_name.endswith(b'\0'):
                raise ValueError('unterminated archive name')
            filename = raw_name[:-1].decode('utf-8')
            read(-(110 + namesize) % 4)
            if filename == 'TRAILER!!!':
                break
            relative = PurePosixPath(filename)
            if relative.is_absolute() or '..' in relative.parts or not relative.parts or relative.parts[0] != 'usr':
                raise ValueError('archive path is outside /usr')
            target = destination.joinpath(*relative.parts)
            if stat.S_ISDIR(mode):
                if size:
                    raise ValueError('invalid directory contents')
                target.mkdir(parents=True, exist_ok=True)
            elif stat.S_ISREG(mode):
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output:
                    remaining = size
                    while remaining:
                        data = read(min(remaining, 1024 * 1024))
                        output.write(data)
                        remaining -= len(data)
            else:
                raise ValueError('archive contains a link or special file')
            read(-size % 4)
        # rpm2cpio may still have padding to write after TRAILER!!!.
        while stream.read(1024 * 1024):
            pass
        if process.wait() != 0:
            raise ValueError('native payload reader failed')
    finally:
        stream.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
