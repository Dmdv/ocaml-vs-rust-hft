//! The order book + matching engine.

use crate::wire::{Msg, T_ADD, T_CANCEL, T_MARKET, T_REPLACE};
use std::collections::HashMap;

pub type Side = u8;
pub const SIDE_BID: Side = 0;
pub const SIDE_ASK: Side = 1;

/// Price ticks are bounded so the ladder is a flat array (real low-latency engines do this).
/// The generator keeps prices well inside this range.
pub const MAX_PRICE: usize = 20_000;
const NIL: u32 = u32::MAX;

/// One execution. `price` is always the resting (maker) price — the aggressor gets improvement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Trade {
    pub maker: u32,
    pub taker: u32,
    pub price: u32,
    pub qty: u32,
    pub aggressor: Side,
}

/// Output sink. Generic + monomorphized => zero-cost; the hot path never allocates for trades.
pub trait TradeSink {
    fn trade(&mut self, t: Trade);
}

impl TradeSink for Vec<Trade> {
    #[inline(always)]
    fn trade(&mut self, t: Trade) {
        self.push(t);
    }
}

/// A counting sink for benchmarks: no allocation, no growth.
#[derive(Default)]
pub struct CountSink {
    pub trades: u64,
    pub volume: u64,
}
impl TradeSink for CountSink {
    #[inline(always)]
    fn trade(&mut self, t: Trade) {
        self.trades += 1;
        self.volume += t.qty as u64;
    }
}

struct Node {
    id: u32,
    side: Side,
    price: u32,
    qty: u32,
    prev: u32,
    next: u32,
}

#[derive(Clone, Copy)]
struct Level {
    head: u32,
    tail: u32,
}
impl Level {
    const EMPTY: Level = Level { head: NIL, tail: NIL };
}

pub struct Book {
    nodes: Vec<Node>,
    free: Vec<u32>,
    bids: Vec<Level>,
    asks: Vec<Level>,
    id_to_idx: HashMap<u32, u32>,
    bb: i32, // best bid price, -1 when no bids
    ba: i32, // best ask price, MAX_PRICE when no asks
}

impl Default for Book {
    fn default() -> Self {
        Self::new()
    }
}

impl Book {
    pub fn new() -> Self {
        Book {
            nodes: Vec::with_capacity(1 << 20),
            free: Vec::new(),
            bids: vec![Level::EMPTY; MAX_PRICE],
            asks: vec![Level::EMPTY; MAX_PRICE],
            id_to_idx: HashMap::with_capacity(1 << 20),
            bb: -1,
            ba: MAX_PRICE as i32,
        }
    }

    #[inline]
    pub fn best_bid(&self) -> Option<u32> {
        if self.bb >= 0 {
            Some(self.bb as u32)
        } else {
            None
        }
    }
    #[inline]
    pub fn best_ask(&self) -> Option<u32> {
        if self.ba < MAX_PRICE as i32 {
            Some(self.ba as u32)
        } else {
            None
        }
    }
    pub fn order_qty(&self, id: u32) -> Option<u32> {
        self.id_to_idx.get(&id).map(|&i| self.nodes[i as usize].qty)
    }
    pub fn resting_count(&self) -> usize {
        self.id_to_idx.len()
    }

