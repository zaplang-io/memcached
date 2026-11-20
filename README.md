# memcached

Memcached client for [Zap](https://github.com/zaplang-io/zap) — an official **non-core** package.

- Tracking issue: [zaplang-io/zap#514](https://github.com/zaplang-io/zap/issues/514)
- Roadmap: [bootstrap epic #1](https://github.com/zaplang-io/memcached/issues/1)
- Contributor & agent conventions: [AGENTS.md](AGENTS.md)
- Design decisions: [DECISIONS.md](DECISIONS.md)

> **Status: early / scaffolding.** Text framing, key validation, and typed protocol errors are in development under [issue #2](https://github.com/zaplang-io/memcached/issues/2). The TCP client depends on [Zap hostname connect deadlines](https://github.com/zaplang-io/zap/issues/1138). The examples below describe the target API.

## Goals

- A typed Zap client whose public API mirrors [**pymemcache**](https://pymemcache.readthedocs.io/) (`Client`, `PooledClient`, `HashClient`, and the serde layer) as closely as Zap's static typing allows. API-parity with the popular Python library is a project rule — see [AGENTS.md](AGENTS.md).
- memcached's **text protocol** first; the newer meta/binary protocol is a later decision (see [DECISIONS.md](DECISIONS.md)).
- Values are `bytes` by default, with an optional **serde** layer (serializer/deserializer keyed on memcached flags) for typed values, matching pymemcache's model.

## Usage (target surface)

```zap
# Sketch — see the epic for what is implemented today.
conn = memcached.Client(host="127.0.0.1", port=11211)

# `set` is a reserved word in Zap, so the storage setter is named `set_value`
# (mirroring the redis package; see DECISIONS.md).
conn.set_value(b"user:1", b"alice", expire=60)

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

Run `zap test src/memcached.zap` with a Zap toolchain that has native code generation enabled. The protocol tests use a loopback TCP fake and require no running memcached service.

## Development

Read **[AGENTS.md](AGENTS.md)** before contributing — it covers the pymemcache-parity rule, the one-issue-one-PR flow, how design decisions are recorded in **[DECISIONS.md](DECISIONS.md)**, and the rule for reporting core Zap language/stdlib defects upstream in `zaplang-io/zap` (rather than working around them here).
