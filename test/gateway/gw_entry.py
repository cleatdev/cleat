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
#       socket.getaddrinfo. Every lookup is appended to <path>.lookups as
#       "<name> <family>", one line per call. A name on several lines is
#       answered one line per lookup in file order and the last line repeats.
#       A line may carry several addresses joined by commas, answered together
#       as one lookup. The family asked for is honoured, the way libc does:
#       an AF_INET lookup never sees an IPv6 answer. An address field that
#       starts with `!` is answered whatever family was asked, which stands
#       for a resolver that misbehaves. `~<seconds>,` before the addresses
#       holds the answer that long.
#   --upstream-map <path>  "<address> <port> [<peer>]" lines. The gateway
#       classifies the fixture's addresses as if they were real and dials them
#       through its own open_upstream. This seam maps only the socket address:
#       a dial of a mapped address lands on a harness listener on 127.0.0.1,
#       and getpeername on that socket reads back as the mapped address, or as
#       <peer> when a line names one.
#
# The second seam exists because the gateway refuses loopback, so without it no
# tunnel could ever be established against a local listener.

import argparse
import errno
import importlib.util
import ipaddress
import os
import socket
import sys
import threading
import time

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
            spec = fields[0]
            delay = 0.0
            if spec.startswith("~"):
                d, _, spec = spec[1:].partition(",")
                delay = float(d)
            any_family = spec.startswith("!")
            addrs = [a for a in spec.lstrip("!").split(",") if a]
            for name in fields[1:]:
                answers.setdefault(name.lower().rstrip("."), []).append((addrs, any_family, delay))
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
                f.write("%s %d\n" % (name, int(family)))
            key = name.lower()
            if key.endswith("."):
                key = key[:-1]
            seq = answers.get(key)
            if not seq:
                raise socket.gaierror(socket.EAI_NONAME, "fixture: no answer for " + name)
            i = cursor.get(key, 0)
            cursor[key] = i + 1
            addrs, any_family, delay = seq[min(i, len(seq) - 1)]
        if delay:
            time.sleep(delay)
        out = []
        for a in addrs:
            fam = socket.AF_INET6 if ":" in a else socket.AF_INET
            if family not in (0, socket.AF_UNSPEC) and fam != family and not any_family:
                continue
            if fam == socket.AF_INET6:
                out.append((fam, socket.SOCK_STREAM, 6, "", (a, port, 0, 0)))
            else:
                out.append((fam, socket.SOCK_STREAM, 6, "", (a, port)))
        if not out:
            raise socket.gaierror(socket.EAI_NODATA, "fixture: no answer in that family for " + name)
        return out

    socket.getaddrinfo = fixture_getaddrinfo


def install_upstream(gw, path):
    upmap = {}
    back = {}
    if path:
        with open(path) as f:
            for line in f:
                fields = line.split()
                if len(fields) in (2, 3):
                    upmap[fields[0]] = int(fields[1])
                    back[int(fields[1])] = fields[2] if len(fields) == 3 else fields[0]

    def harness_dial_target(addr, port):
        try:
            ipaddress.IPv4Address(addr)
        except ValueError:
            # A hostname reached the dial: resolve it the way a connect call
            # would, through the fixture, so the second lookup is logged.
            addr = socket.getaddrinfo(addr, port, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        if addr not in upmap:
            # Nothing listens there. Answer the way an unroutable address does.
            return ("127.0.0.1", 9)
        return ("127.0.0.1", upmap[addr])

    def harness_peer_address(sockaddr):
        peer = back.get(sockaddr[1], sockaddr[0])
        if peer == "!reset":
            # The peer reset between the connect and getpeername.
            raise OSError(errno.ENOTCONN, "harness: peer reset after connect")
        return peer

    gw.dial_target = harness_dial_target
    gw.peer_address = harness_peer_address


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
