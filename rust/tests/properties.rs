//! Property tests: the engine maintains its invariants under arbitrary valid message streams,
//! and is deterministic. We synthesize *valid* streams (Add ids are unique and never reuse a
//! live id, per spec) from raw proptest data, then assert invariants after every message.

use lob::{Book, Msg, Trade, T_ADD, T_CANCEL, T_MARKET, T_REPLACE};
use proptest::prelude::*;

/// Raw per-action data; mapped to a valid `Msg` against live-id state in the test body.
#[derive(Clone, Copy, Debug)]
struct Action {
    kind: u8,  // 0=add 1=cancel 2=replace 3=market
    side: u8,  // 0=bid 1=ask
    price: u32,
    qty: u32,
    new_price: u32,
    new_qty: u32,
    sel: usize, // selects a live order for cancel/replace
}

fn action() -> impl Strategy<Value = Action> {
    (0u8..4, 0u8..2, 1u32..200, 1u32..50, 1u32..200, 0u32..50, 0usize..10_000).prop_map(
        |(kind, side, price, qty, new_price, new_qty, sel)| Action {
            kind,
            side,
            price,
            qty,
            new_price,
            new_qty,
            sel,
        },
    )
}

/// Turn raw actions into a valid message stream (monotonic unique Add ids; cancel/replace only
/// target ids we have handed out). Returns the messages actually issued.
fn build(actions: &[Action]) -> Vec<Msg> {
    let mut out = Vec::with_capacity(actions.len());
    let mut next_id = 1u32;
    let mut live: Vec<u32> = Vec::new();
    for a in actions {
        let m = match a.kind {
            1 if !live.is_empty() => {
                let id = live.swap_remove(a.sel % live.len());
                Msg { msg_type: T_CANCEL, side: 0, order_id: id, price: 0, qty: 0, new_price: 0, new_qty: 0 }
            }
            2 if !live.is_empty() => {
                let id = live[a.sel % live.len()];
                Msg { msg_type: T_REPLACE, side: 0, order_id: id, price: 0, qty: 0, new_price: a.new_price, new_qty: a.new_qty }
            }
            3 => Msg { msg_type: T_MARKET, side: a.side, order_id: { let id = next_id; next_id += 1; id }, price: 0, qty: a.qty, new_price: 0, new_qty: 0 },
            _ => {
                // Add (also the fallback when cancel/replace have no live orders)
                let id = next_id;
                next_id += 1;
                live.push(id);
                Msg { msg_type: T_ADD, side: a.side, order_id: id, price: a.price, qty: a.qty, new_price: 0, new_qty: 0 }
            }
        };
        out.push(m);
    }
    out
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn invariants_hold_after_every_message(actions in prop::collection::vec(action(), 0..600)) {
        let msgs = build(&actions);
        let mut book = Book::new();
        let mut sink: Vec<Trade> = Vec::new();
        for m in &msgs {
            book.process(m, &mut sink);
            if let Err(e) = book.check_invariants() {
                prop_assert!(false, "invariant violated after {:?}: {}", m, e);
            }
        }
    }

    #[test]
    fn deterministic_same_input_same_output(actions in prop::collection::vec(action(), 0..600)) {
        let msgs = build(&actions);
        let run = |msgs: &[Msg]| {
            let mut b = Book::new();
            let mut s: Vec<Trade> = Vec::new();
            for m in msgs { b.process(m, &mut s); }
            (b.digest(), s)
        };
        let (d1, s1) = run(&msgs);
        let (d2, s2) = run(&msgs);
        prop_assert_eq!(d1, d2);
        prop_assert_eq!(s1, s2);
    }
}
