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
Rows: first handshake message a client_key_exchange
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
