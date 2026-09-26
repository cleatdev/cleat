# The egress gateway image (EGRESS-SPEC.md section 8.0, concept/46).
#
# Python 3 standard library on a distroless base: no shell, no package manager
# and no interpreter beyond python3, so a parser defect that yields execution
# lands somewhere with almost nothing to run. The gateway starts as root only to
# bind and chown its sockets, then drops to uid 65532 and verifies the drop
# before it reads a byte the box chose.
#
# Base pinned by its multi-arch OCI index digest (linux/amd64 + linux/arm64),
# the same idiom as the box image. Never built by _do_build, never FROM the box
# image. It carries no sh.cleat.version label.
FROM gcr.io/distroless/python3-debian12@sha256:2fdb05402a2cf21cf78fdb3ba4c5db167241e9e498140f5bf689d7efb773731f

LABEL sh.cleat.role=gateway

COPY gateway.py /usr/local/lib/cleat-gw/gateway.py
COPY gw-admin gw-health /usr/local/bin/

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=2 \
  CMD ["/usr/local/bin/gw-health"]

ENTRYPOINT ["/usr/bin/python3.11", "-I", "/usr/local/lib/cleat-gw/gateway.py"]
