# Gateway mutations

The bats mutation harness (`test/mutation_regressions.sh`) mutates `bin/cleat` and the shipped
bash scripts. It cannot reach the gateway, which is Python. This file is the gateway's own list
(EGRESS-SPEC.md 11.6 and 4.5). Run it before any change to `docker/gateway/gateway.py` is merged:

```
python3 test/gateway/mutate.py            # every entry
python3 test/gateway/mutate.py -k hellos  # entries whose name contains the text
```

Each entry replaces one literal in a copy of `gateway.py` (several `Before` or `After` lines join
with newlines), runs the named corpus rows against the
copy and expects at least one of them to fail. `mutate.py` reads this file. An entry whose
`Before` text is not found exactly once in the source reports NO MATCH, so a refactor that moves a
line must move its entry in the same change. A row filter is a substring of a corpus row name.

## sni_count_exact
Rows: two names inside one server_name extension
Before: `    if len(names) != 1:`
After: `    if len(names) < 1:`
Why: a hello with two names in one extension must refuse as dup-sni. Spec 4.5 `test_single_sni_required`.

## dial_by_address
Rows: rebinding
Before: `open_upstream(str(canonical_v4(a)), pol.port)`
After: `open_upstream(host, pol.port)`
Why: a hostname handed to the dial is a second resolution between classification and dial.

## resolve_only_after_allow
Rows: denied host is never resolved
Before: `        if pol.mode == "strict" and host not in pol.hosts:`
After: `        await self.resolve(host)`
After: `        if pol.mode == "strict" and host not in pol.hosts:`
Why: a denied name must never reach the resolver, which is the exfiltration channel of spec 4.4.

## every_hello_checked
Rows: HelloRetryRequest, second ClientHello carrying a different SNI | early data before a second ClientHello
Before: `            check_client_hello(exts, self.host)`
After: `            self.hellos == 1 and check_client_hello(exts, self.host)`
Why: a validator that stops after the first hello leaves the second one's SNI unchecked.

## two_hello_cap
Rows: a third ClientHello in one tunnel
Before: `MAX_HELLOS = 2 `
After: `MAX_HELLOS = 8 `
Why: the only coverage the handshake-flood code has on the hello count.

## exact_membership
Rows: lookalike host with the real one allowed
Before: `        if pol.mode == "strict" and host not in pol.hosts:`
After: `        if pol.mode == "strict" and not any(host.endswith(h) for h in pol.hosts):`
Why: `github.com` must never match `evilgithub.com` or `api.github.com`.

## denial_body
Rows: a policy denial's body bytes match the status text | malformed CONNECT head
Before: `    return ("\r\n".join(head) + "\r\n\r\n").encode("ascii") + b`
After: `    return ("\r\n".join(head) + "\r\n\r\n").encode("ascii")`
Why: without the body Claude Code reports an authentication failure (spec 9.1). `vnext_egress_denial_body`.

## app_data_keeps_scanning
Rows: early data before a second ClientHello
Before: `            self.counting = False`
After: `            self.counting = False`
After: `            self.body = lambda rtype, frag: None`
Why: the first application_data record must not switch the scanner off (spec 4.5 `test_second_hello_after_early_data_refused`).

## first_message_is_a_hello
Rows: session id length 0xff | extension length longer than the remaining buffer
Before: `                if self.hellos == 0:`
Before: `                    raise Refusal("sni", "bad-clienthello")`
After: `                if False:`
After: `                    raise Refusal("sni", "bad-clienthello")`
Why: the first client handshake message in every TLS version is a ClientHello (spec 4.5 `test_first_message_must_be_a_hello`).

## hello_deadline
Rows: slow ClientHello
Before: `hello_by = t200 + pol.handshake_timeout_s`
After: `hello_by = t200 + 3600`
Why: a client dribbling one byte every five seconds must still be reaped (spec 4.5 `test_slow_clienthello_reaped`).

## private_ranges_refused
Rows: resolved to a private or special address
Before: `"0.0.0.0/8", "10.0.0.0/8", `
After: `"0.0.0.0/8", `
Why: an allowed name that resolves into private space is refused after resolution.

## mapped_v6_canonicalised
Rows: resolved to a private or special address
Before: `        ip = ip.ipv4_mapped`
After: `        pass`
Why: `::ffff:127.0.0.1` must be classified as `127.0.0.1`, never skipped by an IPv4-only test.

## port_443_only
Rows: port 80 and port 8443 are refused
Before: `        if port != pol.port:`
After: `        if False:`
Why: without a ClientHello there is nothing to check, so every port but 443 is refused (spec 4.6).

## record_ceiling
Rows: record length field of 20000
Before: `        if length > MAX_RECORD:`
After: `        if False:`
Why: an oversized record is refused at its header rather than buffered.

## held_bytes_bounded
Rows: partial hello held behind application_data
Before: `                if scan.hellos == 0 and held_bytes > BUDGET:`
After: `                if False:`
Why: before the first hello completes the budget can stop counting, so held records need their own bound.

