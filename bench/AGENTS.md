# AGENTS.md (bench/)

- `main.ml`: core_bench of `Normalizer.frame` per stream (trades, bbo, funding) and a 60-frame book
  replay from a 400-level snapshot.
- `live.ml`: frames per second and words per frame through `Live_feed`, end to end. The recorded
  trades minute in `test/fixtures` is replayed by an in-process fake server, so no network is used.

Quote the machine and the profile with any number you copy into the README. Benchmarks are not
pinned thresholds.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/all`.
