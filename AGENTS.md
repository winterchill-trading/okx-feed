# AGENTS.md

Guide for AI coding agents working in this repository. Read this first; the subdirectory
`AGENTS.md` files add detail for `lib/`, `bin/`, `bench/`, `docs/`, `test/` and `.github/`.
The workspace-wide guide is `../oxcaml-claude-skills/AGENTS.md`.

## Purpose

`okx-feed` is read-only public market data from OKX (trades, best bid and offer, L2 book, funding)
as a `Market_data.Feed.t`. It needs no API keys and places no orders.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `okx-feed` library (`Okx_feed`): `Config`, `Wire`, `Normalizer`, `Live_feed`, `Md_normalizer` |
| `bin/` | `okx-feed` command: `feed -symbol SYM -streams ... [-count N] [-raw] [-url URL]` |
| `bench/` | core_bench of the normalizer, and an in-process end-to-end throughput run of `Live_feed` |
| `docs/` | `okx-ws-spec.md`, the wire reference for the public channels |
| `test/` | Expect tests, the normalizer and feed tests, and `test/fixtures/raw/` (a recorded mainnet minute) |
| `.github/` | CI workflow |

## Build, test, run

Inside the workspace (sibling checkouts and the shared `5.2.0+ox` switch are required):

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/all
opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/doc
```

Parallel work: prefix the commands with `DUNE_BUILD_DIR=_build-okx-feed`.

Standalone: `venue-net` and `market-data` are not in the `winterchill` opam repository, so pin
them from GitHub in the order of `.github/workflows/ci.yml`, then `dune build && dune test`.

## Conventions

- Every module has an `.mli`. Code is `open! Core`, with labelled arguments and ppx_jane.
- Sizes are venue units. OKX swap sizes are contracts (one `BTC-USDT-SWAP` contract is 0.01 BTC);
  this library does not convert them.
- The Yojson path is the reference. The zero-allocation scanner must produce the same events; a
  fixture test checks that both paths agree. Change them together.
- Minor-word pins match within 2%; say why next to any pin you move.
- Formatting: `opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/fmt --auto-promote`.
  Never run `dune fmt` at the workspace root.

## Dependencies and dependents

- Depends on `market-data` and `venue-net`; `fixed-decimal`, `exchange-core` and `parquet` are
  pinned as transitive dependencies in CI.
- Used by `market-recorder`.
- CI pin order (`ci.yml`): `fixed-decimal`, `exchange-core`, `parquet`, `market-data`, `venue-net`.

## CI

`ci.yml` runs the `ox-setup` action with the five pins above, then `dune build`, `dune test`, and
the shared `obj-magic` workflow. Check a run with `gh run list --limit 1`, then at most one
`gh run watch <id> --exit-status`.

## Pitfalls

- OKX `seqId` exceeds 2^31, so sequence numbers are 63-bit OCaml ints.
- OKX wants the plain text frame `ping`, answered by a text `pong`, not a JSON keepalive.
- A reconnect gap is stamped at the reconnect, about 0.6 s after the drop, and precedes the first
  frame of the new socket.
- A book sequence break costs one unsubscribe and subscribe round trip.
- Funding is returned only once rate, mark and index are all known again, which can take a minute
  when the index is quiet.
- OKX book checksums are always 0; sequencing relies on `seqId` and `prevSeqId`.

## Where to read more

- `README.md`: coverage, usage, tests and benchmark, behaviour, reconnects and gaps, limitations.
- `docs/okx-ws-spec.md`, and `../specs/repos/okx-feed.md`.
- `../oxcaml-claude-skills/skills/oxcaml-performance/` for the scanner and the words-per-frame rules.
- `../oxcaml-claude-skills/GOTCHAS.md`, sections "Feed repos wave one" and "OxCaml performance".

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Run `opam install --switch 5.2.0+ox --dry-run <pkg>` first
  and stop if the plan touches any of them.
- Publish, tag or release. Never send orders or use API keys from this repository.
- Print secrets, or poll CI in a loop.
