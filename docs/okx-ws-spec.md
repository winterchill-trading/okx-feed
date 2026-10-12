# OKX v5 public websocket: the parts this feed uses

Source: the OKX API v5 reference (`https://www.okx.com/docs-v5/en/`), sections
"WebSocket", "Order book trading / Market data" and "Public data". Only public
channels are used: no login, no API keys.

## Endpoints

| Use | URL |
| --- | --- |
| Public (trades, books, bbo-tbt, tickers, funding-rate, mark-price, index-tickers) | `wss://ws.okx.com:8443/ws/v5/public` (also served without `:8443`) |
| Business (`trades-all`, candles; not used here) | `wss://ws.okx.com:8443/ws/v5/business` |
| Demo trading public | `wss://wspap.okx.com:8443/ws/v5/public` |

## Requests

Subscribe (unsubscribe is the same with `"op": "unsubscribe"`). `id` is optional,
up to 32 alphanumerics, echoed in the response. One message may carry several
`args`; the whole message must stay under 64 KB.

```json
{"id": "1512", "op": "subscribe", "args": [{"channel": "trades", "instId": "BTC-USDT-SWAP"}]}
```

Ack:

```json
{"id": "1512", "event": "subscribe", "arg": {"channel": "trades", "instId": "BTC-USDT-SWAP"}, "connId": "a4d3ae55"}
```

Error:

```json
{"id": "1512", "event": "error", "code": "60012", "msg": "Invalid request: ...", "connId": "a4d3ae55"}
```

Service notice, sent about 60 s before the server drops the connection for an
upgrade (reconnect proactively):

```json
{"event": "notice", "code": "64008", "msg": "The connection will soon be closed for a service upgrade. Please reconnect.", "connId": "a4d3ae55"}
```

Every push has the shape `{"arg": {"channel", "instId"}, ["action",] "data": [...]}`.
All numbers except `seqId`, `prevSeqId` and `checksum` are JSON strings; times are
milliseconds since the epoch, as strings.

## Channels

### `trades` (public)

One message per taker order, fill price and source; `count` trades are
aggregated and `tradeId` is the last one. `side` is the taker side. `sz` is in
contracts for SWAP/FUTURES/OPTION and in base currency for SPOT.

```json
{"arg": {"channel": "trades", "instId": "BTC-USDT"},
 "data": [{"instId": "BTC-USDT", "tradeId": "130639474", "px": "42219.9", "sz": "0.12060306",
           "side": "buy", "ts": "1630048897897", "count": "3", "source": "0", "seqId": 1234}]}
```

`trades-all` (business endpoint) sends one message per individual trade; not used.

### `bbo-tbt` (public)

Top of book, a fresh one-level snapshot whenever it changes (at most every
10 ms). No `action`. Levels are `[price, size, "0" (deprecated), order count]`.
`ts` is the matching engine time.

```json
{"arg": {"channel": "bbo-tbt", "instId": "BCH-USDT-SWAP"},
 "data": [{"asks": [["111.06", "55154", "0", "2"]], "bids": [["111.05", "57745", "0", "2"]],
           "ts": "1670324386802", "seqId": 363996337}]}
```

`tickers` also carries `bidPx/bidSz/askPx/askSz` but is throttled; `bbo-tbt` is
preferred.

### Order books

| Channel | Depth | Updates | Access |
| --- | --- | --- | --- |
| `books` | 400 | snapshot then deltas every 100 ms | public |
| `books5` | 5 | full 5-level snapshot every 100 ms on change | public |
| `bbo-tbt` | 1 | full snapshot every 10 ms on change | public |
| `books50-l2-tbt` | 50 | snapshot then deltas every 10 ms | VIP4+ only (else error `64003`) |
| `books-l2-tbt` | 400 | snapshot then deltas every 10 ms | VIP4+ only |

This feed uses `books` for L2: it is the only incremental book open to anyone.
`books-l2-tbt` and `books50-l2-tbt` cannot be combined with `books` for one
instrument.

```json
{"arg": {"channel": "books", "instId": "BTC-USDT"}, "action": "snapshot",
 "data": [{"asks": [["8476.98", "415", "0", "13"], ["8477", "7", "0", "2"]],
           "bids": [["8476.97", "256", "0", "12"], ["8475.55", "101", "0", "1"]],
           "ts": "1597026383085", "checksum": 0, "prevSeqId": -1, "seqId": 123456}]}
```

```json
{"arg": {"channel": "books", "instId": "BTC-USDT"}, "action": "update",
 "data": [{"asks": [["8476.98", "0", "0", "0"]], "bids": [["8476.97", "300", "0", "13"]],
           "ts": "1597026383185", "checksum": 0, "prevSeqId": 123456, "seqId": 123457}]}
```

A level with size `"0"` in an update deletes that price.

#### Sequencing

