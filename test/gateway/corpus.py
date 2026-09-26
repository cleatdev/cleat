#!/usr/bin/env python3
# The gateway corpus (EGRESS-SPEC.md 11.6, 4.5 and 9.1). Standard library only.
#
# Every row drives a real gateway process, started through gw_entry.py with no
# Docker at all, over the two interfaces a box and the CLI use: the proxy
# socket and the admin socket. The corpus never imports the gateway.
#
#   python3 corpus.py              every row
#   python3 corpus.py -k <text>    rows whose name contains <text>
#   python3 corpus.py --list       row names
#
# Each row gets its own gateway, fixture and listeners. Rows marked slow wait
# out a real deadline and run concurrently with the rest.

import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ENTRY = os.path.join(HERE, "gw_entry.py")
FIXTURES = os.path.join(HERE, "fixtures")
GW_DIR = os.path.join(HERE, "..", "..", "docker", "gateway")
SOURCE = os.environ.get("CLEAT_GW_SOURCE") or os.path.join(GW_DIR, "gateway.py")
GW_ADMIN = os.path.join(GW_DIR, "gw-admin")
GW_HEALTH = os.path.join(GW_DIR, "gw-health")

ALLOWED = b"allowed.example"
OTHER = b"other.example"
PUB = "11.0.0.1"
PUB2 = "11.0.0.2"
ALERT_AD = bytes.fromhex("15030300020231")
ALERT_IE = bytes.fromhex("15030300020250")
SELFTEST = b"cleat-gateway.invalid"

ROW_RE = re.compile(
    r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ "
    r"code=(policy|port|sni|handshake-flood|address|upstream) "
    r"sub=(-|no-sni|dup-sni|sni-mismatch|bad-clienthello|handshake-timeout|no-clienthello) "
    r"origin=box host=[a-z0-9.:_?-]{1,128} port=\d+ trunc=[01]$")


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


# ---------------------------------------------------------------------------
# Bytes on the wire.

def u16(n):
    return n.to_bytes(2, "big")


def ext(t, data):
    return u16(t) + u16(len(data)) + data


def sni_ext(*names, name_type=0):
    lst = b"".join(bytes([name_type]) + u16(len(n)) + n for n in names)
    return ext(0x0000, u16(len(lst)) + lst)


def std_exts():
    return [
        ext(0x000a, u16(4) + u16(0x001d) + u16(0x0017)),
        ext(0x000d, u16(4) + u16(0x0403) + u16(0x0804)),
        ext(0x002b, b"\x02\x03\x04"),
        ext(0x0033, u16(36) + u16(0x001d) + u16(32) + os.urandom(32)),
    ]


def client_hello(sni=ALLOWED, extra=(), ciphers=(0x1301, 0x1302, 0x1303),
                 session_id=b"", raw_exts=None, front=()):
    if raw_exts is None:
        es = list(front)
        if sni is not None:
            es.append(sni_ext(sni))
        es += std_exts() + list(extra)
        raw_exts = b"".join(es)
    cs = b"".join(u16(c) for c in ciphers)
    body = (b"\x03\x03" + os.urandom(32) + bytes([len(session_id)]) + session_id
            + u16(len(cs)) + cs + b"\x01\x00" + u16(len(raw_exts)) + raw_exts)
    return b"\x01" + len(body).to_bytes(3, "big") + body


def rec(t, payload, ver=b"\x03\x01"):
    return bytes([t]) + ver + u16(len(payload)) + payload


def hs_records(msg, *cuts):
    """A handshake message split into 0x16 records at the given offsets."""
    out = b""
    prev = 0
    for c in list(cuts) + [len(msg)]:
        out += rec(0x16, msg[prev:c])
        prev = c
    return out


CCS = rec(0x14, b"\x01", b"\x03\x03")


def app(n):
    return rec(0x17, os.urandom(n), b"\x03\x03")


def fixture_hello(name):
    with open(os.path.join(FIXTURES, "clienthello-%s.hex" % name)) as f:
        return bytes.fromhex("".join(l.strip() for l in f if not l.startswith("#")))


# ---------------------------------------------------------------------------
# Listeners the gateway dials, through the harness upstream map.

class EdgeConn:
    def __init__(self, sock, script):
        self.sock = sock
        self.data = bytearray()
        self.closed = threading.Event()
        self.script = list(script)
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            while True:
                d = self.sock.recv(65536)
                if not d:
                    break
                self.data += d
                while self.script and len(self.data) >= self.script[0][0]:
                    self.sock.sendall(self.script.pop(0)[1])
        except OSError:
            pass
        self.closed.set()

    def send(self, b):
        self.sock.sendall(b)


class Edge:
    def __init__(self):
        self.ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.ls.bind(("127.0.0.1", 0))
        self.ls.listen(512)
        self.port = self.ls.getsockname()[1]
        self.conns = []
        self.script = []        # [(bytes received before, bytes to send)]
        self.running = True
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while self.running:
            try:
                s, _ = self.ls.accept()
            except OSError:
                return
            self.conns.append(EdgeConn(s, self.script))

    def wait_bytes(self, n, idx=0, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            if len(self.conns) > idx and len(self.conns[idx].data) >= n:
                return bytes(self.conns[idx].data)
            time.sleep(0.01)
        got = bytes(self.conns[idx].data) if len(self.conns) > idx else None
        raise Fail("edge received %s, wanted %d bytes" % (
            "no connection" if got is None else "%d bytes" % len(got), n))

    def data(self, idx=0, settle=0.3):
        time.sleep(settle)
        return bytes(self.conns[idx].data) if len(self.conns) > idx else b""

    def close(self):
        self.running = False
        try:
            self.ls.close()
        except OSError:
            pass
        for c in self.conns:
            try:
                c.sock.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# A gateway under test.

def policy_digest(mode, port, hosts):
    text = "%s\n%d\n" % (mode, port) + "".join(h + "\n" for h in hosts)
    return "v1:" + hashlib.md5(text.encode("ascii")).hexdigest()[:16]


def policy_doc(mode="strict", hosts=(ALLOWED,), max_tunnels=256, handshake_timeout_s=20,
               denials_max=1048576, digest=None, port=443):
    hs = sorted(h.decode() if isinstance(h, bytes) else h for h in hosts)
    doc = {
        "v": 1,
        "digest": digest or policy_digest(mode, port, hs),
        "mode": mode,
        "port": port,
        "hosts": hs,
        "max_tunnels": max_tunnels,
        "handshake_timeout_s": handshake_timeout_s,
        "denials_log_max_bytes": denials_max,
        "selftest_host": "cleat-gateway.invalid",
    }
    return json.dumps(doc, indent=2) + "\n"


class GW:
    def __init__(self, hosts=(ALLOWED,), fixture=None, start=True, policy_text=None, peers=None, **pol):
        self.dir = tempfile.mkdtemp(prefix="gw", dir="/tmp")
        self.proxy = os.path.join(self.dir, "proxy.sock")
        self.denials = os.path.join(self.dir, "denials.log")
        self.admin_path = os.path.join(self.dir, "admin.sock")
        self.policy_path = os.path.join(self.dir, "policy.json")
        self.fixture_path = os.path.join(self.dir, "hosts")
        self.map_path = os.path.join(self.dir, "upstreams")
        if fixture is None:
            fixture = {"allowed.example": [PUB]}
        self.edges = {}
        lines = []
        self.peers = peers or {}
        for name, entries in fixture.items():
            for entry in entries:
                addrs = list(entry) if isinstance(entry, (list, tuple)) else [entry]
                prefix = ""
                if addrs and addrs[0].startswith("~"):
                    prefix, addrs = addrs[0] + ",", addrs[1:]
                if addrs and addrs[0].startswith("!"):
                    prefix += "!"
                    addrs = [addrs[0][1:]] + addrs[1:]
                for a in addrs:
                    if a not in self.edges:
                        self.edges[a] = Edge()
                lines.append(prefix + ",".join(addrs) + " " + name)
        with open(self.fixture_path, "w") as f:
            f.write("\n".join(lines) + "\n")
        with open(self.map_path, "w") as f:
            for a, e in self.edges.items():
                f.write("%s %d%s\n" % (a, e.port, " " + self.peers[a] if a in self.peers else ""))
        with open(self.policy_path, "w") as f:
            f.write(policy_text if policy_text is not None else policy_doc(hosts=hosts, **pol))
        self.proc = None
        self.allow_errors = False
        if start:
            self.start()

    def argv(self):
        return [sys.executable, ENTRY, "--policy", self.policy_path, "--sock-dir", self.dir,
                "--admin", self.admin_path, "--resolver-fixture", self.fixture_path,
                "--upstream-map", self.map_path]

    def start(self, wait=True):
        env = dict(os.environ)
        env["CLEAT_GW_SOURCE"] = SOURCE
        self.out = open(os.path.join(self.dir, "stdout"), "wb")
        self.err = open(os.path.join(self.dir, "stderr"), "wb")
        self.proc = subprocess.Popen(self.argv(), stdin=subprocess.DEVNULL,
                                     stdout=self.out, stderr=self.err, env=env)
        if not wait:
            return
        end = time.time() + 10
        while time.time() < end:
            if self.proc.poll() is not None:
                raise Fail("gateway exited at start: %s" % self.stderr())
            try:
                if self.admin("policy-digest").startswith("ok "):
                    return
            except OSError:
                pass
            time.sleep(0.02)
        raise Fail("gateway never answered its admin socket")

    def admin(self, verb, arg=None, timeout=5):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.admin_path)
            s.sendall((verb + (" " + arg if arg else "") + "\n").encode())
            data = b""
            while b"\n" not in data:
                d = s.recv(512)
                if not d:
                    break
                data += d
        finally:
            s.close()
        return data.decode().rstrip("\n")

    def connect(self, timeout=10):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.proxy)
        return s

    def rows(self):
        if not os.path.exists(self.denials):
            return []
        out = []
        with open(self.denials) as f:
            for line in f:
                fields = line.rstrip("\n").split(" ")
                row = {"ts": fields[0]}
                for kv in fields[1:]:
                    k, _, v = kv.partition("=")
                    row[k] = v
                out.append(row)
        return out

    def last_row(self):
        rows = self.rows()
        check(rows, "no denials.log row was written")
        return rows[-1]

    def lookups(self):
        try:
            with open(self.fixture_path + ".lookups") as f:
                return [l.rstrip("\n") for l in f]
        except FileNotFoundError:
            return []

    def stdout(self):
        self.out.flush()
        with open(os.path.join(self.dir, "stdout")) as f:
            return f.read()

    def stderr(self):
        self.err.flush()
        with open(os.path.join(self.dir, "stderr")) as f:
            return f.read()

    def restart(self):
        """SIGTERM, then a new gateway process over the same socket directory."""
        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(6)
        self.out.close()
        self.err.close()
        os.rename(os.path.join(self.dir, "stderr"), os.path.join(self.dir, "stderr.1"))
        self.start()

    def write_policy(self, text):
        tmp = self.policy_path + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.rename(tmp, self.policy_path)

    def stop(self):
        try:
            if self.proc is not None and self.proc.poll() is None:
                self.proc.send_signal(signal.SIGTERM)
                try:
                    self.proc.wait(5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
                    raise Fail("gateway did not exit within 5 s of SIGTERM")
            for e in self.edges.values():
                e.close()
            err = self.stderr() if self.proc is not None else ""
            if not self.allow_errors:
                check("Traceback" not in err, "gateway printed a traceback:\n" + err)
                check("internal error" not in err, "gateway hit an internal error:\n" + err)
            if os.path.exists(self.denials):
                with open(self.denials) as f:
                    for line in f:
                        check(ROW_RE.match(line.rstrip("\n")),
                              "denials.log row breaks the grammar: %r" % line)
        finally:
            shutil.rmtree(self.dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# A client.

class Resp:
    def __init__(self, status, reason, headers, body):
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body


def read_response(s, timeout=5):
    s.settimeout(timeout)
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            d = s.recv(65536)
        except socket.timeout:
            raise Fail("no response within %d s" % timeout)
        except ConnectionError:
            d = b""
        if not d:
            return None if not buf else Resp(0, "truncated", {}, buf)
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ", 2)
    headers = {}
    for l in lines[1:]:
        k, _, v = l.partition(":")
        headers[k.strip().lower()] = v.strip()
    body = rest
    if "content-length" in headers:
        n = int(headers["content-length"])
        while len(body) < n:
            d = s.recv(65536)
            if not d:
                break
            body += d
    return Resp(int(parts[1]), parts[2] if len(parts) > 2 else "", headers, body)


def tunnel(g, target, headers=b"", raw=None):
    s = g.connect()
    if raw is None:
        raw = b"CONNECT " + target + b" HTTP/1.1\r\nHost: " + target + b"\r\n" + headers + b"\r\n"
    s.sendall(raw)
    return s, read_response(s)


def open_ok(g, target=ALLOWED + b":443"):
    s, r = tunnel(g, target)
    check(r is not None and r.status == 200, "wanted 200 for %r, got %s" % (
        target, None if r is None else "%d %s" % (r.status, r.reason)))
    return s


def recv_all(s, timeout=5):
    s.settimeout(timeout)
    data = b""
    try:
        while True:
            d = s.recv(65536)
            if not d:
                return data, True
            data += d
    except socket.timeout:
        return data, False
    except ConnectionError:
        return data, True


def expect_alert(s, alert=ALERT_AD, timeout=5):
    data, eof = recv_all(s, timeout)
    check(data == alert, "wanted alert %s, got %r" % (alert.hex(), data[:40]))
    check(eof, "tunnel was not closed after the alert")


def expect_no_alert(s, wait=0.3):
    r, _, _ = select.select([s], [], [], wait)
    if r:
        try:
            d = s.recv(64)
        except OSError:
            d = b""
        check(d != ALERT_AD and d != ALERT_IE and d != b"", "tunnel was refused: %r" % d[:16])


def expect_row(g, code, sub="-", host=None, **kw):
    row = g.last_row()
    check(row["code"] == code and row["sub"] == sub,
          "wanted row %s/%s, got %s/%s" % (code, sub, row["code"], row["sub"]))
    if host is not None:
        check(row["host"] == host, "wanted host=%s, got host=%s" % (host, row["host"]))
    for k, v in kw.items():
        check(row[k] == str(v), "wanted %s=%s, got %s" % (k, v, row[k]))
    return row


def refused_before_200(g, target, status, code=None):
    """A refusal answered before any 200. It never reaches the resolver."""
    before = len(g.rows())
    looked = len(g.lookups())
    s, r = tunnel(g, target)
    s.close()
    check(r is not None and r.status == status,
          "%r: wanted %d, got %s" % (target, status, None if r is None else r.status))
    check(len(g.lookups()) == looked, "%r: a refusal before the 200 reached the resolver" % target)
    if code is None:
        check(len(g.rows()) == before, "%r: a refusal with no code wrote a row" % target)
        check("x-cleat-reason" not in r.headers, "%r: X-Cleat-Reason on an uncoded refusal" % target)
    else:
        check(len(g.rows()) == before + 1, "%r: wanted one new row" % target)
        check(g.last_row()["code"] == code, "%r: row code %s, wanted %s" % (
            target, g.last_row()["code"], code))
        check(r.headers.get("x-cleat-reason") == code, "%r: X-Cleat-Reason %r, wanted %s" % (
            target, r.headers.get("x-cleat-reason"), code))
    return r


# ---------------------------------------------------------------------------
# Rows.

ROWS = []


def row(name, slow=False):
    def wrap(fn):
        ROWS.append((name, fn, slow))
        return fn
    return wrap


def with_gw(fn, **gwkw):
    """A row body bound to a fresh gateway built from gwkw, always stopped."""
    def run():
        g = GW(**gwkw)
        try:
            fn(g)
        finally:
            g.stop()
    return run


def established(g, target=ALLOWED + b":443", hello=None, edge=PUB):
    s = open_ok(g, target)
    data = rec(0x16, hello or client_hello())
    s.sendall(data)
    got = g.edges[edge].wait_bytes(len(data))
    check(got == data, "edge received different bytes than the client sent")
    expect_no_alert(s)
    return s


@row("trailing dot in CONNECT, normalized SNI")
def _():
    with_gw(lambda g: established(g, b"allowed.example.:443"))()


@row("uppercase CONNECT, lowercase SNI")
def _():
    with_gw(lambda g: established(g, b"ALLOWED.Example:443"))()


@row("userinfo in CONNECT target is refused with no resolution")
def _():
    def body(g):
        refused_before_200(g, b"user@allowed.example:443", 403, "policy")
        check(g.last_row()["trunc"] == "1", "a replaced byte did not set trunc")
    with_gw(body)()


@row("punycode A-label allowed")
def _():
    with_gw(lambda g: established(g, b"xn--exmple-cua.com:443",
                                  client_hello(sni=b"xn--exmple-cua.com")),
            hosts=(b"xn--exmple-cua.com",), fixture={"xn--exmple-cua.com": [PUB]})()


@row("U-label non-ASCII bytes are refused")
def _():
    def body(g):
        # 4.3a rule 7: a byte above 0x7E makes the head malformed, so this is a
        # 400 with no row. The 11.6 row says 403. The grammar is the later text.
        refused_before_200(g, "ex\u00e4mple.com:443".encode("utf-8"), 400)
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello(sni="allowed.ex\u00e4mple".encode("utf-8"))))
        expect_alert(s)
        expect_row(g, "sni", "bad-clienthello")
    with_gw(body)()


