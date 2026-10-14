# AGENTS.md (lib/)

The `Okx_feed` library.

- `Config`: the public websocket endpoint (default `wss://ws.okx.com:8443/ws/v5/public`).
- `Wire`: JSON shapes of the public channels. `Normalizer` turns frames into `Market_data.Event.t`
  purely, with per-book sequencing and the funding merge.
- `Live_feed`: one reconnecting `Venue_net.Ws_client` per stream, with `stats` for frames,
  parse errors and reconnects. `time_source` stamps `recv_ts` and drives keepalive and backoff.
- `Md_normalizer`: the normalizer as a `Market_data.Normalizer.S`, used to rebuild normalized files
  from recorded raw minutes.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @okx-feed/all`.
