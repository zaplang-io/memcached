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

<!--
Add one section per decision as issues are implemented, e.g.:

## Storage result modeling (issue #3)
...which pymemcache bool/None result maps to which declared Zap return type...

## CAS result modeling (issue #6)
...STORED / EXISTS / NOT_FOUND vs pymemcache True / False / None...

## Serde flag map (issue #8)
...the exact memcached flag values the typed serde uses...

## HashClient dead-server policy (issue #9)
...retry / eject behavior vs pymemcache...
-->