@row("lookalike host with the real one allowed")
def _():
    def body(g):
        refused_before_200(g, b"github.com.evil.tld:443", 403, "policy")
        refused_before_200(g, b"evilgithub.com:443", 403, "policy")
        refused_before_200(g, b"api.github.com:443", 403, "policy")
        established(g, b"GITHUB.COM:443", client_hello(sni=b"github.com"))
    with_gw(body, hosts=(b"github.com",), fixture={"github.com": [PUB]})()


@row("split ClientHello across records")
def _():
    def body(g):
        s = open_ok(g)
        ch = client_hello()
        data = hs_records(ch, 10, 60, 100)
        s.sendall(data)
        check(g.edges[PUB].wait_bytes(len(data)) == data, "edge bytes differ")
        expect_no_alert(s)
    with_gw(body)()


@row("SNI straddling a record boundary")
def _():
    def body(g):
        s = open_ok(g)
        ch = client_hello()
        cut = ch.find(ALLOWED) + 4
        data = hs_records(ch, cut)
        s.sendall(data[:5 + cut])
        time.sleep(0.1)
        s.sendall(data[5 + cut:])
        check(g.edges[PUB].wait_bytes(len(data)) == data, "edge bytes differ")
        expect_no_alert(s)
    with_gw(body)()


@row("foreign SNI after an allowed CONNECT")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello(sni=OTHER)))
        expect_alert(s)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
        check(g.lookups() == [], "a foreign SNI reached the resolver")
        check(not g.edges[PUB].conns, "a foreign SNI reached the edge")
    with_gw(body)()


@row("literal IPv4 in CONNECT, every inet_aton spelling")
def _():
    def body(g):
        for t in (b"1.2.3.4:443", b"0177.0.0.1:443", b"0x7f.0x0.0x0.0x1:443",
                  b"0x7f.1:443", b"2130706433:443", b"0x7f000001:443"):
            r = refused_before_200(g, t, 403, "policy")
            # In open mode no allowlist refuses first: the literal rule does.
            check("is not a name the allowlist can hold" in r.reason, "%r: %r" % (t, r.reason))
            check("cleat egress allow" not in r.body.decode(), "%r: the body offers an allow" % t)
    with_gw(body, mode="open", hosts=())()


@row("bracketed IPv6 in CONNECT")
def _():
    def body(g):
        for t in (b"[::1]:443", b"[::ffff:127.0.0.1]:443", b"[2001:db8::1]:443"):
            refused_before_200(g, t, 403, "policy")
        # Brackets do not excuse a malformed authority.
        for t in (b"[::1]", b"[::1]:", b"[::1]:0443", b"[::1]:44a", b"[:443", b"[]:443"):
            refused_before_200(g, t, 400)
    with_gw(body, mode="open", hosts=())()


PRIVATE = ["10.0.0.5", "127.0.0.1", "169.254.169.254", "100.64.0.1", "172.16.0.1",
           "192.168.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "198.51.100.7",
           "192.0.2.1", "203.0.113.9", "198.18.0.1", "240.0.0.1", "192.0.0.8",
           "192.88.99.1",
           # The last and a middle address of every block, so narrowing a
           # block fails a row rather than only moving its first address.
           "10.255.255.255", "127.255.255.254", "169.254.255.254", "100.127.255.255",
           "172.17.0.1", "172.31.255.255", "192.168.255.255", "198.19.255.255",
           "192.0.0.255", "192.0.2.255", "198.51.100.255", "203.0.113.255",
           "192.88.99.255", "239.255.255.255", "224.0.0.251", "255.255.255.254",
           "0.255.255.255",
           "!::ffff:127.0.0.1", "!::ffff:10.0.0.5", "!::1", "!2001:db8::1",
           "!64:ff9b::7f00:1", "!2002:7f00:1::", "!fe80::1"]

# Just outside each block: these are ordinary public addresses and must dial.
PUBLIC_EDGES = ["9.255.255.255", "11.0.0.0", "100.63.255.255", "100.128.0.0",
                "126.255.255.255", "128.0.0.0", "169.253.255.255", "169.255.0.0",
                "172.15.255.255", "172.32.0.0", "192.0.1.0", "192.0.3.0",
                "192.88.98.255", "192.88.100.0", "192.167.255.255", "192.169.0.0",
                "198.17.255.255", "198.20.0.0", "198.51.99.255", "198.51.101.0",
                "203.0.112.255", "203.0.114.0", "223.255.255.255", "1.0.0.0"]


@row("allowed host resolved to a private or special address is refused after resolve")
def _():
    names = ["p%02d.example" % i for i in range(len(PRIVATE))] + ["mixed.example"]
    fixture = {n: [a] for n, a in zip(names, PRIVATE)}
    fixture["mixed.example"] = [[PUB, "10.0.0.5"]]

    def body(g):
        for n in names:
            s = open_ok(g, n.encode() + b":443")
            s.sendall(rec(0x16, client_hello(sni=n.encode())))
            expect_alert(s)
            expect_row(g, "address", host=n)
        for a, e in g.edges.items():
            if a != PUB:
                check(not e.conns, "the listener at %s saw a connection" % a)
    with_gw(body, hosts=[n.encode() for n in names], fixture=fixture)()


