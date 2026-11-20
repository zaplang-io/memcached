# memcached

Memcached client for [Zap](https://github.com/zaplang-io/zap) — an official **non-core** package.

- Tracking issue: [zaplang-io/zap#514](https://github.com/zaplang-io/zap/issues/514)
- Roadmap: [bootstrap epic #1](https://github.com/zaplang-io/memcached/issues/1)
- Contributor & agent conventions: [AGENTS.md](AGENTS.md)
- Design decisions: [DECISIONS.md](DECISIONS.md)

> **Status: early.** The single-server client supports connection management and the five text storage commands. Retrieval, counters, and pooling are tracked in the [bootstrap epic](https://github.com/zaplang-io/memcached/issues/1).

## Goals

- A typed Zap client whose public API mirrors [**pymemcache**](https://pymemcache.readthedocs.io/) (`Client`, `PooledClient`, `HashClient`, and the serde layer) as closely as Zap's static typing allows. API-parity with the popular Python library is a project rule — see [AGENTS.md](AGENTS.md).
- memcached's **text protocol** first; the newer meta/binary protocol is a later decision (see [DECISIONS.md](DECISIONS.md)).
- Values are `bytes` by default, with an optional **serde** layer (serializer/deserializer keyed on memcached flags) for typed values, matching pymemcache's model.

## Usage

Construct a client with `memcached.Client(host="127.0.0.1", port=11211)`.
Call `connect()` to open the connection immediately or let a command open it
on demand. Call `disconnect()` to close it. Both methods are idempotent when
the client is idle. The next command can reconnect after a disconnect or a
failed exchange. `connect_timeout` and `timeout` are in seconds and default to
`0.0`, which disables the corresponding deadline. A single client permits
one operation at a time.

```zap
import memcached

conn = memcached.Client(host="127.0.0.1", port=11211)

conn.set_value(b"user:1", b"alice", expire=60)
conn.add(b"user:2", b"bob")
conn.replace(b"user:1", b"alice", flags=1)
conn.append(b"user:1", b" smith")
conn.prepend(b"user:1", b"dr. ")
conn.disconnect()
```

Each storage method accepts `key`, `value`, `expire=0`, `flags=0`, and
`noreply=False`. With replies enabled, the boolean reports whether the server
stored the value. With `noreply=True`, `True` means the write finished.

## Planned APIs

```zap
got = conn.get(b"user:1")          # bytes | None
hits = conn.get_many([b"a", b"b"]) # dict[bytes, bytes], present keys only
conn.incr(b"counter", 1)
conn.delete(b"user:1")
conn.disconnect()
```

Multiple servers and pooling follow pymemcache:

```zap
pool = memcached.PooledClient(host="127.0.0.1", port=11211, max_pool_size=8)
ring = memcached.HashClient([(b"10.0.0.1", 11211), (b"10.0.0.2", 11211)])
```

## Protocol

memcached speaks a line-oriented **text protocol** and a newer meta/binary protocol. This client implements the text protocol first. The meta protocol is deferred (DECISIONS.md). Keys are 1–250 printable ASCII bytes with no spaces. Values are `bytes`.

## Build and test

Run `zap test src/memcached.zap` with a native-codegen Zap toolchain that includes [hostname connect deadlines](https://github.com/zaplang-io/zap/issues/1138). The protocol tests use a loopback TCP fake and require no running memcached service.

GitHub Actions runs the protocol suite and checks formatting on pull requests and pushes to `main`. It also runs `sh tools/run-package-tests.sh` to validate package installation and imports from a path dependency and a temporary local registry.

The loopback suite covers storage command framing and reply handling, including a `noreply` write followed by an acknowledged write on the same socket. CI also runs the storage tests against memcached 1.6. To run the live checks with a dedicated server on port 11211, set `MEMCACHED_TEST_HOST` when invoking `zap test src/memcached.zap`.

## Development

Read **[AGENTS.md](AGENTS.md)** before contributing — it covers the pymemcache-parity rule, the one-issue-one-PR flow, how design decisions are recorded in **[DECISIONS.md](DECISIONS.md)**, and the rule for reporting core Zap language/stdlib defects upstream in `zaplang-io/zap` (rather than working around them here).
