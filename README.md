# okx-feed

Read-only public market data from OKX (trades, best bid/offer, L2 order book,
funding) as a `Market_data.Feed.t`. No API keys, no order entry.

- `Okx_feed.Config`: the endpoint (`wss://ws.okx.com:8443/ws/v5/public` by default).
- `Okx_feed.Wire`: JSON shapes of the public channels.
- `Okx_feed.Normalizer`: pure frame -> `Market_data.Event.t` conversion with
  per-book sequencing and the funding merge.
- `Okx_feed.Live_feed.create ?on_raw ?time_source config ~symbols ~streams`: one
  reconnecting websocket per stream (from `venue-net`). `Live_feed.start` takes
  the same arguments and keeps a handle: `Live_feed.stats` counts frames,
  frames that did not decode (or were OKX error events) and reconnections.
  `time_source` (default the wall clock) stamps `recv_ts` and drives the
  keepalive and reconnection delays, so tests can run on a synthetic clock.
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
recorded frames. On an Apple M-series laptop:

| Bench | Time per run | Minor words per run |
| --- | --- | --- |
| trades (one frame) | 2.4 us | 431 |
| bbo (one frame) | 2.5 us | 531 |
| funding (one frame) | 2.1 us | 399 |
| l2 replay (60 frames: ack, 400-level snapshot, 58 deltas) | 2.7 ms | 600k |

`test/test_allocation.ml` pins minor words per message (trades about 427,
bbo 528, funding 396, books 10k on average and 115k for the snapshot), within
2% because counts differ slightly between macOS and Linux.

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
- Undecodable frames and OKX `error` events (e.g. `60018` for an unknown
  `instId`) are logged and skipped.

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