@row("an address just outside every hard-deny block is dialled")
def _():
    names = ["e%02d.example" % i for i in range(len(PUBLIC_EDGES))]
    fixture = {n: [a] for n, a in zip(names, PUBLIC_EDGES)}

    def body(g):
        for n, a in zip(names, PUBLIC_EDGES):
            s = open_ok(g, n.encode() + b":443")
            data = rec(0x16, client_hello(sni=n.encode()))
            s.sendall(data)
            check(g.edges[a].wait_bytes(len(data)) == data, "%s (%s) was not dialled" % (n, a))
            s.close()
    with_gw(body, hosts=[n.encode() for n in names], fixture=fixture)()


@row("the resolver is asked for IPv4 only and an IPv6-only name is refused")
def _():
    def body(g):
        s = open_ok(g, b"v6only.example:443")
        s.sendall(rec(0x16, client_hello(sni=b"v6only.example")))
        expect_alert(s, ALERT_IE)
        expect_row(g, "upstream", host="v6only.example")
        check(g.lookups() == ["v6only.example. %d" % socket.AF_INET],
              "the lookup was not one AF_INET query: %r" % g.lookups())
        check(not g.edges["2001:4860::1"].conns, "an IPv6 answer was dialled")
    with_gw(body, hosts=(b"v6only.example",), fixture={"v6only.example": ["2001:4860::1"]})()


@row("a getpeername that fails after connect is upstream, not a security event")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()))
        expect_alert(s, ALERT_IE)
        expect_row(g, "upstream")
    with_gw(body, peers={PUB: "!reset"})()


@row("concurrent first uses of one name share a single lookup")
def _():
    def body(g):
        socks = [open_ok(g) for _ in range(10)]
        data = [rec(0x16, client_hello()) for _ in socks]
        for s, d in zip(socks, data):
            s.sendall(d)
        end = time.time() + 5
        while time.time() < end and len(g.edges[PUB].conns) < 10:
            time.sleep(0.05)
        check(len(g.edges[PUB].conns) == 10, "only %d tunnels established" % len(g.edges[PUB].conns))
        check(len(g.lookups()) == 1, "%d lookups for one name" % len(g.lookups()))
    with_gw(body, fixture={"allowed.example": [["~1", PUB]]})()


@row("getpeername reading back a forbidden address refuses the tunnel")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()))
        expect_alert(s)
        expect_row(g, "address")
    with_gw(body, peers={PUB: "127.0.0.1"})()


@row("rebinding: one lookup between classification and dial")
def _():
    def body(g):
        established(g)
        check(len(g.lookups()) == 1, "%d lookups for one tunnel" % len(g.lookups()))
        check(not g.edges["10.0.0.5"].conns, "the private listener saw a connection")
    with_gw(body, fixture={"allowed.example": [PUB, "10.0.0.5"]})()


GREASE_EXTS = (ext(0x0a0a, b""), ext(0x2a2a, b"\x00"),
               ext(0x000a, u16(6) + u16(0x3a3a) + u16(0x001d) + u16(0x0017)))


@row("GREASE extension, cipher and group establish")
def _():
    ch = client_hello(extra=GREASE_EXTS, ciphers=(0x1a1a, 0x1301, 0x1302),
                      front=(ext(0xdada, b""),))
    with_gw(lambda g: established(g, hello=ch))()


@row("unknown extension type with a valid length is skipped")
def _():
    with_gw(lambda g: established(g, hello=client_hello(extra=(ext(0x9a9a, b"\x01\x02\x03\x04"),))))()


ECH = ext(0xfe0d, b"\x00\x00\x01\x00\x01\x42\x00\x20" + os.urandom(32) + u16(64) + os.urandom(64))


@row("extension 65037 with a matching outer SNI")
def _():
    with_gw(lambda g: established(g, hello=client_hello(extra=(ECH,))))()


@row("extension 65037 with an absent outer SNI")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello(sni=None, extra=(ECH,))))
        expect_alert(s)
        expect_row(g, "sni", "no-sni")
    with_gw(body)()


@row("extension 65037 with a mismatched outer SNI")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello(sni=OTHER, extra=(ECH,))))
        expect_alert(s)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
    with_gw(body)()


@row("extension 64768 present is not a refusal on its own")
def _():
    with_gw(lambda g: established(g, hello=client_hello(extra=(ext(0xfd00, b"\x02\x00\x0a"),))))()


@row("change_cipher_spec in either direction is skipped")
def _():
    def body(g):
        e = g.edges[PUB]
        ch = rec(0x16, client_hello())
        e.script.append((len(ch), CCS))
        s = open_ok(g)
        s.sendall(ch)
        data, _ = recv_all(s, 1)
        check(data == CCS, "the edge's change_cipher_spec did not reach the client")
        tail = CCS + app(100)
        s.sendall(tail)
        check(e.wait_bytes(len(ch) + len(tail)) == ch + tail, "edge bytes differ")
        expect_no_alert(s)
    with_gw(body)()


def _second_hello_split(interleave):
    def body(g):
        s = open_ok(g)
        ch1 = rec(0x16, client_hello())
        s.sendall(ch1)
        e = g.edges[PUB]
        e.wait_bytes(len(ch1))
        ch2 = client_hello(sni=OTHER)
        cut = len(ch2) // 2
        a, b = rec(0x16, ch2[:cut]), rec(0x16, ch2[cut:])
        s.sendall(a + interleave + b)
        expect_alert(s)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
        got = e.data()
        check(got == ch1 + a + interleave, "the record completing the foreign hello reached the edge")
    with_gw(body)()


@row("foreign second ClientHello split around a change_cipher_spec")
def _():
    _second_hello_split(CCS)


@row("foreign second ClientHello split around an application_data record")
def _():
    _second_hello_split(app(40))


def _tls12(first):
    def body(g):
        s = open_ok(g)
        e = g.edges[PUB]
        ch = rec(0x16, client_hello())
        cke = rec(0x16, b"\x10" + (33).to_bytes(3, "big") + b"\x20" + os.urandom(32), b"\x03\x03")
        fin = rec(0x16, bytes([first]) + os.urandom(39), b"\x03\x03")
        flow = ch + cke + CCS + fin + app(300) + app(16384) + app(7)
        s.sendall(flow)
        check(e.wait_bytes(len(flow)) == flow, "edge bytes differ")
        expect_no_alert(s)
    with_gw(body)()


@row("TLS 1.2 encrypted Finished as a 0x16 record after change_cipher_spec survives")
def _():
    _tls12(0x14)
    _tls12(0x01)        # a phantom partial the reset keeps
    _tls12(0x00)


def _hrr(sni2, early=False):
    def body(g):
        e = g.edges[PUB]
        ch1 = rec(0x16, client_hello(extra=(ext(0x002a, b""),) if early else ()))
        pre = ch1 + (CCS + app(33) if early else b"")
        hrr = rec(0x16, b"\x02" + (84).to_bytes(3, "big") + b"\x03\x03" + bytes.fromhex(
            "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c") + os.urandom(50),
            b"\x03\x03")
        e.script.append((len(pre), hrr + CCS))
        s = open_ok(g)
        s.sendall(pre)
        data, _ = recv_all(s, 1)
        check(data == hrr + CCS, "the retry request did not reach the client")
        ch2 = (b"" if early else CCS) + rec(0x16, client_hello(sni=sni2))
        s.sendall(ch2)
        if sni2 == ALLOWED:
            check(e.wait_bytes(len(pre + ch2)) == pre + ch2, "edge bytes differ")
            expect_no_alert(s)
        else:
            expect_alert(s)
            expect_row(g, "sni", "sni-mismatch", host=sni2.decode())
            got = e.data()
            want = pre + (b"" if early else CCS)
            check(got == want, "the foreign second ClientHello reached the edge")
    with_gw(body)()


@row("HelloRetryRequest, second ClientHello carrying the CONNECT SNI")
def _():
    _hrr(ALLOWED)


@row("HelloRetryRequest, second ClientHello carrying a different SNI")
def _():
    _hrr(OTHER)


@row("application_data before the handshake completes, then a ClientHello")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()) + app(20) + rec(0x16, client_hello(sni=OTHER)))
        expect_alert(s)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
    with_gw(body)()


@row("0-RTT early data between the two ClientHellos, identical SNI")
def _():
    _hrr(ALLOWED, early=True)


@row("0-RTT early data before a second ClientHello carrying a foreign SNI")
def _():
    _hrr(OTHER, early=True)


@row("a third ClientHello in one tunnel is handshake-flood")
def _():
    def body(g):
        s = open_ok(g)
        a, b, c = (rec(0x16, client_hello()) for _ in range(3))
        s.sendall(a + CCS + b + c)
        expect_alert(s)
        expect_row(g, "handshake-flood")
        check(g.edges[PUB].data() == a + CCS + b, "the third hello reached the edge")
    with_gw(body)()


@row("client bytes before the first application_data over 16 KiB")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()))
        cert = rec(0x16, b"\x0b" + (4000).to_bytes(3, "big") + os.urandom(4000))
        s.sendall(cert * 5)
        expect_alert(s)
        expect_row(g, "handshake-flood")
    with_gw(body)()


@row("two hundred application_data records after the handshake pass unparsed")
def _():
    def body(g):
        s = open_ok(g)
        flow = rec(0x16, client_hello())
        rnd = random.Random(7)
        for i in range(200):
            if i == 50:
                # A foreign hello inside application_data is opaque, never parsed.
                flow += rec(0x17, rec(0x16, client_hello(sni=OTHER)))
            flow += app(rnd.choice((1, 64, 512, 4096, 16384)))
        s.sendall(flow)
        check(g.edges[PUB].wait_bytes(len(flow), timeout=10) == flow, "edge bytes differ")
        expect_no_alert(s)
    with_gw(body)()


def _refused_hello(g, data, code, sub="-", **kw):
    s = open_ok(g)
    s.sendall(data)
    expect_alert(s)
    expect_row(g, code, sub, **kw)
    check(not g.edges[PUB].conns, "a refused first hello reached the edge")


@row("two SNI extensions in one record")
def _():
    with_gw(lambda g: _refused_hello(
        g, rec(0x16, client_hello(extra=(sni_ext(ALLOWED),))), "sni", "dup-sni"))()


@row("two SNI extensions across two records of one handshake")
def _():
    ch = client_hello(extra=(sni_ext(ALLOWED),))
    with_gw(lambda g: _refused_hello(g, hs_records(ch, len(ch) - 10), "sni", "dup-sni"))()


@row("two names inside one server_name extension")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, client_hello(
        sni=None, front=(sni_ext(ALLOWED, ALLOWED),))), "sni", "dup-sni"))()


@row("no SNI")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, client_hello(sni=None)), "sni", "no-sni"))()


@row("zero-length SNI")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, client_hello(sni=b"")), "sni", "no-sni"))()


