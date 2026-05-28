// Same refactor in Rust: add a variant, and `match` fails to compile (error E0004) until every
// site handles it. Same safety guarantee as OCaml. Reproduce:
//   rustc --edition 2021 --crate-type lib iceberg_refactor.rs

pub enum Order {
    Live { id: u32, price: u32, remaining: u32 },
    Filled,
    Cancelled,
    Iceberg { shown: u32, hidden: u32 }, // NEW
}

pub fn status_label(o: &Order) -> String {
    match o {
        Order::Live { price, remaining, .. } => format!("live({remaining}@{price})"),
        Order::Filled => "filled".to_string(),
        Order::Cancelled => "cancelled".to_string(),
    }
}
