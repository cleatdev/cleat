#!/usr/bin/python3 -I
# Cleat egress gateway. Python 3, standard library only (concept/46,
# EGRESS-SPEC.md section 8.0).
#
# One gateway serves one box. The box has no network at all: its only way out
# is /run/cleat-egress/proxy.sock, a unix socket on a volume the box mounts
# read-only. This process listens there as a CONNECT proxy that never
# terminates TLS. A tunnel is allowed when the CONNECT target is an allowlisted
# name on port 443 and every ClientHello the tunnel carries names that same
# target. Only then is the name resolved and every answer classified. One
# answer is dialled by its address literal.
#
# The host reaches the gateway only through /run/gw-admin/admin.sock, which
# lives in the gateway's own filesystem and in no mount, so only the daemon
# (docker exec) can reach it.
#
# This file is the whole gateway. gw-admin and gw-health are its two clients.

import asyncio
import hashlib
import ipaddress
import json
import os
import signal
import socket
import stat
import sys
import time

# Paths, fixed for the shipped image. The harness entry point passes its own.
SOCK_DIR = "/run/cleat-egress"
ADMIN_SOCK = "/run/gw-admin/admin.sock"
POLICY_PATH = "/etc/cleat-egress/policy.json"
RUNTIME_UID = 65532
RUNTIME_GID = 65532

# CONNECT head (section 4.3a).
HEAD_DEADLINE_S = 5
REQUEST_LINE_MAX = 1024     # bytes, its CRLF included
HEAD_MAX = 8192             # bytes, the terminating CRLF CRLF included
HEADER_LINES_MAX = 64

# Record scanner (section 4.5).
FIRST_BYTE_DEADLINE_S = 5
MAX_RECORD = 16640          # 2^14 + 256, the RFC 8446 section 5.2 ciphertext ceiling
BUDGET = 16384              # client bytes counted until the first application_data
REASSEMBLY_MAX = 16384      # bytes held in handshake reassembly
MAX_HELLOS = 2              # one HelloRetryRequest. RFC 8446 allows exactly one

# Resolution and dial (section 4.4).
CACHE_TTL_S = 60
CACHE_PRUNE_AT = 1024
CONNECT_TIMEOUT_S = 10
HALF_CLOSE_GRACE_S = 60

# Admin socket (section 8.5).
ADMIN_LINE_MAX = 512
ADMIN_DEADLINE_S = 2

POLICY_MAX_BYTES = 1048576
POLICY_KEYS = frozenset((
    "v", "digest", "mode", "port", "hosts", "max_tunnels",
    "handshake_timeout_s", "denials_log_max_bytes", "selftest_host",
))
SELFTEST_HOST = "cleat-gateway.invalid"

# Accepted connections in any phase, as a multiple of the tunnel cap. Past it a
# connection is closed at accept with no response, so a box cannot spend the
# gateway's descriptors on heads it never finishes.
CONN_HARD_CAP_FACTOR = 4

ALERT_ACCESS_DENIED = bytes.fromhex("15030300020231")   # fatal(2) access_denied(49)
ALERT_INTERNAL_ERROR = bytes.fromhex("15030300020250")  # fatal(2) internal_error(80)

OK_200 = b"HTTP/1.1 200 Connection Established\r\n\r\n"

# The hard-deny set, IPv4, from the IANA special-purpose address registry
# (RFC 6890). Section 4.4 step 8.
DENY_V4 = tuple(ipaddress.IPv4Network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
    "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
    "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
))


# ---------------------------------------------------------------------------
# Names (section 4.3b). One normalizer for the CONNECT target, the SNI and the
# host-side writer.

_BAD_CHARS = frozenset(b"/\\?#%@ \t\x00:")
_LDH = frozenset(b"abcdefghijklmnopqrstuvwxyz0123456789-")


def normalize_host(s):
    """bytes -> (str host, None) or (None, reason)."""
    if len(s) == 0 or len(s) > 255:
        return None, "TOO_LONG"
    for c in s:
        if c < 0x21 or c > 0x7E:
            return None, "NON_ASCII"
    for c in s:
        if c in _BAD_CHARS:
            return None, "BAD_CHARS"
    h = s.lower()
    if h.endswith(b"."):
        h = h[:-1]
    if h.endswith(b"."):
        return None, "MULTI_TRAILING_DOT"
    if len(h) > 253:
        return None, "TOO_LONG"
    labels = h.split(b".")
    if len(labels) < 2:
        return None, "NOT_FQDN"
    for label in labels:
        if len(label) == 0 or len(label) > 63:
            return None, "BAD_LABEL"
        for c in label:
            if c not in _LDH:
                return None, "BAD_LABEL"
        if label[0] == 0x2D or label[-1] == 0x2D:
            return None, "BAD_LABEL"
    last = labels[-1]
    if last.isdigit():
        return None, "IP_LITERAL"
    if last.startswith(b"0x"):
        return None, "IP_LITERAL"
    return h.decode("ascii"), None