@row("SNI name_type other than host_name")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, client_hello(
        sni=None, front=(sni_ext(ALLOWED, name_type=1),))), "sni", "bad-clienthello"))()


@row("first client byte not 0x16")
def _():
    with_gw(lambda g: _refused_hello(g, b"GET / HTTP/1.1\r\nHost: allowed.example\r\n\r\n",
                                     "sni", "bad-clienthello"))()
    with_gw(lambda g: _refused_hello(g, app(10), "sni", "bad-clienthello"))()


@row("first handshake message a client_key_exchange")
def _():
    with_gw(lambda g: _refused_hello(
        g, rec(0x16, b"\x10\x00\x00\x21\x20" + os.urandom(32)), "sni", "bad-clienthello"))()


@row("record length field of 20000, no resynchronisation")
def _():
    def body(g):
        s = open_ok(g)
        t0 = time.time()
        s.sendall(b"\x16\x03\x01\x4e\x20" + os.urandom(100))
        expect_alert(s)
        check(time.time() - t0 < 2, "the gateway waited for the oversized record")
        expect_row(g, "sni", "bad-clienthello")
    with_gw(body)()


@row("record type outside the four it handles")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, client_hello())[:0] + rec(0x18, b"\x00" * 8),
                                     "sni", "bad-clienthello"))()
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()) + rec(0x18, b"\x00" * 8))
        expect_alert(s)
        expect_row(g, "sni", "bad-clienthello")
    with_gw(body)()


def _overrun_hello():
    ch = bytearray(client_hello(extra=(ext(0x9a9a, b"\x00" * 10),)))
    # Rewrite the last extension's own length to 100 with 10 bytes present.
    ch[-12:-10] = u16(100)
    return bytes(ch)


@row("extension length longer than the remaining buffer")
def _():
    with_gw(lambda g: _refused_hello(g, rec(0x16, _overrun_hello()), "sni", "bad-clienthello"))()


@row("session id length 0xff with a 40-byte hello")
def _():
    body40 = b"\x03\x03" + os.urandom(32) + b"\xff" + os.urandom(5)
    with_gw(lambda g: _refused_hello(
        g, rec(0x16, b"\x01" + len(body40).to_bytes(3, "big") + body40), "sni", "bad-clienthello"))()


@row("ClientHello larger than 16 KiB")
def _():
    ch = client_hello(extra=(ext(0x0015, b"\x00" * 17000),))
    with_gw(lambda g: _refused_hello(g, hs_records(ch, 16000), "handshake-flood"))()


@row("partial hello held behind application_data past 16 KiB")
def _():
    def body(g):
        s = open_ok(g)
        ch = client_hello()
        s.sendall(rec(0x16, ch[:40]))
        for _ in range(5):
            s.sendall(app(4000))
        expect_alert(s)
        expect_row(g, "handshake-flood")
        check(not g.edges[PUB].conns, "held records reached the edge")
    with_gw(body)()


@row("oversized CONNECT head, request line or header count closes with no response")
def _():
    def body(g):
        for raw in (b"CONNECT allowed.example:443 HTTP/1.1\r\n" + b"X-Pad: " + b"a" * 9000 + b"\r\n\r\n",
                    b"CONNECT " + b"a" * 1100 + b".example:443 HTTP/1.1\r\n\r\n",
                    b"CONNECT allowed.example:443 HTTP/1.1\r\n" + b"X-A: 1\r\n" * 65 + b"\r\n"):
            s = g.connect()
            s.sendall(raw)
            data, eof = recv_all(s, 6)
            check(data == b"" and eof, "an oversized head got a response: %r" % data[:60])
        check(g.rows() == [], "an oversized head wrote a row")
        check(g.stderr().count("closed a CONNECT head with no response (cap)") == 3,
              "not every capped head reached the container log")
        # tunnel() sends a Host line, so 63 more make exactly 64 header lines.
        s, r = tunnel(g, ALLOWED + b":443",
                      headers=b"".join(b"X-%d: 1\r\n" % i for i in range(63)))
        check(r is not None and r.status == 200, "64 header lines is within the cap")
        s, r = tunnel(g, ALLOWED + b":443",
                      headers=b"".join(b"X-%d: 1\r\n" % i for i in range(64)))
        check(r is None, "65 header lines got a response")
    with_gw(body)()


@row("client closes after the 200 with no ClientHello")
def _():
    def body(g):
        s = open_ok(g)
        s.shutdown(socket.SHUT_WR)
        expect_alert(s)
        expect_row(g, "sni", "no-clienthello")
    with_gw(body)()


@row("client sends nothing after the 200 and does not close", slow=True)
def _():
    def body(g):
        s = open_ok(g)
        t0 = time.time()
        expect_alert(s, timeout=12)
        el = time.time() - t0
        check(4.5 <= el <= 6.5, "refused after %.1f s, wanted about 5" % el)
        expect_row(g, "sni", "handshake-timeout")
    with_gw(body)()


@row("slow ClientHello, one byte every five seconds, is reaped", slow=True)
def _():
    def body(g):
        s = open_ok(g)
        data = rec(0x16, client_hello())
        t0 = time.time()
        for b in data:
            if time.time() - t0 > 30:
                break
            try:
                s.sendall(bytes([b]))
            except OSError:
                break
            r, _, _ = select.select([s], [], [], 5)
            if r:
                break
        got, _ = recv_all(s, 2)
        el = time.time() - t0
        check(got == ALERT_AD, "wanted the alert, got %r" % got[:20])
        check(19 <= el <= 22, "reaped after %.1f s, wanted about 20" % el)
        expect_row(g, "sni", "handshake-timeout")
    with_gw(body)()


@row("handshake length longer than the record, nothing follows", slow=True)
def _():
    def body(g):
        s = open_ok(g)
        ch = client_hello()
        s.sendall(rec(0x16, ch[:100]))
        t0 = time.time()
        got, _ = recv_all(s, 30)
        el = time.time() - t0
        check(got == ALERT_AD, "wanted the alert, got %r" % got[:20])
        check(19.5 <= el <= 21.5, "refused after %.1f s, wanted about 20" % el)
        expect_row(g, "sni", "handshake-timeout")
    with_gw(body)()


@row("an incomplete CONNECT head is closed at 5 s with no response", slow=True)
def _():
    def body(g):
        for raw in (b"CONNECT allowed.example:443 HTTP/1.1\r\n",
                    b"CONNECT allowed.example:443 HTTP/1.1\n\n"):
            s = g.connect()
            s.sendall(raw)
            t0 = time.time()
            data, eof = recv_all(s, 12)
            el = time.time() - t0
            check(data == b"" and eof, "an incomplete head got %r" % data[:40])
            check(4.5 <= el <= 6.5, "closed after %.1f s, wanted about 5" % el)
        check(g.rows() == [], "an incomplete head wrote a row")
    with_gw(body)()


@row("concurrent tunnel cap exceeded gives an explicit 429")
def _():
    def body(g):
        held = [established(g, hello=client_hello(), edge=PUB) if i == 0 else open_ok(g)
                for i in range(3)]
        before = len(g.rows())
        s, r = tunnel(g, ALLOWED + b":443")
        check(r is not None and r.status == 429, "wanted 429 past the cap")
        check("x-cleat-reason" not in r.headers, "a 429 carried X-Cleat-Reason")
        check(r.body.decode().split("\n")[0] == r.reason + ".", "429 status and body drifted")
        check(int(r.headers["content-length"]) == len(r.body), "429 Content-Length is wrong")
        check(len(g.rows()) == before, "a 429 wrote a row")
        check("answered a tunnel past the cap of 3 with 429" in g.stderr(), "the 429 is not in the container log")
        s2, r2 = tunnel(g, SELFTEST + b":443")
        check(r2 is not None and r2.status == 200, "the self-test counted against the cap")
        held[1].close()
        time.sleep(0.3)
        open_ok(g)
    with_gw(body, max_tunnels=3)()


@row("port 80 and port 8443 are refused")
def _():
    def body(g):
        for t, p in ((b"allowed.example:80", 80), (b"allowed.example:8443", 8443),
                     (b"allowed.example:0", 0), (b"allowed.example:65536", 65536)):
            refused_before_200(g, t, 403, "port")
            check(g.last_row()["port"] == str(p), "row port %s, wanted %d" % (g.last_row()["port"], p))
    with_gw(body)()


@row("allowed host resolved once inside the cache lifetime, again after it", slow=True)
def _():
    def body(g):
        t0 = time.time()
        for _ in range(5):
            established(g, edge=PUB).close()
            g.edges[PUB].conns.clear()
        check(len(g.lookups()) == 1, "%d lookups inside the lifetime" % len(g.lookups()))
        time.sleep(max(0, 57 - (time.time() - t0)))
        established(g, edge=PUB).close()
        g.edges[PUB].conns.clear()
        check(len(g.lookups()) == 1, "the cache expired before 57 s")
        time.sleep(max(0, 61.5 - (time.time() - t0)))
        established(g, edge=PUB)
        check(len(g.lookups()) == 2, "the cache outlived 61 s")
    with_gw(body)()


@row("denied host is never resolved")
def _():
    def body(g):
        refused_before_200(g, b"notallowed.example:443", 403, "policy")
        refused_before_200(g, b"sub.allowed.example:443", 403, "policy")
        # Not only before the 403: a lookup started after it counts too.
        time.sleep(0.5)
        check(g.lookups() == [], "a denied host reached the resolver")
    with_gw(body, fixture={"allowed.example": [PUB], "notallowed.example": [PUB2]})()


@row("empty resolver fixture still denies and still answers the self-test")
def _():
    def body(g):
        refused_before_200(g, b"notallowed.example:443", 403, "policy")
        s, r = tunnel(g, SELFTEST + b":443")
        check(r is not None and r.status == 200, "the self-test failed with no resolver")
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()))
        expect_alert(s, ALERT_IE)
        expect_row(g, "upstream")
    with_gw(body, fixture={})()


@row("shipped entry point refuses the resolver fixture flag")
def _():
    for flag in ("--resolver-fixture", "--upstream-map"):
        p = subprocess.run([sys.executable, SOURCE, flag, "/tmp/x"], capture_output=True,
                           text=True, timeout=10)
        check(p.returncode == 2, "%s: rc %d, wanted 2" % (flag, p.returncode))
        check(flag in p.stderr, "%s: the refusal does not name the flag" % flag)


@row("reserved self-test target answers 200, dials nothing, is not a tunnel")
def _():
    def body(g):
        s, r = tunnel(g, SELFTEST + b":443")
        check(r is not None and r.status == 200, "the self-test target was not answered")
        data, eof = recv_all(s, 2)
        check(eof and data == b"", "the self-test tunnel was not closed")
        check(g.lookups() == [], "the self-test reached the resolver")
        check(g.admin("counts") == "ok counts 0 0", "the self-test was counted: " + g.admin("counts"))
        refused_before_200(g, SELFTEST + b":80", 403, "port")
    with_gw(body)()


