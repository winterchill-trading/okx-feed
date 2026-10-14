# AGENTS.md (test/)

Expect tests, normalizer and feed tests, and the recorded fixtures.

- `fixtures/raw/okx/<stream>/BTC-USDT-SWAP/2026/10/12/` holds the first part of a recorded mainnet
  minute per stream, in the `market-recorder` raw layout. Treat it as data: do not edit or regenerate
  it by hand.
- Feed tests drive `Live_feed` against a scripted local websocket server; a malformed frame must
  show in `stats`, and a dropped connection must reconnect on the synthetic clock.
- Promote expect output with `dune promote <file>` for the one file that changed.

Run: `opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/runtest`.