- Each `instId` has its own sequence. A snapshot has `prevSeqId = -1`.
- An update is in sequence when its `prevSeqId` equals the `seqId` of the
  previous message. Anything else is a gap: drop the book and resubscribe (the
  server answers a subscription with a fresh snapshot).
- Usually `seqId > prevSeqId`. With no book change for about 60 s the server
  sends a heartbeat update with empty `asks`/`bids` and `seqId = prevSeqId`
  (same as the last message). After maintenance the sequence may be reset: an
  update arrives with `seqId < prevSeqId`; it is still in sequence when
  `prevSeqId` matches, and later messages continue from the new `seqId`.
- Updates received before the first snapshot are dropped.

Example from the reference: snapshot (`-1`, `10`), update (`10`, `15`),
heartbeat (`15`, `15`), reset (`15`, `3`), update (`3`, `5`).

#### Checksum

`checksum` is deprecated: still present on `books`, `books-l2-tbt` and
`books50-l2-tbt` but always `0`. The reference says to use `seqId`/`prevSeqId`
only. (The old CRC32 over interleaved `bid:size:ask:size` strings of the top 25
levels is no longer sent and is not checked here.)

### `funding-rate` (public)

SWAP only. Pushed every 30 to 90 s. `fundingTime` is the settlement time of the
current period (the next payment), `nextFundingTime` the one after it.
`fundingRate` applies to the current period; the interval (8 h, sometimes 4, 2
or 1 h) is `nextFundingTime - fundingTime`.

```json
{"arg": {"channel": "funding-rate", "instId": "BTC-USD-SWAP"},
 "data": [{"formulaType": "noRate", "fundingRate": "0.0001875391284828", "fundingTime": "1700726400000",
           "impactValue": "", "instId": "BTC-USD-SWAP", "instType": "SWAP", "interestRate": "",
           "method": "current_period", "maxFundingRate": "0.00375", "minFundingRate": "-0.00375",
           "nextFundingRate": "", "nextFundingTime": "1700755200000", "premium": "0.0001233824646391",
           "settFundingRate": "0.0001699799259033", "settState": "settled", "ts": "1700724675402"}]}
```

The funding message has no mark or index price, so the feed also subscribes:

### `mark-price` (public)

Pushed every 200 ms on change, else every 10 s.

```json
{"arg": {"channel": "mark-price", "instId": "BTC-USDT-SWAP"},
 "data": [{"instType": "SWAP", "instId": "BTC-USDT-SWAP", "markPx": "42310.6", "ts": "1597026383085"}]}
```

### `index-tickers` (public)

The index of a swap `BASE-QUOTE-SWAP` is `BASE-QUOTE` (e.g. `BTC-USDT-SWAP` ->
`BTC-USDT`, `BTC-USD-SWAP` -> `BTC-USD`). Pushed every 100 ms on change, else
once a minute.

```json
{"arg": {"channel": "index-tickers", "instId": "BTC-USDT"},
 "data": [{"instId": "BTC-USDT", "idxPx": "42300.1", "high24h": "0.5", "low24h": "0.1",
           "open24h": "0.1", "sodUtc0": "0.1", "sodUtc8": "0.1", "ts": "1597026383085"}]}
```

## Keepalive

- The server closes a connection with no subscription, or with no data pushed,
  for 30 s.
- Client keepalive: when nothing has been received for N < 30 s, send the text
  frame `ping`; the server answers the text frame `pong` (not JSON). No answer
  within N s means reconnect.
- The feed sends `ping` every 20 s and treats two silent intervals as a dead
  connection.

## Limits

- New connections: 3 per second per IP.
- `subscribe` + `unsubscribe` + `login`: 480 per hour per connection.
- One subscribe message: at most 64 KB.
- Many 50/400-level book channels: use several connections, fewer than 30
  channels each.

## Instrument naming

`instId` is the venue symbol: spot `BTC-USDT`, USDT-margined perpetual
`BTC-USDT-SWAP`, coin-margined perpetual `BTC-USD-SWAP`, futures
`BTC-USD-250328`, options `BTC-USD-250328-100000-C`, indexes `BTC-USDT`.

## Observed on mainnet (2026-10-12, `BTC-USDT-SWAP`)

- Each `args` entry is acknowledged by its own `{"event":"subscribe", ...}` message.
- `books` sends one `snapshot` (400 levels per side) then `update`s about every
  100 ms; `checksum` is `0` in every message; `seqId` values exceed 2^31
  (`345495908317`), so they need 63-bit ints.
- `funding-rate` pushes once right after the subscription, then every 30 to 90 s.
  It also carries `prevFundingTime`, not in the reference.
- `mark-price` pushes every 200 ms while the mark moves; `index-tickers` every
  few hundred ms.
- `bbo-tbt` produced about 28 messages a second, `trades` about 6.
- Closing the socket from the client side is reported by the server as a TCP
  close without a websocket Close frame.
