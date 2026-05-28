//! Neutral, deterministic workload generator.
//!
//! Emits a stream of fixed 24-byte little-endian order messages (see spec/protocol.md).
//! Seeded RNG => byte-identical output for a given (seed, count), so every engine consumes
//! the exact same input and the comparison is fair.

use clap::Parser;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use rand_distr::{Distribution, Normal};
use std::fs::File;
use std::io::{BufWriter, Write};

#[derive(Parser)]
#[command(about = "Generate a deterministic order-book workload (24-byte LE records)")]
struct Args {
    /// Number of messages to generate.
    #[arg(long, default_value_t = 5_000_000)]
    count: usize,
    /// RNG seed (determinism).
    #[arg(long, default_value_t = 42)]
    seed: u64,
    /// Output path.
    #[arg(long, default_value = "bench/orders.bin")]
    out: String,
}

const T_ADD: u8 = 0;
const T_CANCEL: u8 = 1;
const T_REPLACE: u8 = 2;
const T_MARKET: u8 = 3;
const SIDE_BID: u8 = 0;
const SIDE_ASK: u8 = 1;

struct Rec {
    msg_type: u8,
    side: u8,
    order_id: u32,
    price: u32,
    qty: u32,
    new_price: u32,
    new_qty: u32,
}

/// Pack a record into its 24-byte little-endian wire form.
fn encode(r: &Rec) -> [u8; 24] {
    let mut b = [0u8; 24];
    b[0] = r.msg_type;
    b[1] = r.side;
    // b[2..4] reserved padding = 0
    b[4..8].copy_from_slice(&r.order_id.to_le_bytes());
    b[8..12].copy_from_slice(&r.price.to_le_bytes());
    b[12..16].copy_from_slice(&r.qty.to_le_bytes());
    b[16..20].copy_from_slice(&r.new_price.to_le_bytes());
    b[20..24].copy_from_slice(&r.new_qty.to_le_bytes());
    b
}

fn main() -> std::io::Result<()> {
    let args = Args::parse();
    let mut rng = StdRng::seed_from_u64(args.seed);
    let mut w = BufWriter::with_capacity(1 << 20, File::create(&args.out)?);

    // Bids and asks are both drawn around a slowly random-walking mid, so a healthy fraction
    // of incoming orders cross and trade, exercising the matching hot path.
    let noise = Normal::new(0.0f64, 8.0).unwrap();
    let mut mid: i64 = 10_000;
    let mut next_id: u32 = 1;
    let mut live: Vec<u32> = Vec::with_capacity(1 << 20);

    for _ in 0..args.count {
        if rng.gen::<f64>() < 0.05 {
            mid += if rng.gen::<bool>() { 1 } else { -1 };
            mid = mid.clamp(9_500, 10_500); // keep the active tick band bounded
        }
        let roll: f64 = rng.gen();
        let side = if rng.gen::<bool>() { SIDE_BID } else { SIDE_ASK };
        let price = ((mid as f64 + noise.sample(&mut rng)).max(1.0)).round() as u32;
        let qty: u32 = rng.gen_range(1..=500);

        let rec = if roll < 0.60 || live.is_empty() {
            let id = next_id;
            next_id += 1;
            live.push(id);
            Rec { msg_type: T_ADD, side, order_id: id, price, qty, new_price: 0, new_qty: 0 }
        } else if roll < 0.90 {
            let idx = rng.gen_range(0..live.len());
            let id = live.swap_remove(idx);
            Rec { msg_type: T_CANCEL, side: 0, order_id: id, price: 0, qty: 0, new_price: 0, new_qty: 0 }
        } else if roll < 0.95 {
            let idx = rng.gen_range(0..live.len());
            let id = live[idx];
            let nq: u32 = rng.gen_range(1..=500);
            Rec { msg_type: T_REPLACE, side: 0, order_id: id, price: 0, qty: 0, new_price: price, new_qty: nq }
        } else {
            let id = next_id;
            next_id += 1;
            Rec { msg_type: T_MARKET, side, order_id: id, price: 0, qty, new_price: 0, new_qty: 0 }
        };
        w.write_all(&encode(&rec))?;
    }
    w.flush()?;
    eprintln!("wrote {} records ({} bytes) to {}", args.count, args.count * 24, args.out);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_layout_is_little_endian_24_bytes() {
        let r = Rec {
            msg_type: T_REPLACE,
            side: SIDE_ASK,
            order_id: 0x0102_0304,
            price: 0x0A0B_0C0D,
            qty: 7,
            new_price: 9,
            new_qty: 11,
        };
        let b = encode(&r);
        assert_eq!(b.len(), 24);
        assert_eq!(b[0], 2);
        assert_eq!(b[1], 1);
        assert_eq!(&b[2..4], &[0, 0]); // padding
        assert_eq!(&b[4..8], &[0x04, 0x03, 0x02, 0x01]);
        assert_eq!(u32::from_le_bytes(b[8..12].try_into().unwrap()), 0x0A0B_0C0D);
        assert_eq!(u32::from_le_bytes(b[12..16].try_into().unwrap()), 7);
        assert_eq!(u32::from_le_bytes(b[16..20].try_into().unwrap()), 9);
        assert_eq!(u32::from_le_bytes(b[20..24].try_into().unwrap()), 11);
    }
}