    /// Structural + semantic consistency checks, for property tests:
    /// book never crossed; every resting order has qty>0, is filed under the right side/price,
    /// has intact links and an id-map entry; reachable count matches the id map; and the tracked
    /// best prices equal the true extremes.
    pub fn check_invariants(&self) -> Result<(), String> {
        if self.bb >= 0 && self.ba < MAX_PRICE as i32 && self.bb >= self.ba {
            return Err(format!("crossed book: bb={} ba={}", self.bb, self.ba));
        }
        let mut counted = 0usize;
        let mut max_bid = -1i32;
        let mut min_ask = MAX_PRICE as i32;
        for (ladder, side) in [(&self.bids, SIDE_BID), (&self.asks, SIDE_ASK)] {
            for p in 1..MAX_PRICE {
                let mut cur = ladder[p].head;
                let mut prev = NIL;
                let mut last = NIL;
                while cur != NIL {
                    let n = &self.nodes[cur as usize];
                    if n.qty == 0 {
                        return Err(format!("zero-qty resting id={}", n.id));
                    }
                    if n.side != side || n.price as usize != p {
                        return Err(format!("misfiled order id={}", n.id));
                    }
                    if n.prev != prev {
                        return Err(format!("broken prev link at id={}", n.id));
                    }
                    match self.id_to_idx.get(&n.id) {
                        Some(&i) if i == cur => {}
                        _ => return Err(format!("id map inconsistent for id={}", n.id)),
                    }
                    if side == SIDE_BID {
                        max_bid = max_bid.max(p as i32);
                    } else {
                        min_ask = min_ask.min(p as i32);
                    }
                    counted += 1;
                    prev = cur;
                    last = cur;
                    cur = n.next;
                }
                if ladder[p].tail != last {
                    return Err(format!("broken tail at price {p}"));
                }
            }
        }
        if counted != self.id_to_idx.len() {
            return Err(format!("reachable {} != id_map {}", counted, self.id_to_idx.len()));
        }
        if max_bid != self.bb {
            return Err(format!("stale best bid: tracked {} actual {}", self.bb, max_bid));
        }
        if min_ask != self.ba {
            return Err(format!("stale best ask: tracked {} actual {}", self.ba, min_ask));
        }
        Ok(())
    }

    #[inline]
    pub fn process<S: TradeSink>(&mut self, m: &Msg, sink: &mut S) {
        match m.msg_type {
            T_ADD => self.handle_limit(m.side, m.order_id, m.price, m.qty, sink),
            T_MARKET => self.handle_market(m.side, m.order_id, m.qty, sink),
            T_CANCEL => self.handle_cancel(m.order_id),
            T_REPLACE => self.handle_replace(m.order_id, m.new_price, m.new_qty, sink),
            _ => {}
        }
    }

    #[inline]
    fn handle_limit<S: TradeSink>(&mut self, side: Side, id: u32, price: u32, qty: u32, sink: &mut S) {
        let rem = self.cross(side, id, qty, price, sink);
        if rem > 0 {
            self.rest(id, side, price, rem);
        }
    }

    #[inline]
    fn handle_market<S: TradeSink>(&mut self, side: Side, id: u32, qty: u32, sink: &mut S) {
        let limit = if side == SIDE_BID { u32::MAX } else { 0 };
        let _discarded = self.cross(side, id, qty, limit, sink);
    }

    fn handle_cancel(&mut self, id: u32) {
        if let Some(&idx) = self.id_to_idx.get(&id) {
            self.unlink_and_free(idx);
            self.id_to_idx.remove(&id);
        }
    }

    fn handle_replace<S: TradeSink>(&mut self, id: u32, new_price: u32, new_qty: u32, sink: &mut S) {
        let idx = match self.id_to_idx.get(&id) {
            Some(&i) => i,
            None => return,
        };
        let side = self.nodes[idx as usize].side;
        let price = self.nodes[idx as usize].price;
        let qty = self.nodes[idx as usize].qty;
        if new_price == price && new_qty > 0 && new_qty <= qty {
            // pure size reduction at same price keeps time priority
            self.nodes[idx as usize].qty = new_qty;
        } else {
            self.unlink_and_free(idx);
            self.id_to_idx.remove(&id);
            if new_qty > 0 {
                self.handle_limit(side, id, new_price, new_qty, sink);
            }
        }
    }

