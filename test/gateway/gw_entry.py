#!/usr/bin/env python3
# The gateway's test harness entry point (EGRESS-SPEC.md 11.6). Never shipped.
#
# It runs the real gateway source with the uid-0 steps of its startup skipped,
# because an unprivileged harness can neither chown a socket to another uid nor
# setuid. The post-drop check still runs.
#
# Two seams, both accepted here and refused by the shipped entry point:
#
#   --resolver-fixture <path>  a hosts-format file installed as the process's
#       socket.getaddrinfo. Every lookup is appended to <path>.lookups, one line
#       per call. A name on several lines is answered one line per lookup in
#       file order and the last line repeats. A line may carry several
#       addresses joined by commas, answered together as one lookup.
#   --upstream-map <path>  "<address> <port>" lines. The gateway classifies
#       the fixture's addresses as if they were real and dials them. This seam
#       carries each dial of a mapped address to a harness listener on
#       127.0.0.1 instead. The mapped address is reported as the peer.
#
# The second seam exists because the gateway refuses loopback, so without it no
# tunnel could ever be established against a local listener.

import argparse
import importlib.util
import ipaddress
import os
import socket
import sys
import threading

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.environ.get("CLEAT_GW_SOURCE") or os.path.join(
    HERE, "..", "..", "docker", "gateway", "gateway.py")


def load_gateway():
    spec = importlib.util.spec_from_file_location("cleat_gateway", SOURCE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_fixture(path):
    answers = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            fields = line.split()
            addrs = fields[0].split(",")
            for name in fields[1:]:
                answers.setdefault(name.lower().rstrip("."), []).append(addrs)
    return answers


def install_resolver(path):
    answers = parse_fixture(path)
    cursor = {}
    lock = threading.Lock()
    log = path + ".lookups"
    open(log, "a").close()

    def fixture_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        name = host.decode("ascii", "replace") if isinstance(host, bytes) else str(host)
        with lock:
            with open(log, "a") as f:
                f.write(name + "\n")
            key = name.lower()
            if key.endswith("."):
                key = key[:-1]
            seq = answers.get(key)
            if not seq:
                raise socket.gaierror(socket.EAI_NONAME, "fixture: no answer for " + name)
            i = cursor.get(key, 0)
            cursor[key] = i + 1
            addrs = seq[min(i, len(seq) - 1)]
        out = []
        for a in addrs:
            if ":" in a:
                out.append((socket.AF_INET6, socket.SOCK_STREAM, 6, "", (a, port, 0, 0)))
            else:
                out.append((socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port)))
        return out

    socket.getaddrinfo = fixture_getaddrinfo


def install_upstream(gw, path):
    import asyncio
    upmap = {}
    if path:
        with open(path) as f:
            for line in f:
                fields = line.split()
                if len(fields) == 2:
                    upmap[fields[0]] = int(fields[1])

    async def harness_open_upstream(addr, port):
        try:
            ipaddress.IPv4Address(addr)
        except ValueError:
            # A hostname reached the dial: resolve it the way a connect call
            # would, through the fixture, so the second lookup is logged.
            infos = socket.getaddrinfo(addr, port, socket.AF_INET, socket.SOCK_STREAM)
            addr = infos[0][4][0]
        target = upmap.get(addr)
        if target is None:
            raise OSError("harness: no upstream listener for " + addr)
        reader, writer = await asyncio.open_connection("127.0.0.1", target)
        return reader, writer, addr

    gw.open_upstream = harness_open_upstream


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", required=True)
    ap.add_argument("--sock-dir", required=True)
    ap.add_argument("--admin", required=True)
    ap.add_argument("--resolver-fixture", required=True)
    ap.add_argument("--upstream-map")
    args = ap.parse_args()
    gw = load_gateway()
    install_resolver(args.resolver_fixture)
    install_upstream(gw, args.upstream_map)
    cfg = gw.Config(sock_dir=args.sock_dir, admin_sock=args.admin,
                    policy_path=args.policy, harness=True)
    return gw.run(cfg)


if __name__ == "__main__":
    sys.exit(main())