## selftest_never_resets_clock
Rows: Cleat-Selftest: 1 leaves last_shim_seen alone
Before: `            if not selftest:`
Before: `                self.last_shim = time.monotonic()`
After: `            if True:`
After: `                self.last_shim = time.monotonic()`
Why: a gate pass must never make a dead shim read as alive (spec 8.5).

## reload_keeps_policy_on_error
Rows: reload answers the new digest
Before: `    if doc["digest"] != policy_digest(doc["mode"], doc["port"], hosts):`
After: `    if doc["digest"] != doc["digest"]:`
Why: the gateway recomputes the digest, so a readback is evidence rather than an echo (spec 8.2).

## bracket_authority_well_formed
Rows: bracketed IPv6 in CONNECT
Before: `        if (not sep or len(host) < 3 or host[-1:] != b"]" or not 1 <= len(port) <= 5`
After: `        if (False or not 1 <= len(port) <= 5`
Why: a bracket does not excuse a malformed authority, which is a 400 with no row (4.3a rule 5).

## request_line_counts_crlf
Rows: the request line cap is 1 KiB with its CRLF
Before: `        if (rl < 0 and len(buf) >= REQUEST_LINE_MAX) or rl + 2 > REQUEST_LINE_MAX:`
After: `        if False:`
Why: a request line that can no longer fit is closed at once rather than held to the deadline.

## truncated_target_not_offered
Rows: 128-byte-truncated target
Before: `        if trunc:`
After: `        if False:`
Why: an allow command naming a cut name would allow a different name (9.1 rule 5).

## generation_unique_per_process
Rows: a restarted gateway starts a new log generation
Before: `        self.generation = time.time_ns() // 1000000`
After: `        self.generation = 0`
Why: a restart that reused generation 0 over the same log could match an old reader mark and resume mid-file.

## sigterm_during_lookup
Rows: SIGTERM exits within five seconds while a lookup is in flight
Before: `    os._exit(0)`
After: `    return 0`
Why: a normal exit waits for the executor thread still inside getaddrinfo.

## deep_json_refused
Rows: nests past the parser
Before: `    except (ValueError, UnicodeDecodeError, RecursionError):`
After: `    except (ValueError, UnicodeDecodeError):`
Why: a document the parser cannot descend is a parse refusal, never an exception that drops the answer.

## fifo_policy_nonblocking
Rows: a FIFO at the policy path cannot freeze a reload
Before: `        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)`
After: `        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)`
Why: the open of a FIFO blocks the whole event loop before the regular-file check can run.

## first_message_type_early
Rows: before the first hello only a hello may be in flight
Before: `        if self.hellos == 0 and self.partial and self.partial[0] != 0x01:`
After: `        if False:`
Why: a non-hello first message dropped by a reset on 0x14 or 0x17 would never be checked.

## no_record_ahead_of_first_hello
Rows: before the first hello only a hello may be in flight
Before: `        if rtype in (0x14, 0x17) and self.hellos == 0 and not self._hello_in_flight():`
After: `        if False:`
Why: application_data or change_cipher_spec with no hello in flight would reach the upstream ahead of every check.

## reassembly_bound
Rows: more than 16 KiB held in reassembly
Before: `        if len(self.partial) > REASSEMBLY_MAX:`
After: `        if False:`
Why: once application_data stops the budget, this bound is all that caps a partial message.

## peer_rechecked
Rows: getpeername reading back a forbidden address
Before: `        if not address_allowed(peer):`
After: `        if False:`
Why: the re-check catches a connect path that diverges from what was classified.

## ipv4_only_query
Rows: the resolver is asked for IPv4 only
Before: `                                       family=socket.AF_INET, type=socket.SOCK_STREAM)`
After: `                                       family=0, type=socket.SOCK_STREAM)`
Why: the gateway issues no AAAA query, so no IPv6 candidate ever enters the classifier (4.4).

## uncoded_refusals_logged
Rows: a malformed CONNECT head writes no row
Before: `            _err("answered a malformed CONNECT head with 400")`
After: `            pass`
Why: the three uncoded refusals are recorded only in the container log (9.2).

## lookups_coalesced
Rows: concurrent first uses of one name share a single lookup
Before: `        fut = self.inflight.get(host)`
After: `        fut = None`
Why: a burst of tunnels to one host must be one query, not a burst of them (4.4).

## failed_peer_read_is_upstream
Rows: a getpeername that fails after connect
Before: `            except (OSError, asyncio.TimeoutError, ValueError):`
After: `            except (asyncio.TimeoutError, ValueError):`
Why: a peer that resets after connect is an unreachable upstream, never an `address` security event.

## fuzz_catches_lenient_parse
Rows: 10,000 ClientHellos mutated
Before: `    if p + el != n:`
After: `    if p + el > n:`
Why: the differential fuzz holds every case to an independent reading of 4.5, so a parser that tolerates trailing bytes after the extension block disagrees with it.

## fuzz_catches_budget_drift
Rows: 10,000 ClientHellos mutated
Before: `BUDGET = 16384 `
After: `BUDGET = 1000 `
Why: the fuzz, not only its named rows, notices a budget that refuses real hellos (the node fixture is 1589 bytes).