@row("self-test request with Cleat-Selftest: 1 leaves last_shim_seen alone")
def _():
    def body(g):
        check(g.admin("last_shim_seen") == "ok last_shim_seen -1", "a fresh gateway saw a shim")
        s, r = tunnel(g, SELFTEST + b":443", headers=b"Cleat-Selftest: 1\r\n")
        check(r.status == 200, "the selftest request was refused")
        check(g.admin("last_shim_seen") == "ok last_shim_seen -1", "the selftest reset the clock")
        tunnel(g, SELFTEST + b":443", headers=b"Cleat-Selftest: 2\r\n")
        check(g.admin("last_shim_seen") == "ok last_shim_seen 0", "a heartbeat did not reset it")
    with_gw(body)()


@row("heartbeat advances the last-seen clock, a pre-ClientHello refusal does not")
def _():
    def body(g):
        tunnel(g, SELFTEST + b":443")
        time.sleep(2.2)
        refused_before_200(g, b"notallowed.example:443", 403, "policy")
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello(sni=OTHER)))
        expect_alert(s)
        age = int(g.admin("last_shim_seen").split()[-1])
        check(age >= 2, "a refusal reset the shim clock (age %d)" % age)
        tunnel(g, SELFTEST + b":443")
        check(g.admin("last_shim_seen") == "ok last_shim_seen 0", "the heartbeat did not reset it")
    with_gw(body)()


@row("SIGTERM exits 0 within five seconds")
def _():
    g = GW()
    try:
        established(g)
        t0 = time.time()
        g.proc.send_signal(signal.SIGTERM)
        rc = g.proc.wait(6)
        check(rc == 0, "exit status %d on SIGTERM" % rc)
        check(time.time() - t0 < 5, "took %.1f s to exit" % (time.time() - t0))
    finally:
        g.stop()


@row("the request line cap is 1 KiB with its CRLF, however the bytes arrive")
def _():
    def body(g):
        def line(n):
            # A request line of exactly n bytes, its CRLF included.
            pad = n - len(b"CONNECT :443 HTTP/1.1\r\n") - len(b".example")
            return b"CONNECT " + b"a" * pad + b".example:443 HTTP/1.1\r\n"
        for n, want in ((1024, 403), (1025, None)):
            raw = line(n) + b"\r\n"
            assert len(line(n)) == n
            for chunks in ([raw], [raw[:1023], raw[1023:]], [raw[:1022], raw[1022:]],
                           [bytes([b]) for b in raw[:1030]] + [raw[1030:]]):
                s = g.connect()
                for c in chunks:
                    s.sendall(c)
                r = read_response(s)
                got = None if r is None else r.status
                check(got == want, "%d-byte request line in %d chunks: got %s, wanted %s" % (
                    n, len(chunks), got, want))
                s.close()
        # A line that can no longer fit is closed at once, not at the deadline.
        s = g.connect()
        s.sendall(b"CONNECT " + b"a" * 1100)
        t0 = time.time()
        data, eof = recv_all(s, 6)
        check(eof and data == b"", "an overlong request line got %r" % data[:40])
        check(time.time() - t0 < 1, "an overlong request line waited %.1f s" % (time.time() - t0))
    with_gw(body)()


@row("a restarted gateway starts a new log generation over the same log")
def _():
    def body(g):
        refused_before_200(g, b"notallowed.example:443", 403, "policy")
        gen1 = g.admin("log-state").split()[2]
        g.restart()
        gen2, size = g.admin("log-state").split()[2:]
        check(gen1 != gen2, "the generation repeated across a restart")
        check(int(size) > 0 and len(g.rows()) == 1, "the restart lost the log")
    with_gw(body)()


@row("SIGTERM exits within five seconds while a lookup is in flight")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()))
        time.sleep(0.5)          # the gateway is now inside the 10 s lookup
        t0 = time.time()
        g.proc.send_signal(signal.SIGTERM)
        rc = g.proc.wait(8)
        check(rc == 0, "exit status %d" % rc)
        check(time.time() - t0 < 5, "took %.1f s with a lookup in flight" % (time.time() - t0))
    with_gw(body, fixture={"allowed.example": [["~10", PUB]]})()


@row("a policy that nests past the parser's depth is refused, never a crash")
def _():
    deep = "[" * 200000 + "]" * 200000

    def body(g):
        g.write_policy(deep)
        check(g.admin("reload") == "err reload parse", "a deep document was not refused as parse")
        check(g.admin("policy-digest").startswith("ok policy-digest v1:"), "the gateway stopped answering")
        g.allow_errors = True     # the refusal is logged on stderr by design
        check("Traceback" not in g.stderr(), "the reload printed a traceback")
    with_gw(body)()
    g = GW(start=False, policy_text=deep)
    try:
        g.start(wait=False)
        rc = g.proc.wait(10)
        check(rc != 0 and "refusing to start" in g.stderr(), "a deep document started a gateway")
        check("Traceback" not in g.stderr(), "start printed a traceback")
    finally:
        g.stop()


@row("a FIFO at the policy path cannot freeze a reload")
def _():
    def body(g):
        os.unlink(g.policy_path)
        os.mkfifo(g.policy_path)
        t0 = time.time()
        check(g.admin("reload", timeout=3) == "err reload parse", "a FIFO policy was not refused")
        check(time.time() - t0 < 2, "the reload waited on the FIFO")
        check(g.admin("policy-digest").startswith("ok policy-digest"), "the gateway froze")
        g.allow_errors = True
    with_gw(body)()


@row("before the first hello only a hello may be in flight")
def _():
    def body(g):
        # A non-hello first message, then application_data before it completes.
        s = open_ok(g)
        s.sendall(rec(0x16, b"\x10\x00\x00\x40" + b"\x00" * 8) + app(20))
        expect_alert(s)
        expect_row(g, "sni", "bad-clienthello")
        # A non-hello first message that never completes is refused on its
        # type byte, not left to wait for the deadline or the close.
        s = open_ok(g)
        s.sendall(rec(0x16, b"\x10\x00\x00\x40" + b"\x00" * 8))
        s.shutdown(socket.SHUT_WR)
        expect_alert(s)
        expect_row(g, "sni", "bad-clienthello")
        # An empty handshake record, then records that are not a hello.
        for tail in (app(20), CCS):
            s = open_ok(g)
            s.sendall(rec(0x16, b"") + tail)
            expect_alert(s)
            expect_row(g, "sni", "bad-clienthello")
        check(not g.edges[PUB].conns, "a record ahead of the first hello reached the edge")
        # A first hello split around a change_cipher_spec is still fine.
        s = open_ok(g)
        ch = client_hello()
        data = rec(0x16, ch[:60]) + CCS + rec(0x16, ch[60:])
        s.sendall(data)
        check(g.edges[PUB].wait_bytes(len(data)) == data, "a split first hello did not establish")
        expect_no_alert(s)
    with_gw(body)()


@row("more than 16 KiB held in reassembly after the budget stops is handshake-flood")
def _():
    def body(g):
        s = open_ok(g)
        s.sendall(rec(0x16, client_hello()) + app(100))
        g.edges[PUB].wait_bytes(1)
        partial = b"\x0b" + (20000).to_bytes(3, "big") + os.urandom(9000)
        s.sendall(rec(0x16, partial) + rec(0x16, os.urandom(8000)))
        expect_alert(s)
        expect_row(g, "handshake-flood")
    with_gw(body)()


@row("neither handshake deadline applies once the first hello is validated", slow=True)
def _():
    def body(g):
        s = established(g)
        e = g.edges[PUB]
        before = len(e.conns[0].data)
        time.sleep(6.5)          # past the 5 s first-byte and the 2 s hello deadline
        tail = app(500)
        s.sendall(tail)
        got = e.wait_bytes(before + len(tail))
        check(got.endswith(tail), "an idle established tunnel was reaped")
        expect_no_alert(s)
    with_gw(body, handshake_timeout_s=2)()


@row("a refusal after the upstream closed its half still logs and closes")
def _():
    def body(g):
        e = g.edges[PUB]
        s = open_ok(g)
        ch1 = rec(0x16, client_hello())
        s.sendall(ch1)
        e.wait_bytes(len(ch1))
        e.conns[0].sock.shutdown(socket.SHUT_WR)
        data, eof = recv_all(s, 2)
        check(eof, "the upstream half-close did not reach the client")
        s.sendall(rec(0x16, client_hello(sni=OTHER)))
        time.sleep(0.5)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
    with_gw(body)()


# -- section 9.1, the denial response, byte for byte ------------------------

@row("a policy denial's body bytes match the status text")
def _():
    def body(g):
        r = refused_before_200(g, b"registry.npmjs.org:443", 403, "policy")
        text = r.body.decode()
        check(text.split("\n")[0] == r.reason + ".", "status and body drifted")
        check(int(r.headers["content-length"]) == len(r.body), "Content-Length is wrong")
        check(len(r.body) == 206, "the section 9.1 example body is 206 bytes, got %d" % len(r.body))
        check(r.headers.get("connection") == "close", "no Connection: close")
        check("cleat egress allow registry.npmjs.org" in text, "the body does not name the fix")
    with_gw(body)()


@row("a 128-byte-truncated target appears identically in the status line and the body")
def _():
    def body(g):
        host = b".".join([b"a" * 60, b"b" * 60, b"c" * 60, b"example"])
        r = refused_before_200(g, host + b":443", 403, "policy")
        target = host[:128].decode()
        check(r.reason == "cleat egress: %s is not on the allowlist" % target, "status target differs")
        check(r.body.decode().split("\n")[0] == r.reason + ".", "body target differs")
        check(g.last_row()["host"] == target and g.last_row()["trunc"] == "1", "row target differs")
        # The cut name is never offered as the one to allow.
        check("cleat egress allow " + target[:10] not in r.body.decode(), "the body offers a cut name")
        check("cut to 128 bytes" in r.body.decode(), "the body does not say the name was cut")
    with_gw(body)()


@row("a malformed CONNECT head writes no row and sends no reason header")
def _():
    def body(g):
        heads = [
            b"connect allowed.example:443 HTTP/1.1\r\n\r\n",
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
            b"GET http://allowed.example/ HTTP/1.1\r\n\r\n",
            b"CONNECT  allowed.example:443 HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:443  HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1 \r\n\r\n",
            b"CONNECT\tallowed.example:443 HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:0443 HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:44a HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:443443 HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:443:443 HTTP/1.1\r\n\r\n",
            b"CONNECT :443 HTTP/1.1\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/2.0\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\nX-A: \x00\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\nno colon\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\n: empty name\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\nX\rA: 1\r\n\r\n",
            b"CONNECT allowed.example:443 HTTP/1.1\r\nX-A: \xff\r\n\r\n",
        ]
        for h in heads:
            s, r = tunnel(g, None, raw=h)
            check(r is not None and r.status == 400, "%r: wanted 400, got %s" % (
                h[:40], None if r is None else r.status))
            check("x-cleat-reason" not in r.headers, "%r: 400 carried X-Cleat-Reason" % h[:40])
            check(r.body.decode().split("\n")[0] == r.reason + ".", "%r: 400 body drifted" % h[:40])
        check(g.rows() == [], "a malformed head wrote a row")
        check(g.lookups() == [], "a malformed head reached the resolver")
        check(g.stderr().count("answered a malformed CONNECT head with 400") == len(heads),
              "not every 400 reached the container log")
    with_gw(body)()


# -- the admin socket and the policy -----------------------------------------

