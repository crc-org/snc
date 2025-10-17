#!/usr/bin/env python3

import socket
import sys
import time
import fcntl, struct
import os
import errno
import pathlib

VSOCK_DEV = pathlib.Path("/dev/vsock")
HOST_CID = 2 # VMADDR_CID_HOST

def main():
    if len(sys.argv) != 2:
        print("ERROR: expected a vsock port number as first argument.")
        raise SystemExit(errno.EINVAL)

    port = int(sys.argv[1])
    tries = 5
    while not VSOCK_DEV.exists():
        tries -= 1

        if not tries:
            print(f"ERROR: {VSOCK_DEV} didn't appear ...")
            return errno.ENODEV
        print(f"Waiting for {VSOCK_DEV} to appear ... ({tries} tries left)")
        time.sleep(1)

    print(f"Looking up the CID in {VSOCK_DEV}...")
    with open(VSOCK_DEV, 'rb') as f:
        r = fcntl.ioctl(f, socket.IOCTL_VM_SOCKETS_GET_LOCAL_CID, '    ')
        cid = struct.unpack('I', r)[0]
    print(f'Our vsock CID is {cid}.')

    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)

    try:
        s.connect((HOST_CID, port))
    except OSError as e:

        if e.errno in (errno.ENODEV, errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.ETIMEDOUT, errno.ECONNRESET):
            print(f"No remote host on vsock://{HOST_CID}:{port} ({e.strerror})")
            s.close()
            return 1

        print(f"Unexpected error connecting vsock://{HOST_CID}:{port}: {e}")
        s.close()
        return 1

    msg = b"hello"
    s.sendall(msg)

    s.sendall(b"\n")

    s.close()
    print(f"A remote host is listening on vsock://{HOST_CID}:{port}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