    /// Match `qty` from the aggressor `side` against resting orders while the price crosses
    /// `limit`. Returns the unfilled remainder. `limit` is the aggressor's price for a limit
    /// order, or `u32::MAX` (buy) / `0` (sell) for a market order.
    fn cross<S: TradeSink>(&mut self, side: Side, taker: u32, mut qty: u32, limit: u32, sink: &mut S) -> u32 {
        if side == SIDE_BID {
            while qty > 0 {
                let ba = self.ba;
                if ba >= MAX_PRICE as i32 || (ba as u32) > limit {
                    break;
                }
                let ap = ba as usize;
                while qty > 0 {
                    let h = self.asks[ap].head;
                    if h == NIL {
                        break;
                    }
                    let maker_id = self.nodes[h as usize].id;
                    let node_qty = self.nodes[h as usize].qty;
                    let traded = if qty < node_qty { qty } else { node_qty };
                    self.nodes[h as usize].qty = node_qty - traded;
                    qty -= traded;
                    sink.trade(Trade { maker: maker_id, taker, price: ap as u32, qty: traded, aggressor: SIDE_BID });
                    if self.nodes[h as usize].qty == 0 {
                        let nxt = self.nodes[h as usize].next;
                        self.asks[ap].head = nxt;
                        if nxt == NIL {
                            self.asks[ap].tail = NIL;
                        } else {
                            self.nodes[nxt as usize].prev = NIL;
                        }
                        self.id_to_idx.remove(&maker_id);
                        self.free.push(h);
                    }
                }
                if self.asks[ap].head == NIL {
                    self.advance_best_ask();
                }
            }
        } else {
            while qty > 0 {
                let bb = self.bb;
                if bb < 0 || (bb as u32) < limit {
                    break;
                }
                let bp = bb as usize;
                while qty > 0 {
                    let h = self.bids[bp].head;
                    if h == NIL {
                        break;
                    }
                    let maker_id = self.nodes[h as usize].id;
                    let node_qty = self.nodes[h as usize].qty;
                    let traded = if qty < node_qty { qty } else { node_qty };
                    self.nodes[h as usize].qty = node_qty - traded;
                    qty -= traded;
                    sink.trade(Trade { maker: maker_id, taker, price: bp as u32, qty: traded, aggressor: SIDE_ASK });
                    if self.nodes[h as usize].qty == 0 {
                        let nxt = self.nodes[h as usize].next;
                        self.bids[bp].head = nxt;
                        if nxt == NIL {
                            self.bids[bp].tail = NIL;
                        } else {
                            self.nodes[nxt as usize].prev = NIL;
                        }
                        self.id_to_idx.remove(&maker_id);
                        self.free.push(h);
                    }
                }
                if self.bids[bp].head == NIL {
                    self.advance_best_bid();
                }
            }
        }
        qty
    }

    fn rest(&mut self, id: u32, side: Side, price: u32, qty: u32) {
        debug_assert!((price as usize) < MAX_PRICE);
        let idx = self.alloc(Node { id, side, price, qty, prev: NIL, next: NIL });
        let p = price as usize;
        let tail = if side == SIDE_BID { self.bids[p].tail } else { self.asks[p].tail };
        if tail == NIL {
            if side == SIDE_BID {
                self.bids[p] = Level { head: idx, tail: idx };
            } else {
                self.asks[p] = Level { head: idx, tail: idx };
            }
        } else {
            self.nodes[tail as usize].next = idx;
            self.nodes[idx as usize].prev = tail;
            if side == SIDE_BID {
                self.bids[p].tail = idx;
            } else {
                self.asks[p].tail = idx;
            }
        }
        self.id_to_idx.insert(id, idx);
        if side == SIDE_BID {
            if price as i32 > self.bb {
                self.bb = price as i32;
            }
        } else if (price as i32) < self.ba {
            self.ba = price as i32;
        }
    }

    fn unlink_and_free(&mut self, idx: u32) {
        let side = self.nodes[idx as usize].side;
        let price = self.nodes[idx as usize].price;
        let prev = self.nodes[idx as usize].prev;
        let next = self.nodes[idx as usize].next;
        if prev != NIL {
            self.nodes[prev as usize].next = next;
        }
        if next != NIL {
            self.nodes[next as usize].prev = prev;
        }
        let p = price as usize;
        let emptied;
        if side == SIDE_BID {
            if self.bids[p].head == idx {
                self.bids[p].head = next;
            }
            if self.bids[p].tail == idx {
                self.bids[p].tail = prev;
            }
            emptied = self.bids[p].head == NIL;
        } else {
            if self.asks[p].head == idx {
                self.asks[p].head = next;
            }
            if self.asks[p].tail == idx {
                self.asks[p].tail = prev;
            }
            emptied = self.asks[p].head == NIL;
        }
        self.free.push(idx);
        if emptied {
            if side == SIDE_BID && self.bb == price as i32 {
                self.advance_best_bid();
            }
            if side == SIDE_ASK && self.ba == price as i32 {
                self.advance_best_ask();
            }
        }
    }