@row("reload answers the new digest, keeps the old policy on a bad document")
def _():
    def body(g):
        d0 = policy_digest("strict", 443, ["allowed.example"])
        check(g.admin("policy-digest") == "ok policy-digest " + d0, "wrong starting digest")
        check(g.admin("match", "new.example") == "ok match deny policy", "match before reload")
        g.write_policy(policy_doc(hosts=(ALLOWED, b"new.example")))
        d1 = policy_digest("strict", 443, ["allowed.example", "new.example"])
        check(g.admin("reload") == "ok reload " + d1, "reload did not answer the new digest")
        check(g.admin("match", "new.example") == "ok match allow", "the reload did not apply")
        bad = [
            (policy_doc(hosts=(ALLOWED,), digest="v1:0000000000000000"), "digest"),
            (policy_doc(mode="open", digest=d1), "digest"),
            ("{not json", "parse"),
            (policy_doc().replace('"v": 1', '"v": 2'), "parse"),
            (policy_doc().replace('"v": 1', '"v": true'), "parse"),
            (policy_doc().replace('"mode": "strict"', '"mode": "off"'), "parse"),
            (policy_doc().replace('"port": 443', '"port": 80'), "parse"),
            (policy_doc(hosts=(b"b.example", b"a.example")).replace(
                '"a.example",\n    "b.example"', '"b.example",\n    "a.example"'), "parse"),
            (policy_doc(hosts=(b"a.example",)).replace('"a.example"', '"A.example"'), "parse"),
            (policy_doc(hosts=(b"a.example",)).replace('"a.example"', '"1.2.3.4"'), "parse"),
            (policy_doc().replace('"max_tunnels"', '"extra": 1,\n  "max_tunnels"'), "parse"),
            (policy_doc().replace('"mode": "strict",', '"mode": "strict",\n  "mode": "open",'), "parse"),
        ]
        for text, code in bad:
            g.write_policy(text)
            got = g.admin("reload")
            check(got == "err reload " + code, "a bad document answered %r, wanted %s" % (got, code))
            check(g.admin("policy-digest") == "ok policy-digest " + d1, "a refused reload changed the policy")
        g.allow_errors = True
    with_gw(body)()


@row("admin verbs answer in the one-line wire form")
def _():
    def body(g):
        established(g)
        refused_before_200(g, b"notallowed.example:443", 403, "policy")
        refused_before_200(g, b"allowed.example:80", 403, "port")
        check(g.admin("counts") == "ok counts 1 2", "counts: " + g.admin("counts"))
        check(g.admin("path_ok") == "ok path_ok true", "path_ok: " + g.admin("path_ok"))
        size = os.path.getsize(g.denials)
        state = g.admin("log-state").split()
        check(state[:2] == ["ok", "log-state"] and state[2].isdigit() and state[3] == str(size),
              "log-state: " + " ".join(state))
        check(g.admin("match", "ALLOWED.example.") == "ok match allow", "match does not normalize")
        check(g.admin("match", "1.2.3.4") == "err match bad-argument", "match took an IP")
        check(g.admin("match") == "err match bad-argument", "match took no argument")
        check(g.admin("frobnicate") == "err frobnicate unknown-verb", "an unknown verb")
        check(g.admin("shim_restarts") == "err shim_restarts unknown-verb", "shim_restarts")
    with_gw(body)()


@row("the denial log is capped in place and its generation moves")
def _():
    def body(g):
        start = int(g.admin("log-state").split()[2])
        for i in range(120):
            s, r = tunnel(g, b"n%03d.example:443" % i)
            s.close()
        check(int(g.admin("log-state").split()[2]) > start, "the generation never moved")
        gen0 = int(g.admin("log-state").split()[2])
        for i in range(120, 240):
            s, r = tunnel(g, b"n%03d.example:443" % i)
            s.close()
        gen, size = g.admin("log-state").split()[2:]
        check(int(gen) - gen0 >= 1, "the generation stuck after the first wrap")
        check(int(size) <= 4096 and int(size) == os.path.getsize(g.denials), "the log outgrew its cap")
        check(os.listdir(g.dir).count("denials.log.1") == 0, "a second log file appeared")
    with_gw(body, denials_max=4096)()


@row("a policy it cannot verify stops the gateway at start")
def _():
    for text in (policy_doc(digest="v1:0123456789abcdef"), "{", "",
                 policy_doc().replace('"v": 1', '"v": 7')):
        g = GW(start=False, policy_text=text)
        try:
            g.start(wait=False)
            rc = g.proc.wait(10)
            check(rc != 0, "a bad policy started a gateway")
            check("refusing to start" in g.stderr(), "the refusal is not named")
        finally:
            g.stop()


@row("path_ok turns false when another socket displaces the proxy socket")
def _():
    def body(g):
        env = dict(os.environ, CLEAT_GW_ADMIN_SOCK=g.admin_path)
        p = subprocess.run([sys.executable, GW_HEALTH], env=env, timeout=10)
        check(p.returncode == 0, "gw-health failed on a healthy gateway")
        os.unlink(g.proxy)
        imp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        imp.bind(g.proxy)
        try:
            check(g.admin("path_ok") == "ok path_ok false", "a displaced socket still reads ok")
            p = subprocess.run([sys.executable, GW_HEALTH], env=env, timeout=10)
            check(p.returncode == 1, "gw-health passed a displaced gateway")
        finally:
            imp.close()
    with_gw(body)()


@row("gw-admin prints the answer and exits 0, 1 or 2")
def _():
    def body(g):
        env = dict(os.environ, CLEAT_GW_ADMIN_SOCK=g.admin_path, CLEAT_GW_PROXY_SOCK=g.proxy)

        def run(*a):
            return subprocess.run([sys.executable, GW_ADMIN] + list(a), env=env,
                                  capture_output=True, text=True, timeout=10)
        p = run("policy-digest")
        check(p.returncode == 0 and p.stdout.startswith("ok policy-digest v1:"), "policy-digest")
        p = run("selftest")
        check(p.returncode == 0 and p.stdout == "ok selftest cleat-egress-ok\n", "selftest")
        check(g.admin("last_shim_seen") == "ok last_shim_seen -1", "selftest reset the shim clock")
        p = run("frobnicate")
        check(p.returncode == 1, "an err answer exited %d" % p.returncode)
        p = run("match", "")
        check(p.returncode == 1 and p.stdout == "err match bad-argument\n", "an empty argument")
        env["CLEAT_GW_ADMIN_SOCK"] = g.admin_path + ".missing"
        p = run("counts")
        check(p.returncode == 2, "no answer exited %d" % p.returncode)
    with_gw(body)()


@row("an allowed connection is recorded on stdout and never in denials.log")
def _():
    def body(g):
        established(g)
        check(re.search(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ allow host=allowed.example port=443 trunc=0$",
                        g.stdout(), re.M), "no allow record on stdout")
        check(not os.path.exists(g.denials) or "allow" not in open(g.denials).read(),
              "an allow row reached denials.log")
    with_gw(body)()


@row("open mode allows any name but keeps the port, literal and SNI rules")
def _():
    def body(g):
        established(g, b"anything.example:443", client_hello(sni=b"anything.example"))
        refused_before_200(g, b"anything.example:80", 403, "port")
        refused_before_200(g, b"1.2.3.4:443", 403, "policy")
        s = open_ok(g, b"anything.example:443")
        s.sendall(rec(0x16, client_hello(sni=OTHER)))
        expect_alert(s)
        expect_row(g, "sni", "sni-mismatch", host="other.example")
        check(g.admin("match", "whatever.example") == "ok match allow", "open mode match")
    with_gw(body, mode="open", hosts=(), fixture={"anything.example": [PUB]})()


