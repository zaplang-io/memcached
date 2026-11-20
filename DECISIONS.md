# memcached package decisions

Design decisions for the Zap `memcached` client, keyed to issues. Each records a
choice that could not be read straight off [pymemcache](https://pymemcache.readthedocs.io/)
or the memcached protocol, with the reference it follows or departs from.

## Parity target: pymemcache

The package tracks [**pymemcache**](https://pymemcache.readthedocs.io/) as its
primary API reference (`Client`, `PooledClient`, `HashClient`, and the serde
layer). `python-memcached` is a secondary reference only. pymemcache is the
modern, maintained, de-facto Python memcached client, so matching it gives Zap
users the least-surprise surface. Deviations are recorded below, keyed to the
issue that introduces them.

## Protocol: text first, meta deferred

memcached offers a line-oriented **text protocol** and a newer **meta/binary
protocol**. The client implements the text protocol first (epic #1 / #2): it is
simpler to frame, fully covers the pymemcache surface being built, and is
universally supported. Adopting the meta protocol (for e.g. opaque flags and
base64 keys) is a separate future decision and will be recorded here when taken.

## `set` is reserved → `set_value`

Zap reserves `set`, so the storage setter (issue #3) is named **`set_value`**,
mirroring the precedent set by the redis package. The remaining storage verbs
(`add`, `replace`, `append`, `prepend`) and all retrieval/delete/counter verbs
keep their pymemcache names. This is the one rename forced by the language; it
is called out in the README usage sketch.

## Text framing and errors (issue #2)

- The wire reader keeps reply lines and data blocks as `bytes`. It consumes a
  line through CRLF or a data block through its declared length plus CRLF.
  Reply lines have an 8 KiB limit so an unterminated reply cannot grow the
  line buffer indefinitely. The limit applies only to lines. [Text protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt)
- Keys must contain 1–250 printable ASCII bytes (0x21–0x7e). Callers that need
  to cache data under another key representation supply an ASCII encoding.
  [Text protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt)
- The draft uses named Zap error structs catchable by their type or by
  `Exception`. The public equivalent of pymemcache's `MemcacheError` base
  remains a design decision because Zap user-defined types lack custom
  inheritance (D-0015). Timeout and TCP failure have distinct package types,
  corresponding to pymemcache's timeout and socket errors. Server messages
  are decoded as UTF-8, with hex used for invalid UTF-8.
  [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html)
- The TCP dial helper takes a connect timeout in seconds, like pymemcache.
  Zero disables the timeout. A positive value is rounded up to a nanosecond
  and passed as an absolute monotonic deadline covering DNS and all TCP
  address attempts. [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html) · [zaplang-io/zap#1138](https://github.com/zaplang-io/zap/issues/1138)
- `Client(host, port=11211, connect_timeout=0.0, timeout=0.0)` accepts
  separate TCP host and port arguments as specified in #2. The constructor is
  lazy, and `connect()` opens explicitly. Zap reserves `close` for channels,
  so the idle teardown method is named `disconnect()`. `timeout` sets one
  deadline for an entire command after the dial, covering sends and reads.
  Each client has a private per-instance atomic guard. A concurrent operation
  raises `MemcacheConnectionError` so it cannot access the in-flight socket.
  [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html) · [Zap atomic field defaults](https://github.com/zaplang-io/zap/issues/1152)

## Storage wire behavior (issue #3)

- The five storage methods return `bool`. `STORED` maps to
  `True`, and `NOT_STORED` maps to `False`. `EXISTS` and `NOT_FOUND`
  belong to CAS in issue #6. With `noreply=True`, the client returns `True`
  when the write finishes and has no acknowledgement of storage. The
  default is `noreply=False` as specified in #3. [pymemcache response mapping](https://github.com/pinterest/pymemcache/blob/master/pymemcache/client/base.py)
- The text header emits flags as an unsigned 32-bit decimal and expiration
  as a signed 32-bit decimal, matching the default server build. Memcached
  interprets expiration using its 30-day cutoff and preserves the original
  flags and expiration when appending or prepending.
  [Text protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt) · [Server parser](https://github.com/memcached/memcached/blob/master/proto_parser.c)

## Retrieval types (issue #4)

- `get(key, default=None)` uses `Optional[bytes]`. `gets(key)` returns
  `(Optional[bytes], Optional[bytes])` with both elements absent on a miss.
  Multi-key calls return dictionaries containing only hits. `get_multi`
  aliases `get_many`. [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html)
- CAS tokens are opaque decimal `bytes`, matching pymemcache and preserving
  the full unsigned 64-bit range for issue #6. The internal results retain
  flags for the serde layer in issue #8.
  [Text protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt)
- Empty batches complete without a connection. A nonempty batch validates
  every key before dialing and sends each distinct key once. The reader
  consumes replies through `END` and rejects duplicate or unrequested
  response keys.

## Delete, counters, and touch (issue #5)

- `delete` and `touch` return `False` on a miss with replies enabled.
  `delete_many` and its alias `delete_multi` return `True` even when some
  keys are absent. A batch validates all keys before writing and processes
  one command per key under one client deadline. A transport or server
  error can leave earlier deletions applied.
  [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html)
- `incr` and `decr` take a `uint64` delta and return `Optional[uint64]`,
  preserving memcached's full unsigned range. The server wraps increment
  at 2⁶⁴ and clamps decrement to zero.
  [Text protocol](https://github.com/memcached/memcached/blob/master/doc/protocol.txt)
- These commands default to `noreply=False`. With `noreply=True`, they
  skip the read. Delete and touch report a completed write with `True`,
  while the counter methods return `None` without a confirmed value.
  [pymemcache Client](https://pymemcache.readthedocs.io/en/latest/apidoc/pymemcache.client.base.html)

<!--
Add one section per decision as issues are implemented, e.g.:

## CAS result modeling (issue #6)
...STORED / EXISTS / NOT_FOUND vs pymemcache True / False / None...

## Serde flag map (issue #8)
...the exact memcached flag values the typed serde uses...

## HashClient dead-server policy (issue #9)
...retry / eject behavior vs pymemcache...
-->
