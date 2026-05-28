// Rust expresses the same idea: an enum makes illegal states unrepresentable, and `match` is
// exhaustive. (To restrict `cancel` to live orders only, Rust — like OCaml — uses a separate
// type for the live case; shown here as `Live`'s fields living in their own struct would be the
// next step.) Reproduce: rustc --edition 2021 --crate-type lib order_status.rs

pub enum Order {
    Live { id: u32, price: u32, remaining: u32 },
    Filled,
    Cancelled,
}

pub fn status_label(o: &Order) -> String {
    match o {
        Order::Live { price, remaining, .. } => format!("live({remaining}@{price})"),
        Order::Filled => "filled".to_string(),
        Order::Cancelled => "cancelled".to_string(),
    }
}