def split_authority(a):
    """The authority of a well-formed head -> (kind, host bytes, port).

    kind is "ok", "v6" (a bracketed literal, refused as a name) or "bad"
    (malformed: 400). The port is mandatory, one to five digits, no leading
    zero beyond a single 0.
    """
    if a[:1] == b"[":
        host, sep, port = a.rpartition(b":")
        if (not sep or len(host) < 3 or host[-1:] != b"]" or not 1 <= len(port) <= 5
                or not port.isdigit() or (len(port) > 1 and port[:1] == b"0")):
            return "bad", None, 0
        return "v6", host, int(port)
    if a.count(b":") != 1:
        return "bad", None, 0
    host, _, port = a.partition(b":")
    if not host:
        return "bad", None, 0
    if not (1 <= len(port) <= 5) or not port.isdigit():
        return "bad", None, 0
    if len(port) > 1 and port[:1] == b"0":
        return "bad", None, 0
    return "ok", host, int(port)


_LOG_OK = frozenset(b"abcdefghijklmnopqrstuvwxyz0123456789.:_-")


def sanitize(raw):
    """Box-chosen bytes -> (printable str, trunc flag), for the log and replies.

    Lowercased, cut to 128 bytes, every byte outside [a-z0-9.:_-] replaced by
    '?'. trunc is 1 when anything was cut or replaced (section 8.4).
    """
    low = bytes(raw).lower()
    trunc = 0
    if len(low) > 128:
        low = low[:128]
        trunc = 1
    out = bytearray()
    for c in low:
        if c in _LOG_OK:
            out.append(c)
        else:
            out.append(0x3F)
            trunc = 1
    if not out:
        return "-", 1
    return out.decode("ascii"), trunc


# ---------------------------------------------------------------------------
# Denial responses (section 9.1). One function writes every sentence, so the
# status line and the body cannot drift.

_NOT_OUTAGE = ("This is a Cleat policy decision, not a network outage and not an\n"
               "authentication failure.\n")


def denial_sentence(kind, target, port=443, max_tunnels=0, trunc=0):
    """-> (status text, body text). target is already sanitized.

    A target that was cut or had a byte replaced is never offered back as the
    name to allow: that command would allow a different name.
    """
    if kind == "policy":
        first = "cleat egress: %s is not on the allowlist" % target
        if trunc:
            rest = _NOT_OUTAGE + ("The name is shown cut to 128 bytes. Ask the user to allow the full\n"
                                  "name with cleat egress allow.\n")
        else:
            rest = _NOT_OUTAGE + "Ask the user to run: cleat egress allow %s\n" % target
    elif kind == "invalid":
        first = "cleat egress: %s is not a name the allowlist can hold" % target
        rest = _NOT_OUTAGE + ("The allowlist holds DNS names only. An IP address or a malformed\n"
                              "name is never allowed.\n")
    elif kind == "port":
        first = "cleat egress: port %d is not allowed for %s" % (port, target)
        rest = _NOT_OUTAGE + ("Only port 443 is allowed, in every mode. The gateway checks a\n"
                              "destination through its TLS handshake and plain HTTP has none.\n")
    elif kind == "tunnels":
        first = "cleat egress: too many open tunnels"
        rest = ("This box already has %d tunnels open, the most its gateway allows.\n"
                "This is a local Cleat limit, not an upstream rate limit. Close idle\n"
                "connections before retrying.\n" % max_tunnels)
    else:
        first = "cleat egress: malformed CONNECT request"
        rest = "The gateway accepts CONNECT <host>:443 HTTP/1.1 with CRLF line endings.\n"
    return first, first + ".\n" + rest


_STATUS = {"policy": 403, "invalid": 403, "port": 403, "tunnels": 429, "malformed": 400}
_REASON_HEADER = {"policy": "policy", "invalid": "policy", "port": "port"}


def http_denial(kind, target="-", port=443, max_tunnels=0, trunc=0):
    sentence, body = denial_sentence(kind, target, port, max_tunnels, trunc)
    b = body.encode("ascii")
    head = [
        "HTTP/1.1 %d %s" % (_STATUS[kind], sentence),
        "Content-Type: text/plain; charset=utf-8",
        "Content-Length: %d" % len(b),
        "Connection: close",
    ]
    if kind in _REASON_HEADER:
        head.append("X-Cleat-Reason: %s" % _REASON_HEADER[kind])
    return ("\r\n".join(head) + "\r\n\r\n").encode("ascii") + b


# ---------------------------------------------------------------------------
# The CONNECT head (section 4.3a).

class HeadMalformed(Exception):
    """Answered with 400."""


class HeadAbort(Exception):
    """Closed with no response: a cap, the deadline or EOF before the end."""


async def read_head(reader, deadline):
    """-> (head bytes through CRLF CRLF, bytes that followed it)."""
    loop = asyncio.get_running_loop()
    buf = bytearray()
    while True:
        end = buf.find(b"\r\n\r\n")
        if end >= 0:
            end += 4
            if end > HEAD_MAX or buf.count(b"\r\n", 0, end) - 2 > HEADER_LINES_MAX:
                raise HeadAbort("cap")
            if buf.find(b"\r\n") + 2 > REQUEST_LINE_MAX:
                raise HeadAbort("cap")
            return bytes(buf[:end]), bytes(buf[end:])
        # No terminator yet. Refuse as soon as one could no longer fit, so the
        # verdict never depends on how the stream was split into reads.
        if len(buf) >= HEAD_MAX:
            raise HeadAbort("cap")
        rl = buf.find(b"\r\n")
        if (rl < 0 and len(buf) >= REQUEST_LINE_MAX) or rl + 2 > REQUEST_LINE_MAX:
            raise HeadAbort("cap")
        if buf.count(b"\r\n") - 1 > HEADER_LINES_MAX:
            raise HeadAbort("cap")
        left = deadline - loop.time()
        if left <= 0:
            raise HeadAbort("deadline")
        try:
            chunk = await asyncio.wait_for(reader.read(4096), left)
        except asyncio.TimeoutError:
            raise HeadAbort("deadline")
        if not chunk:
            raise HeadAbort("eof" if buf else "")
        buf += chunk


