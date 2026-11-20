# memcached (Zap package) — contributor & agent conventions

This is an official **non-core** Zap package: a memcached client. These conventions apply to everyone working in this repo, human or agent.

## Project scope & design

- **Python-parity rule.** The public API mirrors [pymemcache](https://pymemcache.readthedocs.io/) (`Client`, `PooledClient`, `HashClient`, and the serde layer) as closely as Zap's static typing allows. `python-memcached` is a *secondary* reference only; pymemcache is the primary parity target.
- When a shape cannot match pymemcache cleanly — a word Zap reserves (e.g. `set` → `set_value`), Zap's requirement of a single declared return type, or bytes-vs-str — **do not guess.** Record the chosen deviation and its rationale in `DECISIONS.md`, keyed to the issue, with a link to the pymemcache (or protocol) reference it follows or departs from.
- Values are `bytes`; keys are protocol-legal `bytes`/ASCII (no spaces/control chars/newlines, ≤250 bytes). The optional serde layer provides typed values over memcached flags, mirroring pymemcache.
- Implement the **text protocol** first; the meta/binary protocol is a separate, later decision.

## Issues & PRs

- Keep issues concrete and testable, with as much detail as possible: the target pymemcache API, the memcached protocol command(s) involved, and explicit acceptance criteria.
- Multi-issue features get an **Epic** with linked, trackable sub-issues.
- Individual issues should be **'M'-sized**. Don't split an epic into unnecessary 'S'-sized issues.
- **One issue → one PR.** Branch fresh from `origin/main`; **rebase onto `origin/main`** before opening a PR and before pushing follow-up commits.
- **All package issues live in this repo** (zaplang-io/memcached), not in zaplang-io/zap.
- Conventional-commits PR titles.

## Core-language defects (important)

This package is built on the Zap language and stdlib. If package work exposes a **core language or stdlib defect**:

- **Report it in `zaplang-io/zap`**, and stop at reporting it.
- **Never work around a core defect** to make this package function. Keep the dependent work blocked/draft and note the dependency.
- Do not implement a core fix here; the Zap maintainer decides who fixes it and when.

## Decisions

- Record every non-obvious API/design decision in **`DECISIONS.md`**, keyed to its issue, citing the pymemcache or memcached-protocol reference it follows or deviates from. Keep it current with every PR that changes the public surface.

## Documentation

- Keep `README.md` and `DECISIONS.md` up to date with every PR that changes behavior or the public API.
- User-exposed functions carry docstrings suitable for later documentation generation.

## Tests

- Tests are **exhaustive, not minimal** — treat them as intent documentation and a walled garden around protocol and command behavior. Cover edge cases: empty values, large values, binary values containing `\r\n`, illegal/oversized keys, expiry boundaries, hit-vs-miss, CAS conflicts, `*_many` partial results, `noreply`, and connection/timeout errors.
- When fixing a bug, **first add a failing test** that reproduces it, then fix.
- Prefer a local `memcached` (or an in-process fake) for integration tests; gate live tests clearly.
- Do not assume dict/set iteration order in assertions (it is unspecified in Zap).

## Attribution

- **Agent attribution is allowed in this repository.** Commits, PR descriptions, and issue/PR comments may carry agent attribution (e.g. a `Co-authored-by` trailer or a "drafted by …" note). The `zaplang-io/zap` no-attribution rule does **not** apply here.
