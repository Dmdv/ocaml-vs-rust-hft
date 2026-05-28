//! Limit-order-book matching engine — Rust baseline.
//!
//! Implements the shared contract in `spec/protocol.md`: price-time priority, an array price
//! ladder for O(1) best-price access, an index-arena intrusive FIFO per level for O(1) cancel,
//! and an FNV-1a book digest. Trades are appended to a preallocated in-book buffer (no dynamic
//! dispatch, no per-trade allocation once reserved) so the comparison against OCaml is fair.

pub mod book;
pub mod wire;

pub use book::{Book, Side, Trade, SIDE_ASK, SIDE_BID};
pub use wire::{Msg, T_ADD, T_CANCEL, T_MARKET, T_REPLACE};