    #[inline]
    fn advance_best_ask(&mut self) {
        let mut p = self.ba + 1;
        while (p as usize) < MAX_PRICE && self.asks[p as usize].head == NIL {
            p += 1;
        }
        self.ba = if (p as usize) < MAX_PRICE { p } else { MAX_PRICE as i32 };
    }

    #[inline]
    fn advance_best_bid(&mut self) {
        let mut p = self.bb - 1;
        while p >= 1 && self.bids[p as usize].head == NIL {
            p -= 1;
        }
        self.bb = if p >= 1 { p } else { -1 };
    }

    #[inline]
    fn alloc(&mut self, n: Node) -> u32 {
        if let Some(i) = self.free.pop() {
            self.nodes[i as usize] = n;
            i
        } else {
            self.nodes.push(n);
            (self.nodes.len() - 1) as u32
        }
    }

    /// FNV-1a-64 over the canonicalized resting book (see spec §4). Iterating each side's ladder
    /// ascending, head->tail, yields `(side asc, price asc, seq asc)` ordering by construction.
    pub fn digest(&self) -> u64 {
        const PRIME: u64 = 0x100000001b3;
        let mut h: u64 = 0xcbf29ce484222325;
        let feed_u32 = |h: &mut u64, v: u32| {
            for b in v.to_le_bytes() {
                *h ^= b as u64;
                *h = h.wrapping_mul(PRIME);
            }
        };
        for ladder in [&self.bids, &self.asks] {
            for level in ladder {
                let mut cur = level.head;
                while cur != NIL {
                    let n = &self.nodes[cur as usize];
                    feed_u32(&mut h, n.id);
                    h ^= n.side as u64;
                    h = h.wrapping_mul(PRIME);
                    feed_u32(&mut h, n.price);
                    feed_u32(&mut h, n.qty);
                    cur = n.next;
                }
            }
        }
        h
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(side: Side, id: u32, price: u32, qty: u32) -> Msg {
        Msg { msg_type: T_ADD, side, order_id: id, price, qty, new_price: 0, new_qty: 0 }
    }
    fn run(book: &mut Book, m: Msg) -> Vec<Trade> {
        let mut s = Vec::new();
        book.process(&m, &mut s);
        s
    }

    #[test]
    fn add_rests_without_crossing() {
        let mut b = Book::new();
        assert!(run(&mut b, add(SIDE_BID, 1, 100, 10)).is_empty());
        assert_eq!(b.best_bid(), Some(100));
        assert_eq!(b.best_ask(), None);
        assert_eq!(b.resting_count(), 1);
    }

    #[test]
    fn crossing_limit_partial_fill_at_maker_price() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_ASK, 1, 100, 5));
        // incoming aggressive buy at 105 should trade at the maker's 100 (price improvement)
        let t = run(&mut b, add(SIDE_BID, 2, 105, 3));
        assert_eq!(t, vec![Trade { maker: 1, taker: 2, price: 100, qty: 3, aggressor: SIDE_BID }]);
        assert_eq!(b.order_qty(1), Some(2)); // resting ask reduced
        assert_eq!(b.best_ask(), Some(100));
        assert_eq!(b.best_bid(), None); // fully filled aggressor doesn't rest
    }

    #[test]
    fn sweeps_multiple_levels_in_price_then_time_priority() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_ASK, 1, 100, 2));
        run(&mut b, add(SIDE_ASK, 2, 101, 2));
        let t = run(&mut b, add(SIDE_BID, 3, 101, 3));
        assert_eq!(
            t,
            vec![
                Trade { maker: 1, taker: 3, price: 100, qty: 2, aggressor: SIDE_BID },
                Trade { maker: 2, taker: 3, price: 101, qty: 1, aggressor: SIDE_BID },
            ]
        );
        assert_eq!(b.order_qty(2), Some(1));
        assert_eq!(b.best_ask(), Some(101));
    }

    #[test]
    fn fifo_time_priority_within_a_level() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_ASK, 1, 100, 2)); // earlier
        run(&mut b, add(SIDE_ASK, 2, 100, 2)); // later
        let t = run(&mut b, add(SIDE_BID, 3, 100, 3));
        // order 1 (earlier) fully fills first, then order 2 partially
        assert_eq!(
            t,
            vec![
                Trade { maker: 1, taker: 3, price: 100, qty: 2, aggressor: SIDE_BID },
                Trade { maker: 2, taker: 3, price: 100, qty: 1, aggressor: SIDE_BID },
            ]
        );
        assert_eq!(b.order_qty(1), None);
        assert_eq!(b.order_qty(2), Some(1));
    }

    #[test]
    fn market_order_consumes_then_discards_remainder() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_ASK, 1, 100, 2));
        let mkt = Msg { msg_type: T_MARKET, side: SIDE_BID, order_id: 9, price: 0, qty: 5, new_price: 0, new_qty: 0 };
        let t = run(&mut b, mkt);
        assert_eq!(t, vec![Trade { maker: 1, taker: 9, price: 100, qty: 2, aggressor: SIDE_BID }]);
        assert_eq!(b.resting_count(), 0); // remainder (3) discarded, nothing rests
    }

    #[test]
    fn market_on_empty_book_is_noop() {
        let mut b = Book::new();
        let mkt = Msg { msg_type: T_MARKET, side: SIDE_ASK, order_id: 9, price: 0, qty: 5, new_price: 0, new_qty: 0 };
        assert!(run(&mut b, mkt).is_empty());
    }

    #[test]
    fn cancel_present_and_absent() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_BID, 1, 100, 10));
        run(&mut b, add(SIDE_BID, 2, 99, 10));
        let cancel = |id| Msg { msg_type: T_CANCEL, side: 0, order_id: id, price: 0, qty: 0, new_price: 0, new_qty: 0 };
        run(&mut b, cancel(1));
        assert_eq!(b.order_qty(1), None);
        assert_eq!(b.best_bid(), Some(99)); // best advanced down
        run(&mut b, cancel(999)); // absent: no panic, no change
        assert_eq!(b.resting_count(), 1);
    }

    #[test]
    fn replace_size_down_keeps_priority() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_ASK, 1, 100, 5));
        run(&mut b, add(SIDE_ASK, 2, 100, 5)); // behind order 1
        let repl = Msg { msg_type: T_REPLACE, side: 0, order_id: 1, price: 0, qty: 0, new_price: 100, new_qty: 2 };
        run(&mut b, repl);
        assert_eq!(b.order_qty(1), Some(2));
        // order 1 still ahead: a buy of 2 hits order 1 first
        let t = run(&mut b, add(SIDE_BID, 3, 100, 2));
        assert_eq!(t, vec![Trade { maker: 1, taker: 3, price: 100, qty: 2, aggressor: SIDE_BID }]);
    }

    #[test]
    fn replace_price_change_loses_priority_and_can_cross() {
        let mut b = Book::new();
        run(&mut b, add(SIDE_BID, 1, 100, 5)); // resting bid
        run(&mut b, add(SIDE_ASK, 2, 105, 5)); // resting ask
        // reprice the resting bid up to 105 -> it should cross the ask and trade at 105 (maker)
        let repl = Msg { msg_type: T_REPLACE, side: 0, order_id: 1, price: 0, qty: 0, new_price: 105, new_qty: 5 };
        let t = run(&mut b, repl);
        assert_eq!(t, vec![Trade { maker: 2, taker: 1, price: 105, qty: 5, aggressor: SIDE_BID }]);
        assert_eq!(b.resting_count(), 0);
    }

    #[test]
    fn digest_is_order_independent_of_arena_reuse() {
        // Two books reaching the same resting state via different paths must share a digest.
        let mut a = Book::new();
        run(&mut a, add(SIDE_BID, 1, 100, 10));
        run(&mut a, add(SIDE_ASK, 2, 200, 5));

        let mut c = Book::new();
        run(&mut c, add(SIDE_BID, 7, 100, 10)); // different id -> different digest expected
        run(&mut c, add(SIDE_ASK, 8, 200, 5));
        assert_ne!(a.digest(), c.digest());

        let mut d = Book::new();
        run(&mut d, add(SIDE_ASK, 2, 200, 5)); // same orders, inserted in different order
        run(&mut d, add(SIDE_BID, 1, 100, 10));
        assert_eq!(a.digest(), d.digest());
    }
}
