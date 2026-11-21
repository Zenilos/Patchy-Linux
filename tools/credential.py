#!/usr/bin/env python3
# Copyright (c) 2026 Paulneja. GPLv3, see LICENSE. https://github.com/paulneja/Linux-on-esp32-S3
"""Fill a WiFi credential into the "cred" partition of an image.

The board takes its WiFi settings from a plain text file in a partition of
its own, so the person who flashes the image can put the network in
before the board ever boots. The image that is shipped has that partition
blank: no credential of the builder's is in it.

Two things are made here:

    cred.bin    the partition as it goes on the flash: the credential,
                then padding
    a patched copy of the full image, with the same partition filled in

Both are optional; flash.sh asks for what it needs.
"""
import argparse
import csv
import shutil
import sys
from pathlib import Path

# The partition holds plain text, and the board reads it with a shell
# loop that stops at the first empty line. Newlines are the padding: the
# shell never has to hold a long line, and a blank partition reads as
# "no credential" rather than as a wall of 0xff.
PADDING = b'\n'

# The board rejects a quote or a backslash in either value: it would end
# the quoted string in wpa_supplicant.conf and let the rest of the value
# be read as directives. The same boundary the wifi command draws.
FORBIDDEN = ('"', '\\')


def read_partitions(table):
    """The partition table, as name -> (offset, size)."""
    parts = {}
    with table.open() as stream:
        for row in csv.reader(stream):
            if not row or not row[0].strip() or row[0].lstrip().startswith('#'):
                continue
            offset, size = (int(field.strip(), 0) for field in row[3:5])
            parts[row[0].strip()] = (offset, size)
    return parts


def parse_credential(text):
    """The key=value pairs of the credential file."""
    values = {}
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            raise ValueError('line %d is not a key=value line: %r' % (number, line))
        key, _, value = line.partition('=')
        key = key.strip()
        value = value.strip()
        if key not in ('ssid', 'psk', 'key_mgmt'):
            raise ValueError('line %d has an unknown key: %r' % (number, key))
        for bad in FORBIDDEN:
            if bad in value:
                raise ValueError('the %s cannot contain %r' % (key, bad))
        values[key] = value

    if not values.get('ssid'):
        raise ValueError('the credential has no ssid')
    return values


def build_blob(values, size):
    """The partition: the credential, then padding."""
    lines = []
    for key in ('ssid', 'psk', 'key_mgmt'):
        if key in values:
            lines.append('%s=%s' % (key, values[key]))
    blob = ('\n'.join(lines) + '\n').encode()

    if len(blob) > size:
        raise ValueError('the credential is %d bytes and the partition holds %d'
                         % (len(blob), size))
    return blob + PADDING * (size - len(blob))


def patch_image(image, offset, blob, out):
    """A copy of the full image with the credential in the partition."""
    data = bytearray(image.read_bytes())
    if offset + len(blob) > len(data):
        raise ValueError('the partition does not fit in the image')
    data[offset:offset + len(blob)] = blob
    out.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('credential', help='the file with the ssid and the psk')
    parser.add_argument('--table', required=True,
                        help='the partition table (the CSV)')
    parser.add_argument('--partition', default='cred')
    parser.add_argument('--cred-out', help='write the partition here')
    parser.add_argument('--image', help='the full image to patch')
    parser.add_argument('--image-out', help='write the patched image here')
    args = parser.parse_args()

    parts = read_partitions(Path(args.table))
    if args.partition not in parts:
        raise SystemExit('the partition table has no %s partition' % args.partition)
    offset, size = parts[args.partition]

    values = parse_credential(Path(args.credential).read_text())
    blob = build_blob(values, size)

    if not args.cred_out and not args.image_out:
        raise SystemExit('nothing to do: give --cred-out and/or --image-out')

    if args.cred_out:
        Path(args.cred_out).write_bytes(blob)

    if args.image_out:
        if not args.image:
            raise SystemExit('--image-out needs --image')
        patch_image(Path(args.image), offset, blob, Path(args.image_out))

    # Say what was put in, without the secret: the psk is not printed.
    print('credential: %s, %s' % (values['ssid'],
                                 'with a key' if values.get('psk') else 'open network'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit('error: %s' % error)