def parse_head(head):
    """-> (authority bytes, selftest flag). Raises HeadMalformed.

    Header lines are scanned only for well-formedness and are never read, with
    one exception that decides no allow: an exact `Cleat-Selftest: 1` line.
    """
    lines = head[:-4].split(b"\r\n")
    for line in lines:
        for c in line:
            if c != 0x09 and not 0x20 <= c <= 0x7E:
                raise HeadMalformed()
    parts = lines[0].split(b" ")
    if len(parts) != 3:
        raise HeadMalformed()
    method, authority, version = parts
    if method != b"CONNECT" or version not in (b"HTTP/1.1", b"HTTP/1.0"):
        raise HeadMalformed()
    if not authority or b"\t" in lines[0]:
        raise HeadMalformed()
    selftest = False
    for line in lines[1:]:
        if not line or line[0] in (0x20, 0x09):
            raise HeadMalformed()
        colon = line.find(b":")
        if colon <= 0:
            raise HeadMalformed()
        for c in line[:colon]:
            if c < 0x21 or c > 0x7E:
                raise HeadMalformed()
        if line == b"Cleat-Selftest: 1":
            selftest = True
    return authority, selftest


# ---------------------------------------------------------------------------
# The ClientHello scanner (section 4.5).

class Refusal(Exception):
    """A coded refusal after the 200. name is the foreign SNI, when there is one."""

    def __init__(self, code, sub="-", name=None, alert=ALERT_ACCESS_DENIED):
        Exception.__init__(self, code, sub)
        self.code = code
        self.sub = sub
        self.name = name
        self.alert = alert


def parse_client_hello(body):
    """A handshake body -> list of (extension type, data), or None.

    None means the body is not a well-formed ClientHello: some length does not
    walk exactly to its end. This is the shape test, never a content test.
    """
    n = len(body)
    if n < 35 or body[0] != 0x03 or body[1] != 0x03:
        return None
    p = 34
    sid = body[p]
    p += 1
    if sid > 32 or p + sid > n:
        return None
    p += sid
    if p + 2 > n:
        return None
    cs = int.from_bytes(body[p:p + 2], "big")
    p += 2
    if p + cs > n:
        return None
    p += cs
    if p + 1 > n:
        return None
    cm = body[p]
    p += 1
    if p + cm > n:
        return None
    p += cm
    if p == n:
        return []
    if p + 2 > n:
        return None
    el = int.from_bytes(body[p:p + 2], "big")
    p += 2
    if p + el != n:
        return None
    exts = []
    while p < n:
        if p + 4 > n:
            return None
        et = int.from_bytes(body[p:p + 2], "big")
        ln = int.from_bytes(body[p + 2:p + 4], "big")
        p += 4
        if p + ln > n:
            return None
        exts.append((et, body[p:p + ln]))
        p += ln
    return exts


def check_client_hello(exts, host):
    """Raises Refusal unless the hello carries exactly one server_name equal to host."""
    sn = [d for (t, d) in exts if t == 0x0000]
    if len(sn) == 0:
        raise Refusal("sni", "no-sni")
    if len(sn) > 1:
        raise Refusal("sni", "dup-sni")
    d = sn[0]
    if len(d) < 2 or 2 + int.from_bytes(d[0:2], "big") != len(d):
        raise Refusal("sni", "bad-clienthello")
    names = []
    q = 2
    while q < len(d):
        if q + 3 > len(d):
            raise Refusal("sni", "bad-clienthello")
        nt = d[q]
        nl = int.from_bytes(d[q + 1:q + 3], "big")
        q += 3
        if q + nl > len(d):
            raise Refusal("sni", "bad-clienthello")
        names.append((nt, d[q:q + nl]))
        q += nl
    if len(names) != 1:
        raise Refusal("sni", "dup-sni")
    nt, name = names[0]
    if len(name) == 0:
        raise Refusal("sni", "no-sni")
    if nt != 0x00:
        raise Refusal("sni", "bad-clienthello")
    h, reason = normalize_host(name)
    if reason is not None:
        raise Refusal("sni", "bad-clienthello")
    if h != host:
        raise Refusal("sni", "sni-mismatch", name=name)


