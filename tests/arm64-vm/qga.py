#!/usr/bin/env python3
"""Minimal qemu-guest-agent client (stdlib only). Used by vm.sh; no SSH by design (D22)."""
import argparse
import base64
import json
import random
import socket
import sys
import time


def _send(f, execute, arguments=None):
    req = {"execute": execute}
    if arguments is not None:
        req["arguments"] = arguments
    f.write((json.dumps(req) + "\n").encode())
    f.flush()


def _recv(f):
    line = f.readline()
    if not line:
        raise ConnectionError("guest agent closed the socket")
    return json.loads(line)


def _call(f, execute, arguments=None):
    _send(f, execute, arguments)
    resp = _recv(f)
    if "error" in resp:
        raise RuntimeError("guest agent error: %s" % (resp["error"],))
    return resp["return"]


def _sync(f, sync_id):
    """guest-sync: discard stale replies until the one carrying our id."""
    _send(f, "guest-sync", {"id": sync_id})
    while True:
        resp = _recv(f)
        if "error" in resp:
            raise RuntimeError("guest agent error: %s" % (resp["error"],))
        if resp.get("return") == sync_id:
            return


def run(sock_path, cmd, timeout_s):
    """Run `sh -c cmd` in the guest; return (exitcode, stdout, stderr). TimeoutError after timeout_s."""
    deadline = time.monotonic() + timeout_s

    def remaining():
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("guest command exceeded %ss" % timeout_s)
        return left

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(remaining())
        s.connect(sock_path)
        f = s.makefile("rwb")

        def call(execute, arguments=None):
            s.settimeout(remaining())
            try:
                return _call(f, execute, arguments)
            except socket.timeout:
                raise TimeoutError("guest command exceeded %ss" % timeout_s)

        sync_id = random.randint(1, 2**31 - 1)
        s.settimeout(remaining())
        try:
            _sync(f, sync_id)
        except socket.timeout:
            raise TimeoutError("guest command exceeded %ss" % timeout_s)
        pid = call("guest-exec", {"path": "/bin/sh", "arg": ["-c", cmd],
                                  "capture-output": True})["pid"]
        while True:
            st = call("guest-exec-status", {"pid": pid})
            if st.get("exited"):
                out = base64.b64decode(st.get("out-data", ""))
                err = base64.b64decode(st.get("err-data", ""))
                return st.get("exitcode", 255), out, err
            time.sleep(min(0.5, remaining()))
    finally:
        try:
            f.close()
        except (NameError, OSError):
            pass
        s.close()


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("sock")
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    code, out, err = run(a.sock, " ".join(cmd), a.timeout)
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    return code


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        sys.exit(main(sys.argv[1:]))
    except (TimeoutError, OSError, RuntimeError, ValueError) as e:
        print("qga: %s" % e, file=sys.stderr)
        sys.exit(255)
