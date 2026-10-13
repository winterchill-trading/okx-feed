# okx-feed

Read-only public market data from OKX (trades, best bid/offer, L2 order book,
funding) as a `Market_data.Feed.t`. No API keys, no order entry.

- `Okx_feed.Config`: the endpoint (`wss://ws.okx.com:8443/ws/v5/public` by default).
- `Okx_feed.Wire`: JSON shapes of the public channels.
- `Okx_feed.Normalizer`: pure frame -> `Market_data.Event.t` conversion with
  per-book sequencing and the funding merge. `frame` reads `trades`,
  `bbo-tbt` and sequenced `books` pushes with `Scan` and decodes everything
  else with Yojson; `frame_reference` always uses Yojson.
- `Okx_feed.Scan`: `[@zero_alloc]` readers for those three push shapes into
  reused records. Any shape they do not recognise (a reordered `arg`, several
  entries in `data`, escapes, nested objects, numbers they cannot read
  exactly) returns `false` and falls back to Yojson.
- `Okx_feed.Live_feed.create ?on_raw ?time_source config ~symbols ~streams`: one
  reconnecting websocket per stream (from `venue-net`). `Live_feed.start` takes
  the same arguments and keeps a handle: `Live_feed.stats` counts frames,
  frames that did not decode (or were OKX error events) and reconnections.
  `time_source` (default the wall clock) stamps `recv_ts` and drives the
  keepalive and reconnection delays, so tests can run on a synthetic clock.
  `Live_feed.feed_with_gaps` is the same feed with a `gaps` pipe of
  `Market_data.Gap.t` (see [Reconnects and gaps](#reconnects-and-gaps)).
- `Okx_feed.Md_normalizer`: the normalizer as a `Market_data.Normalizer.S`,
  for rebuilding `norm/` event logs from recorded raw minutes with
  `Market_data.Rebuild_norm.run ~normalizers:[ Okx_feed.Md_normalizer.normalizer ]`
  (or a binary mounting `Rebuild_norm.command`).

The channel reference with sample messages and sequencing rules is in
[docs/okx-ws-spec.md](docs/okx-ws-spec.md).

## Coverage

| Stream | OKX channel(s) | Verified live |
| --- | --- | --- |
| `trades` | `trades` | yes |
| `bbo` | `bbo-tbt` | yes |
| `l2` | `books` (400 levels, snapshot + 100 ms deltas, `seqId`/`prevSeqId`) | yes |
| `funding` | `funding-rate` + `mark-price` + `index-tickers` (of the swap's index) | yes |

Verified on 2026-10-12 against mainnet with `BTC-USDT-SWAP` for about 12 s per
stream: 72 trades, 339 BBOs, 1 snapshot + 105 deltas without a sequence gap,
48 funding records, no decode errors.

## Usage

```
dune exec okx-feed -- feed -symbol BTC-USDT-SWAP -streams trades,bbo,l2,funding [-count N] [-raw] [-url URL]
```

`-symbol` may be repeated. `-raw` also prints every received frame to stderr,
prefixed with its stream.

```
$ TZ=UTC okx-feed feed -symbol BTC-USDT-SWAP -streams trades -count 2
(Trade
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:21.147000000Z))
  (recv_ts (2026-10-12 12:49:21.195913000Z)) (price 82932.5) (size 0.01)
  (side Sell) (trade_id 2988536030)))
(Trade
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:21.432000000Z))
  (recv_ts (2026-10-12 12:49:21.499739000Z)) (price 82932.5) (size 0.5)
  (side Sell) (trade_id 2988536031)))

$ TZ=UTC okx-feed feed -symbol BTC-USDT-SWAP -streams bbo -count 1
(Bbo
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:23.105000000Z))
  (recv_ts (2026-10-12 12:49:23.281367000Z)) (bid_price 82932.5)
  (bid_size 323.4) (ask_price 82932.6) (ask_size 366.96)))

$ TZ=UTC okx-feed feed -symbol BTC-USDT-SWAP -streams l2 -count 2   # levels trimmed
(L2
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:30.605000000Z))
  (recv_ts (2026-10-12 12:49:30.916555000Z)) (kind Snapshot)
  (bids
   (((price 82932.5) (size 997.35)) ((price 82932.4) (size 137.3)) ...
  (asks
   (((price 82932.6) (size 112.37)) ((price 82932.7) (size 0.05)) ...
(L2
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:30.705000000Z))
  (recv_ts (2026-10-12 12:49:30.917103000Z)) (kind Delta)
  (bids
   (((price 82932.5) (size 1019.05)) ((price 82932.4) (size 134.89)) ...
  (asks
   (((price 82938.3) (size 0)) ((price 82943.8) (size 0.01)) ...

$ TZ=UTC okx-feed feed -symbol BTC-USDT-SWAP -streams funding -count 1
(Funding
 ((instrument ((venue Okx) (symbol BTC-USDT-SWAP)))
  (exch_ts (2026-10-12 12:49:24.968000000Z))
  (recv_ts (2026-10-12 12:49:25.057966000Z)) (rate 7.93364355466E-05)
  (next_funding_time (2026-10-12 16:00:00.000000000Z)) (mark_price 82932.7)
  (index_price 82970)))
```

## Tests, fixtures and benchmark

`test/fixtures/raw/okx/<stream>/BTC-USDT-SWAP/2026/10/12/16-53.ndjson` holds
the start of a recorded mainnet minute per stream in market-recorder's raw
layout (`<recv_ts> <frame>` per line, 257 KB in all): 149 `trades` pushes, 249
`bbo-tbt` pushes, a 400-level `books` snapshot with 58 deltas, and 119
funding-related pushes, each after its subscription ack. Tests decode and
normalize every frame (no errors; 149 trades, 249 BBOs, 1 snapshot + 58
deltas, 82 funding records), run `Rebuild_norm` over the minute into a temporary
directory and read the event logs back, and drive `Live_feed` against a
scripted local websocket server (a malformed frame shows in `stats`; a dropped
connection is replaced after the first backoff on a synthetic clock and
resubscribed).

`dune exec ./bench/main.exe -- -quota 3` times `Normalizer.frame` on the
recorded frames, and `Normalizer.frame_reference` (the Yojson decoder) in the
`yojson` rows. On an Apple M-series laptop (arm64, `--profile release`, a busy
machine, so times are rounded; CI runs amd64):

| Bench | Yojson (before) | Scanned |
| --- | --- | --- |
| trades (one frame) | 2.4 us, 431 words | 0.48 us, 25 words |
| bbo (one frame) | 2.6 us, 531 words | 0.46 us, 22 words |
| funding (one frame, always Yojson) | 2.1 us, 399 words | 2.4 us, 385 words |
| l2 snapshot (400 levels per side, fresh normalizer) | 0.6 ms, 115k words | 0.11 ms, 5.0k words |
| l2 replay (60 frames: ack, snapshot, 58 deltas) | 2.7 ms, 600k words | 0.51 ms, 31k words |

The dev profile and release with `OCAMLPARAM='_,O3=1'` give the same words
and times within the machine's noise (dev: trades 0.52 us, l2 replay 0.6 to
1.6 ms; O3: trades 0.46 us, l2 replay 0.45 ms). What remains on the scanned
path is the output itself: the event record, its list cell, `Ok` and the
trade id string for a trade, 6 words per level for a book. The snapshot also
allocates the 2 x 1024-level scratch once per normalizer (major heap, 4.1k
words). Funding dropped 14 words per frame when `index-tickers` stopped
sorting every known swap on each push.

`Scan.trade`, `Scan.bbo` and `Scan.book` allocate nothing: they are checked
`[@zero_alloc]` and `test/test_scan.ml` pins 0 words per call.
`test/test_allocation.ml` pins minor words per message on the recorded
minute (trades about 22, bbo 18, books 511 on average and 4844 for the
snapshot, funding 375 (369 on Linux, 382 on macOS); the largest trades and
bbo message is the subscription ack at 209), within 2% because counts differ slightly between macOS and Linux.
`test/test_scanned_path.ml` runs both paths over every recorded frame (149 of
150 trades frames, 249 of 250 bbo frames and 59 of 60 books frames are
scanned; acks fall back) and over hand-written sequencing cases (gap, reset,
heartbeat, unsorted snapshot, several symbols, empty side, unknown side) and
requires identical output.

### Websocket delivery

`Live_feed` takes frames from `Venue_net.Ws_client` through `on_message`, so
each frame goes from the connection's frame pipe straight to the normalizer.
Before, it read `Ws_client.messages` one frame at a time with
`Pipe.iter_without_pushback`, which costs about 13 words per frame for the
hop (see venue-net's README); that path is kept as
`Live_feed.For_testing.start_via_messages`.

`dune exec ./bench/live.exe` writes the recorded trades minute 100 times (15,000
frames) as pre-encoded websocket frames from the in-process fake server in one
burst, and counts minor words over the whole receive phase (socket reads,
framing, delivery, `Normalizer.frame`, pipe writes). arm64, best of 10 runs:

| Build | messages pipe (before) | `on_message` |
| --- | --- | --- |
| dev | 655 to 681 ns, 80.6 words | 594 to 606 ns, 67.5 words |
| release | 655 to 669 ns, 80.6 words | 594 to 606 ns, 67.5 words |
| release, `OCAMLPARAM='_,O3=1'` | 648 ns, 80.5 words | 584 ns, 67.5 words |

`test/test_delivery.ml` runs both deliveries over every recorded stream and
requires identical events, gaps and stats, and pins the words per trades
frame end to end (dev profile, pipes drained after the burst: about 139
before, 126 now, 13 saved; a few words of slack for Linux CI).

## Symbol conventions

Symbols are OKX `instId`s, used unchanged as `Market_data.Symbol`s
(`okx:BTC-USDT-SWAP`):

| Market | Example |
| --- | --- |
| USDT-margined perpetual (preferred) | `BTC-USDT-SWAP` |
| Coin-margined perpetual | `BTC-USD-SWAP` |
| Spot | `BTC-USDT` |
| Dated futures | `BTC-USD-250328` |
| Index (used internally for funding) | `BTC-USDT` |

## Behaviour

- Keepalive: the text frame `ping` every 20 s; two silent intervals replace
  the connection.
- Every (re)connect resubscribes all the stream's channels in one request and
  resets the L2 books, so a reconnect yields a fresh `Snapshot`.
- L2: updates before the first snapshot are dropped; an update whose
  `prevSeqId` does not equal the last `seqId` drops the book and
  unsubscribes/resubscribes the channel, which makes OKX send a new snapshot.
  Heartbeat updates (no levels, `seqId = prevSeqId`) emit nothing; a sequence
  reset after maintenance (`seqId < prevSeqId`, `prevSeqId` joining) is
  accepted.
- Funding: emitted once rate, mark and index are all known, then whenever one
  of them changes (mostly on mark or index moves, every few hundred ms).
  `next_funding_time` is OKX's `fundingTime`, the end of the current period.
- `feed_with_gaps` reports breaks as `Market_data.Gap.t`s, all with reason
  `Resync`, `venue = Okx` and the stream set: one per reconnect of a stream's
  socket (`instrument = None`, every symbol of that connection) and one per L2
  sequence gap (`instrument` set). A gap is written before any event of the new
  connection, or before the new snapshot, and is stamped from `time_source`.
  `feed` is the same feed without that pipe.
- Undecodable frames and OKX `error` events (e.g. `60018` for an unknown
  `instId`) are logged and skipped.

## Reconnects and gaps

The public endpoint has no replay: nothing OKX sends between the old socket's
last frame and the new socket's subscription is ever delivered. The window is

1. detection: immediate on a close or reset; a half-open socket is replaced
   after two silent 20 s ping intervals, so 40 to 60 s after its last frame;
2. backoff: 0.5 s with 20% jitter for the first attempt (0.4 to 0.6 s),
   doubling up to 30 s while attempts fail;
3. connect, TLS and the subscribe round trip.

What the window costs per stream:

| Stream | Lost | Recovered by |
| --- | --- | --- |
| `trades` | every print in the window, for good | nothing (no history on subscribe) |
| `bbo` | intermediate top-of-book changes | the next `bbo-tbt` push (each is a full top of book, about 28 a second) |
| `l2` | intermediate deltas | the `books` snapshot sent on subscribe |
| `funding` | intermediate rate, mark and index changes | the first record once rate, mark and index are all known again: `funding-rate` pushes right after the subscription, `mark-price` within 10 s, `index-tickers` within a minute when the index does not move |

Measured on the synthetic clock (`test/test_live_feed.ml`, loopback server,
socket dropped at t = 0): no connection is opened before 0.39 s; by 0.6 s the
client has reconnected and resubscribed (`connections 2`, `reconnects 1`), the
`Resync` gap (stream `trades`, no instrument) is already in the `gaps` pipe,
stamped 0.600 s, and the first trade of the new socket is stamped
`recv_ts` = 0.600 s. Frames pushed to the old socket after the drop are not
delivered. An L2 sequence gap (`prevSeqId` 12 after `seqId` 10) costs one more
round trip: the client sends `unsubscribe` then `subscribe` for that channel,
drops the deltas in between, and the gap (instrument `okx:BTC-USDT-SWAP`,
stream `l2`) is stamped with the frame that broke the sequence and read before
the new `Snapshot`.

## Limitations

- Sizes are the venue's units: contracts for swaps and futures (one
  `BTC-USDT-SWAP` contract is 0.01 BTC), base currency for spot.
  `Market_data` has no contract multiplier, so consumers must know `ctVal`.
- Trades are OKX's aggregated prints (one per taker order and price; `count`
  is dropped); `trade_id` is the last id of the aggregate. `trades-all` is on
  the business endpoint and is not used.
- `funding` covers perpetual swaps only (symbols ending in `-SWAP`); for
  other symbols the stream opens no connection. `Market_data.Funding` has no
  field for the funding interval or the settled previous rate.
- `books-l2-tbt` / `books50-l2-tbt` (10 ms) need VIP4; the public `books`
  channel updates every 100 ms. The deprecated checksum (always `0`) is not
  checked.
- The `64008` service-upgrade notice is only logged; the connection is
  replaced when OKX actually closes it.
- The gap resubscription path is covered by tests but was not observed live
  (no gap occurred).

## CI

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.
