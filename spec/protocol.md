# Shared Protocol & Matching Spec

This is the **single source of truth** for all three engines (Rust, idiomatic OCaml, OxCaml).
They consume byte-identical input and MUST produce identical trade streams and book digests.
That equality is what makes the benchmark fair: we compare *representations*, not algorithms.

## 1. Wire format

A workload file (`bench/orders.bin`) is a sequence of fixed **24-byte little-endian** records.
File size is always `24 * N`. No header.

| Offset | Size | Field        | Notes |
|-------:|-----:|--------------|-------|
| 0      | u8   | `msg_type`   | 0=Add, 1=Cancel, 2=Replace, 3=Market |
| 1      | u8   | `side`       | 0=Bid (buy), 1=Ask (sell) |
| 2      | u16  | `_pad`       | reserved, 0 |
| 4      | u32  | `order_id`   | unique per Add; references a live order for Cancel/Replace |
| 8      | u32  | `price`      | integer **ticks**; unused for Cancel/Market (0) |
| 12     | u32  | `qty`        | shares; unused for Cancel (0) |
| 16     | u32  | `new_price`  | Replace only (else 0) |
| 20     | u32  | `new_qty`    | Replace only (else 0) |

Prices are integer ticks (no floats — exchanges quote in discrete ticks). Quantities are u32.

## 2. Book model

A single-symbol limit order book with **price-time priority**:
- Two sides: bids (descending price-priority; best = highest), asks (ascending; best = lowest).
- Each price level holds resting orders in **FIFO arrival order** (time priority).
- An order is identified by `order_id`; the book supports O(1) cancel/replace by id.

## 3. Matching semantics

`process(msg)` dispatches on `msg_type`:

### Add (limit order) — `handle_limit(side, id, price, qty)`
```
remaining = qty
while remaining > 0 and exists best opposite level L and crosses(side, price, L.price):
    while remaining > 0 and L not empty:
        resting = L.front          # FIFO
        traded = min(remaining, resting.qty)
        emit Trade{ maker=resting.id, taker=id, price=resting.price, qty=traded, aggressor=side }
        remaining     -= traded
        resting.qty   -= traded
        if resting.qty == 0: remove resting (pop L.front; erase id)
    if L empty: remove level L
if remaining > 0:
    insert resting order {id, side, price, remaining} at BACK of its price level (arrival-time priority)
```
- `crosses(Bid, p, ask_px) = p >= ask_px`; `crosses(Ask, p, bid_px) = p <= bid_px`.
- **Trade price is the resting (maker) price** — the aggressor receives price improvement.
- `order_id` of an Add is assumed unique and not currently resting (the generator guarantees this).

### Market — `handle_market(side, id, qty)`
Identical to `handle_limit` but `crosses(...)` is always true (sweep until liquidity exhausted or
`qty` filled). **Any remainder is discarded** (never rests). No trade if the book side is empty.

### Cancel — `handle_cancel(id)`
If `id` is resting, remove it (and drop the level if it becomes empty). If absent, **no-op**.

### Replace — `handle_replace(id, new_price, new_qty)`
If `id` is not resting, **no-op**. Otherwise let `o` be the resting order:
- If `new_price == o.price` **and** `0 < new_qty <= o.qty`: set `o.qty = new_qty`, **keep time priority** (pure size reduction).
- Else: remove `o`; if `new_qty > 0`, run `handle_limit(o.side, id, new_price, new_qty)` — i.e. it
  **loses time priority** and **may cross/trade** at the new price. (Price change or size increase.)

### Self-trade
Not prevented (we do not track order ownership). Orders match regardless of origin. Documented choice.

## 4. Engine outputs

### Trade stream — `trades.csv`
Header: `seq,maker_id,taker_id,price,qty,aggressor`
- `seq`: 0-based monotonic trade counter.
- `aggressor`: `B` if incoming side is Bid, `S` if Ask.
One row per emitted trade, in emission order. This is compared against `spec/golden_trades.csv`.

### Book digest — `digest.txt`
A 64-bit **FNV-1a** hash over the final resting book, printed as 16-hex-lowercase.
Canonicalization (identical across languages):
1. Collect all resting orders.
2. Sort by `(side asc, price asc, seq asc)` where `seq` is insertion order (a per-book monotonic
   counter assigned when an order first rests).
3. For each, feed these bytes (little-endian) into FNV-1a-64:
   `order_id:u32`, `side:u8`, `price:u32`, `qty:u32`.
4. FNV-1a-64: `offset = 0xcbf29ce484222325`, `prime = 0x100000001b3`; for each byte `b`:
   `h = (h XOR b) * prime` (wrapping u64).

The digest catches any divergence in resting state that trades alone might miss.

## 5. Harness contract (per engine)

Each engine ships a `harness` binary that:
1. Reads `orders.bin` fully into memory.
2. Processes every message, timing **each `process` call** in nanoseconds.
3. Discards the first 10% as warmup; writes remaining per-op latencies to `latencies.csv`
   (one integer nanosecond per line, no header).
4. Writes `trades.csv` and `digest.txt`.
5. Prints a summary: `THROUGHPUT msgs=<n> elapsed_ns=<t>` and, where measurable,
   `ALLOC minor_words=<w> major_words=<w>` (OCaml) or `ALLOC bytes=<b> allocs=<n>` (Rust).

Determinism: given the same `orders.bin`, every engine yields identical `trades.csv` + `digest.txt`.
