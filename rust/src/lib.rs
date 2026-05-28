//! Limit-order-book matching engine — Rust baseline.
//!
//! Implements the shared contract in `spec/protocol.md`: price-time priority, an array price
//! ladder for O(1) best-price access, an index-arena intrusive FIFO per level for O(1) cancel,
//! and an FNV-1a book digest. The engine is generic over a [`TradeSink`] so the hot path never
//! allocates for output (the harness uses a preallocated sink, benches use a counting sink).

pub mod book;
pub mod wire;

pub use book::{Book, CountSink, Side, Trade, TradeSink, SIDE_ASK, SIDE_BID};
pub use wire::{Msg, T_ADD, T_CANCEL, T_MARKET, T_REPLACE};