@row("normalize_host agrees with the shared hostname table")
def _():
    table = os.path.join(HERE, "..", "fixtures", "egress_hosts.tsv")
    rows = []
    with open(table, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            rows.append((cols[0], cols[1]))
    names = sorted({want for _, want in rows if not want.startswith("!")})

    def body(g):
        bad = []
        for inp, want in rows:
            got = g.admin("match", inp) if inp else g.admin("match")
            ok = got == "ok match allow"
            if want.startswith("!") == ok:
                bad.append("%r: wanted %s, got %r" % (inp, want, got))
        check(not bad, "gateway and host table disagree:\n" + "\n".join(bad))
        check(len(rows) >= 40, "only %d table rows" % len(rows))
    with_gw(body, hosts=[n.encode() for n in names])()


@row("the policy bin/cleat renders is the document the gateway loads, digest for digest")
def _():
    # The host renders policy.json and the gateway recomputes its digest on
    # load and refuses a mismatch, so the two formulas must agree byte for byte.
    # Driven through the shipped shell functions, never a copy of them.
    cli_path = os.path.join(HERE, "..", "..", "bin", "cleat")
    home = tempfile.mkdtemp(prefix="gwcli", dir="/tmp")

    def cli(fn, *args):
        p = subprocess.run(["bash", "-c", 'source "$1"; shift; "$@"', "_", cli_path, fn] + list(args),
                           capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                           env={"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
        check(p.returncode == 0, "%s failed: %s" % (fn, p.stderr.strip()))
        return p.stdout

    table = os.path.join(HERE, "..", "fixtures", "egress_hosts.tsv")
    names = set()
    with open(table, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 1 and cols[1] and not cols[1].startswith("!"):
                names.add(cols[1])
    names = sorted(names)
    rnd = random.Random(20260926)
    cases = [("strict", ["claude.ai", "api.anthropic.com", "claude.ai"]), ("open", ["claude.ai"]),
             ("strict", names)]
    for _ in range(4):
        cases.append((rnd.choice(("strict", "open")), rnd.sample(names, rnd.randint(1, min(9, len(names))))))
    try:
        for mode, hosts in cases:
            hs = "\n".join(hosts)
            doc = cli("_egress_policy_json", mode, hs)
            want = cli("_egress_policy_digest", mode, hs)
            check(want == policy_digest(mode, 443, sorted(set(hosts))),
                  "host digest %s differs from the corpus formula for %s %r" % (want, mode, hosts))
            g = GW(policy_text=doc)
            try:
                got = g.admin("policy-digest")
                check(got == "ok policy-digest " + want, "gateway enforces %r, host rendered %s" % (got, want))
                for h in set(hosts):
                    check(g.admin("match", h) == "ok match allow", "%s not allowed after load" % h)
                if mode == "strict":
                    check(g.admin("match", "not-listed.example") == "ok match deny policy",
                          "an unlisted host was allowed under strict")
            finally:
                g.stop()
        # A reload re-reads the same path and answers the digest it accepted.
        first = cli("_egress_policy_json", "strict", "claude.ai")
        second = cli("_egress_policy_json", "strict", "claude.ai\ndocs.rs")
        want2 = cli("_egress_policy_digest", "strict", "claude.ai\ndocs.rs")
        g = GW(policy_text=first)
        try:
            tmp = g.policy_path + ".new"
            with open(tmp, "w") as f:
                f.write(second)
            os.rename(tmp, g.policy_path)
            check(g.admin("reload") == "ok reload " + want2, "reload did not answer the host's digest")
            check(g.admin("policy-digest") == "ok policy-digest " + want2, "reload did not take")
        finally:
            g.stop()
    finally:
        shutil.rmtree(home, ignore_errors=True)


@row("the audit's address rule in bin/cleat agrees with the gateway's, address for address")
def _():
    # cleat egress audit tells the user whether the gateway would dial the
    # address a name resolved to. That is only true while the two rules agree,
    # so both classify the same addresses: every range edge and its
    # neighbours, the mapped forms, and a seeded random spread.
    import ipaddress
    cli_path = os.path.join(HERE, "..", "..", "bin", "cleat")
    probe = subprocess.run([sys.executable, "-c",
                            "import sys; sys.path.insert(0, sys.argv[1]); import gateway; "
                            "print('\\n'.join('1' if gateway.address_allowed(a) else '0' for a in sys.stdin.read().split()))",
                            os.path.dirname(SOURCE)], input="", capture_output=True, text=True, timeout=60)
    check(probe.returncode == 0, "the gateway module did not import: %s" % probe.stderr.strip())
    addrs = set()
    for net in ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
                "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
                "255.255.255.255/32"):
        n = ipaddress.IPv4Network(net)
        for v in (int(n.network_address) - 1, int(n.network_address), int(n.broadcast_address),
                  int(n.broadcast_address) + 1):
            if 0 <= v < 2 ** 32:
                addrs.add(str(ipaddress.IPv4Address(v)))
    rnd = random.Random(20260926)
    for _ in range(3000):
        addrs.add(str(ipaddress.IPv4Address(rnd.getrandbits(32))))
    for a in list(addrs)[:200]:
        addrs.add("::ffff:" + a)
    addrs.update(("::1", "fd00::1", "2606:4700::1111", "::"))
    order = sorted(addrs)
    gw = subprocess.run([sys.executable, "-c",
                         "import sys; sys.path.insert(0, sys.argv[1]); import gateway; "
                         "print('\\n'.join('1' if gateway.address_allowed(a) else '0' for a in sys.stdin.read().split()))",
                         os.path.dirname(SOURCE)], input="\n".join(order), capture_output=True, text=True, timeout=120)
    check(gw.returncode == 0, "gateway classification failed: %s" % gw.stderr.strip())
    home = tempfile.mkdtemp(prefix="gwaddr", dir="/tmp")
    try:
        cli = subprocess.run(["bash", "-c",
                              'source "$1"; while IFS= read -r a; do '
                              'if _egress_address_special "$a"; then echo 0; else echo 1; fi; done', "_", cli_path],
                             input="\n".join(order) + "\n", capture_output=True, text=True, timeout=300,
                             env={"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    finally:
        shutil.rmtree(home, ignore_errors=True)
    check(cli.returncode == 0, "the CLI classification failed: %s" % cli.stderr.strip())
    g = gw.stdout.split()
    c = cli.stdout.split()
    check(len(g) == len(order) and len(c) == len(order), "answer counts differ")
    bad = ["%s gateway=%s cli=%s" % (a, x, y) for a, x, y in zip(order, g, c) if x != y]
    check(not bad, "the CLI and the gateway disagree on %d addresses:\n%s" % (len(bad), "\n".join(bad[:20])))


# -- the fuzz row ---------------------------------------------------------------

def _mutate(rnd, seed):
    rec_ = bytearray(seed)
    kind = rnd.randrange(3)
    if kind == 0:
        for _ in range(rnd.randint(1, 4)):
            i = rnd.randrange(len(rec_))
            rec_[i] ^= 1 << rnd.randrange(8)
    elif kind == 1:
        offs = [3, 6]
        body = 9
        offs.append(body + 34)
        sid = rec_[body + 34] if len(rec_) > body + 34 else 0
        cs = body + 35 + sid
        offs.append(cs)
        if len(rec_) > cs + 2:
            csl = int.from_bytes(rec_[cs:cs + 2], "big")
            cm = cs + 2 + csl
            offs.append(cm)
            offs.append(cm + 1 + (rec_[cm] if len(rec_) > cm else 0))
        o = rnd.choice(offs)
        width = 1 if o in (body + 34,) else 2
        val = rnd.choice((0, 1, 0xff, 0xffff, rnd.randrange(1 << (8 * width))))
        rec_[o:o + width] = (val & ((1 << (8 * width)) - 1)).to_bytes(width, "big")
    else:
        # Extension-list edit on a parsed hello: drop, duplicate or swap one.
        body = bytes(rec_[9:])
        try:
            sid = body[34]
            p = 35 + sid
            p += 2 + int.from_bytes(body[p:p + 2], "big")
            p += 1 + body[p]
            head, exts_raw = body[:p], body[p + 2:]
            exts = []
            q = 0
            while q + 4 <= len(exts_raw):
                ln = int.from_bytes(exts_raw[q + 2:q + 4], "big")
                exts.append(exts_raw[q:q + 4 + ln])
                q += 4 + ln
            if exts:
                i = rnd.randrange(len(exts))
                op = rnd.randrange(3)
                if op == 0:
                    del exts[i]
                elif op == 1:
                    exts.insert(i, exts[i])
                else:
                    j = rnd.randrange(len(exts))
                    exts[i], exts[j] = exts[j], exts[i]
            eb = b"".join(exts)
            nb = head + u16(len(eb)) + eb
            hs = b"\x01" + len(nb).to_bytes(3, "big") + nb
            rec_ = bytearray(rec(0x16, hs))
        except IndexError:
            pass
    return bytes(rec_)


# An independent reading of sections 4.3b and 4.5, written for this corpus and
# sharing no code with the gateway. The fuzz row holds every case's outcome to
# it, so a gateway that accepts a malformed or foreign hello, or refuses with
# the wrong subcode, fails the row rather than passing as "some reason code".
# It models a client that sends its bytes and then closes, towards a name that
# resolves only to a forbidden address, so every hello the gateway accepts ends
# as `address` and nothing is ever dialled.

def ref_name(raw):
    if not 0 < len(raw) <= 255 or any(b < 33 or b > 126 for b in raw):
        return None
    if any(b in b"/\\?#%@: \t\x00" for b in raw):
        return None
    name = raw.decode("ascii").lower()
    if name.endswith("."):
        name = name[:-1]
    if name.endswith(".") or len(name) > 253 or "." not in name:
        return None
    parts = name.split(".")
    for part in parts:
        if not 1 <= len(part) <= 63 or part[0] == "-" or part[-1] == "-":
            return None
        if any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in part):
            return None
    if parts[-1].isdigit() or parts[-1].startswith("0x"):
        return None
    return name


def ref_hello_exts(body):
    """The extension list of a well-formed hello body, or None."""
    try:
        if body[:2] != b"\x03\x03":
            return None
        at = 34
        n = body[at]; at += 1
        if n > 32:
            return None
        at += n
        n = int.from_bytes(body[at:at + 2], "big"); at += 2
        at += n
        n = body[at]; at += 1
        at += n
        if at > len(body):
            return None
        if at == len(body):
            return []
        n = int.from_bytes(body[at:at + 2], "big"); at += 2
        if at + n != len(body) or len(body[at - 2:at]) != 2:
            return None
        exts = []
        while at < len(body):
            if at + 4 > len(body):
                return None
            t = int.from_bytes(body[at:at + 2], "big")
            n = int.from_bytes(body[at + 2:at + 4], "big")
            at += 4
            if at + n > len(body):
                return None
            exts.append((t, body[at:at + n]))
            at += n
        return exts
    except IndexError:
        return None


def ref_hello_verdict(exts, host):
    """None when the hello names host, else (code, sub)."""
    sni = [d for t, d in exts if t == 0]
    if not sni:
        return ("sni", "no-sni")
    if len(sni) > 1:
        return ("sni", "dup-sni")
    d = sni[0]
    if len(d) < 2 or int.from_bytes(d[:2], "big") != len(d) - 2:
        return ("sni", "bad-clienthello")
    names, at = [], 2
    while at < len(d):
        if at + 3 > len(d):
            return ("sni", "bad-clienthello")
        n = int.from_bytes(d[at + 1:at + 3], "big")
        if at + 3 + n > len(d):
            return ("sni", "bad-clienthello")
        names.append((d[at], d[at + 3:at + 3 + n]))
        at += 3 + n
    if len(names) != 1:
        return ("sni", "dup-sni")
    kind, raw = names[0]
    if not raw:
        return ("sni", "no-sni")
    if kind != 0:
        return ("sni", "bad-clienthello")
    name = ref_name(raw)
    if name is None:
        return ("sni", "bad-clienthello")
    if name != host:
        return ("sni", "sni-mismatch")
    return None


def reference_outcome(data, host):
    """The (code, sub) a gateway must log for this stream, then the client's close."""
    if not data:
        return ("sni", "no-clienthello")
    if data[0] != 0x16:
        return ("sni", "bad-clienthello")
    at, hellos, counting, seen, held = 0, 0, True, 0, 0
    partial = b""
    while True:
        if len(data) - at < 5:
            return ("sni", "no-clienthello")
        rtype, ln = data[at], int.from_bytes(data[at + 3:at + 5], "big")
        if ln > 16640:
            return ("sni", "bad-clienthello")
        if counting:
            seen += 5 + ln
            if seen > 16384:
                return ("handshake-flood", "-")
        if rtype not in (0x14, 0x15, 0x16, 0x17):
            return ("sni", "bad-clienthello")
        if len(data) - at - 5 < ln:
            return ("sni", "no-clienthello")
        frag = data[at + 5:at + 5 + ln]
        at += 5 + ln
        in_flight = partial[:1] == b"\x01"
        if rtype in (0x14, 0x17):
            if hellos == 0 and not in_flight:
                return ("sni", "bad-clienthello")
            if rtype == 0x17:
                counting = False
            if not in_flight:
                partial = b""
        elif rtype == 0x16:
            partial += frag
            if hellos == 0 and partial and partial[0] != 0x01:
                return ("sni", "bad-clienthello")
            while len(partial) >= 4:
                n = int.from_bytes(partial[1:4], "big")
                if len(partial) < 4 + n:
                    break
                mtype, mbody, partial = partial[0], partial[4:4 + n], partial[4 + n:]
                exts = ref_hello_exts(mbody) if mtype == 1 else None
                if exts is None:
                    if hellos == 0:
                        return ("sni", "bad-clienthello")
                    continue
                hellos += 1
                if hellos > 2:
                    return ("handshake-flood", "-")
                verdict = ref_hello_verdict(exts, host)
                if verdict:
                    return verdict
            if len(partial) > 16384:
                return ("handshake-flood", "-")
        if hellos == 0:
            held += 5 + ln
            if held > 16384:
                return ("handshake-flood", "-")
        else:
            return ("address", "-")


@row("the reference validator agrees with the gateway on the corpus's own hellos")
def _():
    # The reference must itself be right before it can judge the fuzz: hold it
    # to hellos whose outcome this corpus already asserts row by row.
    good = rec(0x16, client_hello(sni=b"fuzz.example"))
    cases = [
        (good, ("address", "-")),
        (rec(0x16, client_hello(sni=b"other.example")), ("sni", "sni-mismatch")),
        (rec(0x16, client_hello(sni=None)), ("sni", "no-sni")),
        (rec(0x16, client_hello(sni=b"")), ("sni", "no-sni")),
        (rec(0x16, client_hello(sni=b"fuzz.example", extra=(sni_ext(b"fuzz.example"),))), ("sni", "dup-sni")),
        (rec(0x16, _overrun_hello()), ("sni", "bad-clienthello")),
        (app(10), ("sni", "bad-clienthello")),
        (good[:3], ("sni", "no-clienthello")),
        (b"\x16\x03\x01\x4e\x20", ("sni", "bad-clienthello")),
        (b"", ("sni", "no-clienthello")),
    ]
    for data, want in cases:
        got = reference_outcome(data, "fuzz.example")
        check(got == want, "reference says %s for a case the corpus says is %s" % (got, want))


@row("10,000 ClientHellos mutated from the checked-in fixtures", slow=True)
def _():
    count = int(os.environ.get("CLEAT_GW_FUZZ_COUNT", "10000"))
    rnd = random.Random(20260925)
    seeds = [fixture_hello(n) for n in ("curl", "openssl", "node", "python")]
    cases = []
    for _ in range(count):
        m = _mutate(rnd, rnd.choice(seeds))
        if rnd.random() < 0.3 and len(m) > 10 and m[0] == 0x16:
            cut = rnd.randrange(6, len(m))
            if len(m) > cut:
                m = hs_records(m[5:], cut - 5)
        cases.append(m)
    g = GW(hosts=(b"fuzz.example",), fixture={"fuzz.example": ["10.0.0.9"]},
           denials_max=67108864, max_tunnels=64)
    problems = []
    codes = {}
    try:
        for i, data in enumerate(cases):
            want = reference_outcome(data, "fuzz.example")
            before = len(g.rows()) if i == 0 else n_rows
            s = g.connect(timeout=15)
            try:
                s.sendall(b"CONNECT fuzz.example:443 HTTP/1.1\r\n\r\n")
                r = read_response(s)
                if r is None or r.status != 200:
                    problems.append("case %d: no 200" % i)
                    continue
                try:
                    s.sendall(data)
                    s.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                got, eof = recv_all(s, 15)
            finally:
                s.close()
            rows = g.rows()
            n_rows = len(rows)
            if not eof:
                problems.append("case %d: hang" % i)
            elif n_rows != before + 1:
                problems.append("case %d: %d rows" % (i, n_rows - before))
            else:
                row_ = rows[-1]
                seen = (row_["code"], row_["sub"])
                codes[seen] = codes.get(seen, 0) + 1
                if seen != want:
                    problems.append("case %d: gateway %s/%s, reference %s/%s, bytes %s" % (
                        i, seen[0], seen[1], want[0], want[1], data[:48].hex()))
            if len(problems) > 20:
                break
        check(not problems, "%d fuzz cases disagree, first: %s" % (len(problems), "\n".join(problems[:5])))
        check(not g.edges["10.0.0.9"].conns, "a fuzz case reached the forbidden address")
        check(codes.get(("address", "-"), 0) > count // 10, "too few accepted hellos to mean anything: %s" % codes)
        sys.stdout.write("      fuzz outcomes: %s\n" % ", ".join(
            "%s/%s %d" % (k[0], k[1], v) for k, v in sorted(codes.items())))
    finally:
        g.stop()


# -- real TLS stacks, the image's own clients --------------------------------

class Relay:
    """127.0.0.1 TCP to the proxy socket, the shim's job, recording client bytes."""

    def __init__(self, proxy):
        self.proxy = proxy
        self.ls = socket.socket()
        self.ls.bind(("127.0.0.1", 0))
        self.ls.listen(16)
        self.port = self.ls.getsockname()[1]
        self.streams = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, _ = self.ls.accept()
            except OSError:
                return
            u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            u.connect(self.proxy)
            buf = bytearray()
            self.streams.append(buf)
            threading.Thread(target=self._pump, args=(c, u, buf), daemon=True).start()
            threading.Thread(target=self._pump, args=(u, c, None), daemon=True).start()

    def _pump(self, a, b, buf):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                if buf is not None:
                    buf += d
                b.sendall(d)
        except OSError:
            pass
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def hellos(self, i=0):
        s = bytes(self.streams[i])
        s = s[s.find(b"\r\n\r\n") + 4:]
        n, seq = 0, []
        while len(s) >= 5:
            t, ln = s[0], int.from_bytes(s[3:5], "big")
            if t == 0x16 and len(s) > 5 and s[5] == 0x01:
                n += 1
            seq.append(t)
            s = s[5 + ln:]
        return n, seq

    def close(self):
        self.ls.close()


def _tls_rig(td):
    key, crt = os.path.join(td, "k.pem"), os.path.join(td, "c.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                    "ec_paramgen_curve:P-256", "-nodes", "-keyout", key, "-out", crt,
                    "-days", "2", "-subj", "/CN=alpha.example",
                    "-addext", "subjectAltName=DNS:alpha.example"],
                   check=True, capture_output=True, timeout=30)
    return key, crt


def _s_server(key, crt, port, *extra):
    return subprocess.Popen(["openssl", "s_server", "-accept", "127.0.0.1:%d" % port,
                             "-cert", crt, "-key", key] + list(extra),
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _need(tool):
    check(shutil.which(tool), "%s is required for the real-stack rows and is missing" % tool)


def _real(fn):
    _need("openssl")
    _need("curl")
    td = tempfile.mkdtemp(prefix="gwtls", dir="/tmp")
    port = _free_port()
    g = GW(hosts=(b"alpha.example", b"denied.example"), start=False,
           fixture={"alpha.example": [PUB]})
    # Point the fixture address at the real server rather than at an Edge.
    g.edges[PUB].close()
    with open(g.map_path, "w") as f:
        f.write("%s %d\n" % (PUB, port))
    g.edges = {}
    srv = None
    relay = None
    try:
        g.start()
        relay = Relay(g.proxy)
        key, crt = _tls_rig(td)
        srv = fn(g, relay, td, key, crt, port)
    finally:
        if srv is not None:
            srv.kill()
            srv.wait()
        if relay is not None:
            relay.close()
        g.stop()
        shutil.rmtree(td, ignore_errors=True)


def _curl(relay, crt, *extra):
    return subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--cacert", crt,
                           "-x", "http://127.0.0.1:%d" % relay.port] + list(extra),
                          capture_output=True, text=True, timeout=30)


def _wait_listen(port):
    end = time.time() + 5
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise Fail("s_server never listened")


@row("real stack: HelloRetryRequest with curl against a P-256 only server")
def _():
    def body(g, relay, td, key, crt, port):
        srv = _s_server(key, crt, port, "-tls1_3", "-groups", "P-256", "-www")
        _wait_listen(port)
        p = _curl(relay, crt, "--tlsv1.3", "--curves", "X25519:P-256", "https://alpha.example/")
        check(p.returncode == 0 and p.stdout == "200", "curl rc %d %s %s" % (p.returncode, p.stdout, p.stderr))
        n, _ = relay.hellos(len(relay.streams) - 1)
        check(n == 2, "wanted two ClientHellos, the relay saw %d" % n)
        return srv
    _real(body)


@row("real stack: TLS 1.2 with curl")
def _():
    def body(g, relay, td, key, crt, port):
        srv = _s_server(key, crt, port, "-tls1_2", "-www")
        _wait_listen(port)
        p = _curl(relay, crt, "--tls-max", "1.2", "https://alpha.example/")
        check(p.returncode == 0 and p.stdout == "200", "curl rc %d %s %s" % (p.returncode, p.stdout, p.stderr))
        return srv
    _real(body)


@row("real stack: 0-RTT early data then a retry, with openssl s_client")
def _():
    def body(g, relay, td, key, crt, port):
        srv = _s_server(key, crt, port, "-tls1_3", "-groups", "P-256", "-early_data")
        _wait_listen(port)
        sess = os.path.join(td, "sess.pem")
        ed = os.path.join(td, "ed.txt")
        with open(ed, "w") as f:
            f.write("early\n")
        base = ["openssl", "s_client", "-connect", "alpha.example:443", "-proxy",
                "127.0.0.1:%d" % relay.port, "-servername", "alpha.example", "-CAfile", crt]
        p1 = subprocess.Popen(base + ["-tls1_3", "-groups", "P-256", "-sess_out", sess],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(1.5)
        out1 = p1.communicate(timeout=20)[0].decode(errors="replace")
        check(os.path.exists(sess), "no session ticket was saved:\n" + out1[-800:])
        p2 = subprocess.Popen(base + ["-sess_in", sess, "-early_data", ed, "-curves", "X25519:P-256"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(1.5)
        out2 = p2.communicate(timeout=20)[0].decode(errors="replace")
        check("Verify return code: 0 (ok)" in out2, "the resumed session failed:\n" + out2[-800:])
        n, seq = relay.hellos(len(relay.streams) - 1)
        check(n == 2, "wanted two ClientHellos, the relay saw %d (%s)" % (n, seq))
        check(0x17 in seq[:seq.index(0x16, 1) if 0x16 in seq[1:] else len(seq)],
              "no early data record crossed before the second hello: %s" % seq)
        return srv
    _real(body)


@row("real stack: curl reports the policy denial")
def _():
    def body(g, relay, td, key, crt, port):
        p = subprocess.run(["curl", "-sS", "-v", "-x", "http://127.0.0.1:%d" % relay.port,
                            "https://notlisted.example/"], capture_output=True, text=True, timeout=30)
        check(p.returncode != 0, "curl reached a denied host")
        check("403" in p.stderr, "curl did not see the 403:\n" + p.stderr[-600:])
        return None
    _real(body)


# ---------------------------------------------------------------------------

def run_row(name, fn):
    t0 = time.time()
    try:
        fn()
        return name, None, time.time() - t0
    except Fail as e:
        return name, str(e), time.time() - t0
    except Exception:
        return name, traceback.format_exc(), time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    signal.alarm(600)
    rows = [r for r in ROWS if not args.k or any(k in r[0] for k in args.k)]
    if args.list:
        for name, _, slow in rows:
            print(("[slow] " if slow else "") + name)
        return 0
    t0 = time.time()
    results = []
    slow = [r for r in rows if r[2]]
    fast = [r for r in rows if not r[2]]
    with concurrent.futures.ThreadPoolExecutor(max(1, len(slow))) as pool:
        futs = [pool.submit(run_row, n, f) for n, f, _ in slow]
        for n, f, _ in fast:
            res = run_row(n, f)
            results.append(res)
            print(("  ok    " if res[1] is None else "  FAIL  ") + "%s (%.1fs)" % (n, res[2]), flush=True)
            if res[1]:
                print("        " + res[1].replace("\n", "\n        "), flush=True)
        for fu in futs:
            res = fu.result()
            results.append(res)
            print(("  ok    " if res[1] is None else "  FAIL  ") + "%s (%.1fs)" % (res[0], res[2]), flush=True)
            if res[1]:
                print("        " + res[1].replace("\n", "\n        "), flush=True)
    failed = [r for r in results if r[1]]
    print("gateway corpus: %d rows, %d passed, %d failed" % (
        len(results), len(results) - len(failed), len(failed)))
    print("gateway corpus wall clock: %.1fs" % (time.time() - t0))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