class Scanner:
    """Client-to-server records, for the life of the tunnel.

    Server-to-client records are pumped and never parsed, so nothing here
    depends on recognising a HelloRetryRequest. Every ClientHello the client
    sends goes through check_client_hello, the first and any later one.
    """

    def __init__(self, host):
        self.host = host
        self.hellos = 0
        self.counting = True
        self.seen = 0
        self.partial = bytearray()

    def header(self, rtype, length):
        """Checks that need only the five-byte header, before the body is read."""
        if length > MAX_RECORD:
            raise Refusal("sni", "bad-clienthello")
        if self.counting:
            self.seen += 5 + length
            if self.seen > BUDGET:
                raise Refusal("handshake-flood")
        if rtype not in (0x14, 0x15, 0x16, 0x17):
            raise Refusal("sni", "bad-clienthello")

    def body(self, rtype, frag):
        """Scans one record. Returning means the record may be forwarded."""
        if rtype in (0x14, 0x17) and self.hellos == 0 and not self._hello_in_flight():
            # Before the first hello the only thing a client may be in the
            # middle of is that hello. Anything else would reach the upstream
            # ahead of every check.
            raise Refusal("sni", "bad-clienthello")
        if rtype == 0x17:
            self.counting = False
            self._reset_unless_hello()
            return
        if rtype == 0x14:
            self._reset_unless_hello()
            return
        if rtype == 0x15:
            return
        self.partial += frag
        if self.hellos == 0 and self.partial and self.partial[0] != 0x01:
            # The first handshake message's type is known from its first byte.
            raise Refusal("sni", "bad-clienthello")
        while len(self.partial) >= 4:
            n = int.from_bytes(self.partial[1:4], "big")
            if len(self.partial) < 4 + n:
                break
            mtype = self.partial[0]
            mbody = bytes(self.partial[4:4 + n])
            del self.partial[:4 + n]
            exts = parse_client_hello(mbody) if mtype == 0x01 else None
            if exts is None:
                if self.hellos == 0:
                    raise Refusal("sni", "bad-clienthello")
                continue
            self.hellos += 1
            if self.hellos > MAX_HELLOS:
                raise Refusal("handshake-flood")
            check_client_hello(exts, self.host)
        if len(self.partial) > REASSEMBLY_MAX:
            raise Refusal("handshake-flood")

    def _hello_in_flight(self):
        return bool(self.partial) and self.partial[0] == 0x01

    def _reset_unless_hello(self):
        # A partial that begins with msg_type 0x01 is kept, so a hello split
        # around a change_cipher_spec or an application_data record is
        # validated when the record that completes it arrives.
        if not self.partial or self.partial[0] != 0x01:
            del self.partial[:]


class ClientSource:
    """The client stream, starting with the bytes that followed the head."""

    def __init__(self, reader, pending):
        self.reader = reader
        self.buf = bytearray(pending)

    async def _fill(self, n, deadline):
        loop = asyncio.get_running_loop()
        while len(self.buf) < n:
            if deadline is None:
                chunk = await self.reader.read(65536)
            else:
                left = deadline - loop.time()
                if left <= 0:
                    raise asyncio.TimeoutError()
                chunk = await asyncio.wait_for(self.reader.read(65536), left)
            if not chunk:
                raise EOFError()
            self.buf += chunk

    async def first_byte(self, deadline):
        await self._fill(1, deadline)
        return self.buf[0]

    async def record(self, scan, deadline):
        """Reads and scans one record -> its raw bytes, header included."""
        await self._fill(5, deadline)
        rtype = self.buf[0]
        length = int.from_bytes(self.buf[3:5], "big")
        scan.header(rtype, length)
        await self._fill(5 + length, deadline)
        raw = bytes(self.buf[:5 + length])
        del self.buf[:5 + length]
        scan.body(rtype, raw[5:])
        return raw


# ---------------------------------------------------------------------------
# Addresses (section 4.4 step 8).

def canonical_v4(addr):
    """An address string -> IPv4Address, or None when it can never be dialled.

    An IPv4-mapped IPv6 address is rewritten to IPv4. Every other IPv6 form is
    refused: the gateway dials IPv4 only.
    """
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return None
    if ip.version == 6:
        ip = ip.ipv4_mapped
    return ip


def address_allowed(addr):
    ip = canonical_v4(addr)
    if ip is None:
        return False
    for net in DENY_V4:
        if ip in net:
            return False
    return True


def dial_target(addr, port):
    """The socket address a classified address is dialled at. Identity here.

    The harness entry point maps it to a local listener, because the gateway
    refuses loopback and so could never reach one. Nothing else changes it.
    """
    return (addr, port)


def peer_address(sockaddr):
    """The address getpeername reported, as the re-check classifies it.

    Identity here. The harness entry point maps a local listener back to the
    address it stands for.
    """
    return sockaddr[0]


async def open_upstream(addr, port):
    """Dials one classified IPv4 literal -> (reader, writer, peer address).

    Never handed a hostname: a hostname here would be a second resolution
    between classification and dial. The socket is connected by address, so
    no resolver runs, and the peer is read back with getpeername.
    """
    ipaddress.IPv4Address(addr)
    loop = asyncio.get_running_loop()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setblocking(False)
    try:
        await loop.sock_connect(sock, dial_target(addr, port))
        peer = peer_address(sock.getpeername())
        reader, writer = await asyncio.open_connection(sock=sock)
    except BaseException:
        sock.close()
        raise
    return reader, writer, peer


# ---------------------------------------------------------------------------
# Policy (section 8.2).

class PolicyError(Exception):
    """code is "parse" or "digest", the two reload failure answers."""

    def __init__(self, code, why):
        Exception.__init__(self, code, why)
        self.code = code
        self.why = why


