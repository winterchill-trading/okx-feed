# AGENTS.md (bin/)

The `okx-feed` command. It parses `feed -symbol SYM -streams ... [-count N] [-raw] [-url URL]`
and prints the normalized events, or the raw frames with `-raw`. It is a probe for a live
connection, not a recorder; the recorder is `market-recorder`.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/all`.
