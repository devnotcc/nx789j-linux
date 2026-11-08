#!/usr/bin/env python3
"""Compare the link keys in an Android btsnoop log with bt_config.conf, without printing keys.

  bt-snoop-keys.py btsnoop_hci.log bt_config.conf

For every Link Key Notification (event 0x18, a new pairing) and Link Key Request Reply (command
0x040B, a reconnect) in the log, prints the device address, the key type, and whether the key
equals the LinkKey stored for that device in bt_config.conf as-is, byte-reversed, or not at all.
Keys and their hashes are never printed.
"""
import re
import struct
import sys


def config_keys(path):
    keys, cur = {}, None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        m = re.match(r'^\[([0-9a-fA-F:]{17})\]$', line)
        if m:
            cur = m.group(1).lower()
            continue
        if line.startswith('['):
            cur = None
        elif cur and line.startswith('LinkKey ='):
            keys[cur] = bytes.fromhex(line.split('=', 1)[1].strip())
    return keys


def addr(b):  # HCI bd_addr is little-endian
    return ':'.join('%02x' % x for x in reversed(b))


def packets(path):
    with open(path, 'rb') as f:
        if f.read(8) != b'btsnoop\0':
            sys.exit('not a btsnoop file')
        f.read(8)
        while True:
            h = f.read(24)
            if len(h) < 24:
                return
            orig, incl, flags, drops, ts = struct.unpack('>IIIIq', h)
            data = f.read(incl)
            # H4 framing: first byte is the packet type (1 command, 4 event)
            yield data


def compare(stored, key):
    if stored is None:
        return 'no LinkKey stored for this device'
    if stored == key:
        return 'SAME as bt_config (as stored)'
    if stored == key[::-1]:
        return 'SAME as bt_config but byte-reversed'
    return 'DIFFERENT from bt_config'


def main():
    log, conf = sys.argv[1], sys.argv[2]
    stored = config_keys(conf)
    n = 0
    for p in packets(log):
        if len(p) < 3:
            continue
        if p[0] == 4 and p[1] == 0x18 and len(p) >= 3 + 23:  # Link Key Notification
            a, key, typ = p[3:9], p[9:25], p[25]
            print(f'notification {addr(a)} type {typ}: {compare(stored.get(addr(a)), key)}')
            n += 1
        elif p[0] == 1 and p[1:3] == b'\x0b\x04' and len(p) >= 4 + 22:  # Link Key Request Reply
            a, key = p[4:10], p[10:26]
            print(f'request-reply {addr(a)}: {compare(stored.get(addr(a)), key)}')
            n += 1
    print(f'{n} key events')


if __name__ == '__main__':
    main()