class Policy:
    __slots__ = ("digest", "mode", "port", "hosts", "max_tunnels",
                 "handshake_timeout_s", "denials_max", "selftest_host")


def policy_digest(mode, port, hosts):
    """The policy digest of section 5.6: mode, port, then each host, one per line."""
    text = "%s\n%d\n" % (mode, port) + "".join(h + "\n" for h in hosts)
    return "v1:" + hashlib.md5(text.encode("ascii")).hexdigest()[:16]


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


def _int_in(v, lo, hi):
    return type(v) is int and lo <= v <= hi


def load_policy(path):
    """-> Policy. Raises PolicyError. A document it cannot fully verify is refused."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise PolicyError("parse", "not a regular file")
            data = os.read(fd, POLICY_MAX_BYTES + 1)
        finally:
            os.close(fd)
    except OSError as e:
        raise PolicyError("parse", "unreadable: %s" % e.strerror)
    if len(data) > POLICY_MAX_BYTES:
        raise PolicyError("parse", "larger than %d bytes" % POLICY_MAX_BYTES)
    try:
        doc = json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicate_keys)
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise PolicyError("parse", "not a JSON document")
    if type(doc) is not dict or set(doc) != POLICY_KEYS:
        raise PolicyError("parse", "unexpected keys")
    if doc["v"] != 1 or type(doc["v"]) is not int:
        raise PolicyError("parse", "unknown document version")
    if doc["mode"] not in ("strict", "open"):
        raise PolicyError("parse", "unknown mode")
    if not _int_in(doc["port"], 443, 443):
        raise PolicyError("parse", "port is not 443")
    hosts = doc["hosts"]
    if type(hosts) is not list:
        raise PolicyError("parse", "hosts is not a list")
    prev = None
    for h in hosts:
        if type(h) is not str:
            raise PolicyError("parse", "a host is not a string")
        try:
            raw = h.encode("ascii")
        except UnicodeEncodeError:
            raise PolicyError("parse", "a host is not ASCII")
        if normalize_host(raw) != (h, None):
            raise PolicyError("parse", "a host is not a normalized name")
        if prev is not None and not raw > prev:
            raise PolicyError("parse", "hosts are not sorted and unique")
        prev = raw
    if not _int_in(doc["max_tunnels"], 1, 65535):
        raise PolicyError("parse", "max_tunnels out of range")
    if not _int_in(doc["handshake_timeout_s"], 1, 300):
        raise PolicyError("parse", "handshake_timeout_s out of range")
    if not _int_in(doc["denials_log_max_bytes"], 4096, 67108864):
        raise PolicyError("parse", "denials_log_max_bytes out of range")
    if doc["selftest_host"] != SELFTEST_HOST:
        raise PolicyError("parse", "unexpected selftest_host")
    if type(doc["digest"]) is not str:
        raise PolicyError("parse", "digest is not a string")
    if doc["digest"] != policy_digest(doc["mode"], doc["port"], hosts):
        raise PolicyError("digest", "digest does not match mode, port and hosts")
    p = Policy()
    p.digest = doc["digest"]
    p.mode = doc["mode"]
    p.port = doc["port"]
    p.hosts = frozenset(hosts)
    p.max_tunnels = doc["max_tunnels"]
    p.handshake_timeout_s = doc["handshake_timeout_s"]
    p.denials_max = doc["denials_log_max_bytes"]
    p.selftest_host = doc["selftest_host"]
    return p


# ---------------------------------------------------------------------------
# The gateway.

def _stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _err(msg):
    try:
        sys.stderr.write("cleat-gw: %s\n" % msg)
        sys.stderr.flush()
    except OSError:
        pass


class Gateway:

    def __init__(self, policy_path, proxy_path, denials_fd, policy, sock_id):
        self.policy_path = policy_path
        self.proxy_path = proxy_path
        self.dfd = denials_fd
        self.policy = policy
        self.sock_id = sock_id          # (st_dev, st_ino) recorded at bind
        # A reader's mark is <generation>:<offset>. A restart that began again at
        # 0 over a log it did not truncate could match an old mark and resume
        # mid-file, so each process starts from its own start time instead.
        self.generation = time.time_ns() // 1000000
        self.allowed = 0
        self.denied = 0
        self.last_shim = None
        self.tunnels = 0
        self.conns = 0
        self.cache = {}
        self.inflight = {}              # name -> the lookup already under way

    # -- records ----------------------------------------------------------

    def deny_row(self, code, sub, raw_host, port):
        """One denials.log row. Written before any reply reaches the client."""
        host, trunc = sanitize(raw_host)
        row = ("%s code=%s sub=%s origin=box host=%s port=%d trunc=%d\n"
               % (_stamp(), code, sub, host, port, trunc)).encode("ascii")
        try:
            if os.fstat(self.dfd).st_size + len(row) > self.policy.denials_max:
                os.ftruncate(self.dfd, 0)
                self.generation += 1
            os.write(self.dfd, row)
        except OSError as e:
            _err("denials.log write failed: %s" % e.strerror)
        self.denied += 1

    def allow_row(self, host, port):
        h, trunc = sanitize(host.encode("ascii"))
        try:
            sys.stdout.write("%s allow host=%s port=%d trunc=%d\n" % (_stamp(), h, port, trunc))
            sys.stdout.flush()
        except OSError:
            pass

    # -- the proxy socket -------------------------------------------------

    async def serve_client(self, reader, writer):
        self.conns += 1
        try:
            if self.conns > self.policy.max_tunnels * CONN_HARD_CAP_FACTOR:
                return
            await self._serve(reader, writer)
        except (ConnectionError, OSError, asyncio.IncompleteReadError, EOFError):
            pass
        except Exception as e:          # a gateway bug fails closed, never open
            _err("internal error %s: %s" % (type(e).__name__, e))
        finally:
            self.conns -= 1
            await _close(writer)

    async def _reply(self, writer, data):
        writer.write(data)
        await writer.drain()

    async def _serve(self, reader, writer):
        loop = asyncio.get_running_loop()
        try:
            head, pending = await read_head(reader, loop.time() + HEAD_DEADLINE_S)
        except HeadAbort as e:
            # No response and no denials.log row: the head was never
            # trustworthy enough to answer. The container log keeps a line.
            if e.args and e.args[0]:
                _err("closed a CONNECT head with no response (%s)" % e.args[0])
            return
        try:
            authority, selftest = parse_head(head)
            kind, raw_host, port = split_authority(authority)
            if kind == "bad":
                raise HeadMalformed()
        except HeadMalformed:
            _err("answered a malformed CONNECT head with 400")
            await self._reply(writer, http_denial("malformed"))
            return
        pol = self.policy
        host, reason = (None, "IP_LITERAL") if kind == "v6" else normalize_host(raw_host)
        if reason is not None:
            self.deny_row("policy", "-", raw_host, port)
            await self._reply(writer, http_denial("invalid", sanitize(raw_host)[0], port))
            return
        if port != pol.port:
            self.deny_row("port", "-", host.encode("ascii"), port)
            await self._reply(writer, http_denial("port", sanitize(host.encode("ascii"))[0], port))
            return
        if host == pol.selftest_host:
            # The reserved self-test target. 200, close, dial nothing. A
            # heartbeat resets the shim clock. gw-admin's selftest does not.
            if not selftest:
                self.last_shim = time.monotonic()
            await self._reply(writer, OK_200)
            return
        if pol.mode == "strict" and host not in pol.hosts:
            self.deny_row("policy", "-", host.encode("ascii"), port)
            shown, trunc = sanitize(host.encode("ascii"))
            await self._reply(writer, http_denial("policy", shown, port, trunc=trunc))
            return
        if self.tunnels >= pol.max_tunnels:
            _err("answered a tunnel past the cap of %d with 429" % pol.max_tunnels)
            await self._reply(writer, http_denial("tunnels", max_tunnels=pol.max_tunnels))
            return
        self.tunnels += 1
        try:
            self.allowed += 1
            self.allow_row(host, port)
            await self._reply(writer, OK_200)
            await self._tunnel(reader, writer, host, pending, pol)
        finally:
            self.tunnels -= 1

    async def _refuse(self, writer, r, host, upstream=None):
        name = r.name if r.name is not None else host.encode("ascii")
        self.deny_row(r.code, r.sub, name, 443)
        try:
            writer.write(r.alert)
            await writer.drain()
        except (ConnectionError, OSError, RuntimeError):
            pass
        if upstream is not None:
            await _close(upstream)

    async def _tunnel(self, reader, writer, host, pending, pol):
        loop = asyncio.get_running_loop()
        t200 = loop.time()
        src = ClientSource(reader, pending)
        scan = Scanner(host)
        held = []
        held_bytes = 0

        # Until the first ClientHello is complete and validated. Every record
        # read here is held and replayed upstream in order once the dial lands.
        try:
            first = await src.first_byte(t200 + FIRST_BYTE_DEADLINE_S)
            if first != 0x16:
                raise Refusal("sni", "bad-clienthello")
            hello_by = t200 + pol.handshake_timeout_s
            while scan.hellos == 0:
                raw = await src.record(scan, hello_by)
                held.append(raw)
                held_bytes += len(raw)
                if scan.hellos == 0 and held_bytes > BUDGET:
                    raise Refusal("handshake-flood")
        except Refusal as r:
            await self._refuse(writer, r, host)
            return
        except asyncio.TimeoutError:
            await self._refuse(writer, Refusal("sni", "handshake-timeout"), host)
            return
        except EOFError:
            await self._refuse(writer, Refusal("sni", "no-clienthello"), host)
            return

        # Only now resolve, classify every candidate, dial one by address.
        try:
            addrs = await self.resolve(host)
        except (OSError, UnicodeError):
            addrs = []
        if not addrs:
            await self._refuse(writer, Refusal("upstream", alert=ALERT_INTERNAL_ERROR), host)
            return
        for a in addrs:
            if not address_allowed(a):
                await self._refuse(writer, Refusal("address"), host)
                return
        upstream = None
        for a in addrs:
            try:
                ur, uw, peer = await asyncio.wait_for(
                    open_upstream(str(canonical_v4(a)), pol.port), CONNECT_TIMEOUT_S)
            except (OSError, asyncio.TimeoutError, ValueError):
                continue
            upstream = (ur, uw)
            break
        if upstream is None:
            await self._refuse(writer, Refusal("upstream", alert=ALERT_INTERNAL_ERROR), host)
            return
        ur, uw = upstream
        if not address_allowed(peer):
            await self._refuse(writer, Refusal("address"), host, uw)
            return

        try:
            uw.write(b"".join(held))
            await uw.drain()
        except (ConnectionError, OSError):
            await _close(uw)
            return
        await self._pump(src, scan, writer, ur, uw, host)

    async def _pump(self, src, scan, cw, ur, uw, host):
        async def client_to_upstream():
            while True:
                try:
                    raw = await src.record(scan, None)
                except EOFError:
                    _write_eof(uw)
                    return None
                uw.write(raw)
                await uw.drain()

        async def upstream_to_client():
            while True:
                data = await ur.read(65536)
                if not data:
                    _write_eof(cw)
                    return None
                cw.write(data)
                await cw.drain()

        c2u = asyncio.ensure_future(client_to_upstream())
        u2c = asyncio.ensure_future(upstream_to_client())
        try:
            done, pending = await asyncio.wait((c2u, u2c), return_when=asyncio.FIRST_COMPLETED)
            clean = all(t.exception() is None for t in done)
            if clean and pending:
                # One side closed cleanly. Give the other a bounded while.
                await asyncio.wait(pending, timeout=HALF_CLOSE_GRACE_S)
            if c2u.done() and not c2u.cancelled() and isinstance(c2u.exception(), Refusal):
                u2c.cancel()
                await self._refuse(cw, c2u.exception(), host, uw)
        finally:
            for t in (c2u, u2c):
                if not t.done():
                    t.cancel()
            for t in (c2u, u2c):
                try:
                    await t
                except BaseException:
                    pass
            await _close(uw)

    async def resolve(self, host):
        """The one resolver. Lazy, allow path only, cached a fixed 60 seconds.

        Concurrent first uses of one name share a single lookup, so a burst of
        tunnels to one host is one query rather than a burst of them.
        """
        now = time.monotonic()
        hit = self.cache.get(host)
        if hit is not None and hit[0] > now:
            return hit[1]
        fut = self.inflight.get(host)
        if fut is None:
            fut = asyncio.ensure_future(self._lookup(host))
            self.inflight[host] = fut
            fut.add_done_callback(lambda f, h=host: self._lookup_done(h, f))
        # shield: a tunnel cancelled mid-lookup must not cancel the lookup the
        # others share.
        return await asyncio.shield(fut)

    def _lookup_done(self, host, fut):
        # Cleared when the lookup ends, whoever is still waiting, so a stale
        # answer can never outlive it. Reading the exception marks it seen.
        if self.inflight.get(host) is fut:
            del self.inflight[host]
        if not fut.cancelled():
            fut.exception()

    async def _lookup(self, host):
        now = time.monotonic()
        loop = asyncio.get_running_loop()
        # Bytes, not str: a str name would pass through Python's idna codec,
        # a second name parser the section 4.3b normalizer already replaces.
        infos = await loop.getaddrinfo(host.encode("ascii") + b".", 443,
                                       family=socket.AF_INET, type=socket.SOCK_STREAM)
        addrs = []
        for info in infos:
            a = info[4][0]
            if a not in addrs:
                addrs.append(a)
        if len(self.cache) >= CACHE_PRUNE_AT:
            for k in [k for k, v in self.cache.items() if v[0] <= now]:
                del self.cache[k]
            if len(self.cache) >= CACHE_PRUNE_AT:
                self.cache.clear()
        if addrs:
            self.cache[host] = (now + CACHE_TTL_S, addrs)
        return addrs

    # -- the admin socket -------------------------------------------------

    async def serve_admin(self, reader, writer):
        try:
            line = await asyncio.wait_for(reader.readuntil(b"\n"), ADMIN_DEADLINE_S)
            answer = self.admin(line[:-1])
            writer.write(answer.encode("ascii") + b"\n")
            await writer.drain()
        except (asyncio.TimeoutError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError, ConnectionError, OSError):
            pass
        except Exception as e:
            _err("admin internal error %s: %s" % (type(e).__name__, e))
        finally:
            await _close(writer)

    def admin(self, line):
        try:
            text = line.decode("ascii")
        except UnicodeDecodeError:
            return "err - bad-argument"
        verb, _, arg = text.partition(" ")
        if not verb or not all(c.isalnum() or c in "-_" for c in verb):
            return "err - unknown-verb"
        if verb == "reload":
            try:
                self.policy = load_policy(self.policy_path)
            except PolicyError as e:
                _err("reload refused, %s: %s" % (e.code, e.why))
                return "err reload %s" % e.code
            return "ok reload %s" % self.policy.digest
        if verb == "policy-digest":
            return "ok policy-digest %s" % self.policy.digest
        if verb == "path_ok":
            return "ok path_ok %s" % ("true" if self.path_ok() else "false")
        if verb == "last_shim_seen":
            if self.last_shim is None:
                return "ok last_shim_seen -1"
            return "ok last_shim_seen %d" % int(time.monotonic() - self.last_shim)
        if verb == "match":
            h, reason = normalize_host(arg.encode("ascii"))
            if reason is not None:
                return "err match bad-argument"
            pol = self.policy
            ok = pol.mode == "open" or h in pol.hosts
            return "ok match %s" % ("allow" if ok else "deny policy")
        if verb == "counts":
            return "ok counts %d %d" % (self.allowed, self.denied)
        if verb == "log-state":
            try:
                size = os.fstat(self.dfd).st_size
            except OSError:
                return "err log-state not-ready"
            return "ok log-state %d %d" % (self.generation, size)
        return "err %s unknown-verb" % verb

    def path_ok(self):
        try:
            st = os.lstat(self.proxy_path)
        except OSError:
            return False
        return stat.S_ISSOCK(st.st_mode) and (st.st_dev, st.st_ino) == self.sock_id


def _write_eof(writer):
    try:
        if writer.can_write_eof():
            writer.write_eof()
    except (ConnectionError, OSError, RuntimeError):
        pass


async def _close(writer):
    try:
        writer.close()
        await writer.wait_closed()
    except (ConnectionError, OSError, RuntimeError):
        pass


# ---------------------------------------------------------------------------
# Startup (section 8.2). Every step before the drop runs as uid 0 holding
# CHOWN, SETUID and SETGID. Any failure is fatal. No byte the box chose is read
# until the drop is verified.

class Config:
    def __init__(self, sock_dir=SOCK_DIR, admin_sock=ADMIN_SOCK, policy_path=POLICY_PATH,
                 sock_uid=None, sock_gid=None, harness=False):
        self.sock_dir = sock_dir
        self.admin_sock = admin_sock
        self.policy_path = policy_path
        self.sock_uid = sock_uid
        self.sock_gid = sock_gid
        self.harness = harness


def _bind_unix(path, mode):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    os.chmod(path, mode)
    return s


def verify_dropped(harness):
    try:
        with open("/proc/self/status") as f:
            status = f.read()
    except OSError:
        if harness and os.getuid() != 0 and os.geteuid() != 0:
            return
        raise SystemExit("cleat-gw: cannot read /proc/self/status to verify the drop")
    fields = {}
    for line in status.splitlines():
        k, _, v = line.partition(":")
        fields[k] = v.split()
    uids = fields.get("Uid", [])
    caps = [fields.get(k, ["x"])[0] for k in ("CapPrm", "CapEff", "CapAmb")]
    if len(uids) != 4 or "0" in uids or any(c.strip("0") for c in caps):
        raise SystemExit("cleat-gw: still privileged after the drop, refusing to serve")


def start(cfg):
    """Steps 1 to 7 of section 8.2 -> (Gateway, proxy socket, admin socket)."""
    os.umask(0o077)
    proxy_path = os.path.join(cfg.sock_dir, "proxy.sock")
    proxy = _bind_unix(proxy_path, 0o600)
    if not cfg.harness:
        os.chown(proxy_path, cfg.sock_uid, cfg.sock_gid)
    st = os.stat(proxy_path)
    admin = _bind_unix(cfg.admin_sock, 0o600)
    admin.listen(16)
    dfd = os.open(os.path.join(cfg.sock_dir, "denials.log"),
                  os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC | os.O_NOFOLLOW, 0o644)
    os.fchmod(dfd, 0o644)
    policy = load_policy(cfg.policy_path)
    if not cfg.harness:
        os.setgroups([])
        os.setgid(RUNTIME_GID)
        os.setuid(RUNTIME_UID)
    verify_dropped(cfg.harness)
    proxy.listen(256)
    gw = Gateway(cfg.policy_path, proxy_path, dfd, policy, (st.st_dev, st.st_ino))
    return gw, proxy, admin


async def serve(gw, proxy, admin):
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    s1 = await asyncio.start_unix_server(gw.serve_client, sock=proxy)
    s2 = await asyncio.start_unix_server(gw.serve_admin, sock=admin, limit=ADMIN_LINE_MAX)
    _err("serving %s, mode %s, %d hosts" % (gw.policy.digest, gw.policy.mode, len(gw.policy.hosts)))
    await stop.wait()
    s1.close()
    s2.close()
    tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    for t in tasks:
        t.cancel()
    if tasks:
        await asyncio.wait(tasks, timeout=2)


def run(cfg):
    try:
        gw, proxy, admin = start(cfg)
    except PolicyError as e:
        _err("refusing to start, policy %s: %s" % (e.code, e.why))
        return 1
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(serve(gw, proxy, admin))
    # A getaddrinfo still running in an executor thread cannot be cancelled,
    # and a normal interpreter exit would wait for it. Nothing is left to
    # flush but the two streams, so leave now.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except OSError:
            pass
    os._exit(0)


def _env_id(name):
    v = os.environ.get(name, "")
    if not v.isdigit() or len(v) > 10 or int(v) > 4294967294:
        raise SystemExit("cleat-gw: %s must be a decimal id" % name)
    return int(v)


def main(argv):
    for a in argv:
        if a.split("=", 1)[0] in ("--resolver-fixture", "--upstream-map"):
            _err("%s is accepted only by the test harness entry point" % a.split("=", 1)[0])
            return 2
    if argv:
        _err("takes no arguments")
        return 2
    cfg = Config(sock_uid=_env_id("CLEAT_SOCK_UID"), sock_gid=_env_id("CLEAT_SOCK_GID"))
    return run(cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
