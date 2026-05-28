//! Benchmark harness for the Rust engine. See `spec/protocol.md` §5.
//!
//! Three passes over the same input (deterministic, so results are identical):
//!   A. untimed, CSV sink   -> trades.csv + digest.txt   (correctness / golden artifacts)
//!   B. timed per-op        -> latencies.csv             (latency distribution)
//!   C. bulk timed          -> THROUGHPUT + ALLOC        (clean throughput + allocations)
//!
//! Usage: harness [orders.bin] [out_dir]

use lob::{Book, CountSink, Msg, Trade, TradeSink, SIDE_BID};
use std::alloc::{GlobalAlloc, Layout, System};
use std::fs::{self, File};
use std::io::{BufWriter, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Instant;

static ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);
static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);

struct Counting;
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Relaxed);
        ALLOC_BYTES.fetch_add(l.size() as u64, Relaxed);
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l)
    }
}
#[global_allocator]
static GLOBAL: Counting = Counting;

/// Streams trades to a CSV file and folds them into an order-sensitive FNV-1a hash
/// (the trade-stream digest used for cross-engine differential testing).
struct CsvSink<W: Write> {
    w: W,
    seq: u64,
    hash: u64,
}
impl<W: Write> TradeSink for CsvSink<W> {
    fn trade(&mut self, t: Trade) {
        const PRIME: u64 = 0x100000001b3;
        for v in [t.maker, t.taker, t.price, t.qty] {
            for b in v.to_le_bytes() {
                self.hash ^= b as u64;
                self.hash = self.hash.wrapping_mul(PRIME);
            }
        }
        self.hash ^= t.aggressor as u64;
        self.hash = self.hash.wrapping_mul(PRIME);
        let ag = if t.aggressor == SIDE_BID { 'B' } else { 'S' };
        writeln!(self.w, "{},{},{},{},{},{}", self.seq, t.maker, t.taker, t.price, t.qty, ag)
            .expect("write trade");
        self.seq += 1;
    }
}

fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let in_path = args.next().unwrap_or_else(|| "bench/orders.bin".to_string());
    let out_dir = args.next().unwrap_or_else(|| "bench/results/rust".to_string());
    fs::create_dir_all(&out_dir)?;

    let mut data = Vec::new();
    File::open(&in_path)?.read_to_end(&mut data)?;
    let n = data.len() / 24;
    let decode = |i: usize| Msg::decode(&data[i * 24..]);

    // ---- Pass A: untimed, produce trades.csv + digest.txt ----
    let mut book = Book::new();
    let mut sink = CsvSink {
        w: BufWriter::new(File::create(format!("{out_dir}/trades.csv"))?),
        seq: 0,
        hash: 0xcbf29ce484222325,
    };
    writeln!(sink.w, "seq,maker_id,taker_id,price,qty,aggressor")?;
    for i in 0..n {
        let m = decode(i);
        book.process(&m, &mut sink);
    }
    sink.w.flush()?;
    let digest = book.digest();
    let trades_hash = sink.hash;
    fs::write(
        format!("{out_dir}/digest.txt"),
        format!("trades={}\ntrades_hash={:016x}\nbook_digest={:016x}\n", sink.seq, trades_hash, digest),
    )?;
    let trade_count = sink.seq;

    // ---- Pass B: timed per-op latency ----
    let mut book = Book::new();
    let mut count = CountSink::default();
    let mut lat: Vec<u64> = Vec::with_capacity(n);
    for i in 0..n {
        let m = decode(i);
        let t0 = Instant::now();
        book.process(&m, &mut count);
        lat.push(t0.elapsed().as_nanos() as u64);
    }
    let warmup = n / 10;
    let mut lw = BufWriter::new(File::create(format!("{out_dir}/latencies.csv"))?);
    for &v in &lat[warmup..] {
        writeln!(lw, "{v}")?;
    }
    lw.flush()?;

    // ---- Pass C: clean throughput + allocations (no per-op clock) ----
    let mut book = Book::new();
    let mut count = CountSink::default();
    let ab0 = ALLOC_BYTES.load(Relaxed);
    let ac0 = ALLOC_COUNT.load(Relaxed);
    let start = Instant::now();
    for i in 0..n {
        let m = decode(i);
        book.process(&m, &mut count);
    }
    let elapsed_ns = start.elapsed().as_nanos() as u64;
    let alloc_bytes = ALLOC_BYTES.load(Relaxed) - ab0;
    let alloc_count = ALLOC_COUNT.load(Relaxed) - ac0;

    // quick percentiles for immediate feedback (analyze.py is authoritative)
    let mut s = lat[warmup..].to_vec();
    s.sort_unstable();
    let pct = |p: f64| s[((s.len() as f64 - 1.0) * p) as usize];

    eprintln!("messages         {n}");
    eprintln!("trades           {trade_count}");
    eprintln!("trades_hash      {trades_hash:016x}");
    eprintln!("book digest      {digest:016x}");
    eprintln!("resting orders   {}", book.resting_count());
    eprintln!("THROUGHPUT msgs={n} elapsed_ns={elapsed_ns}  ({:.2} M msg/s)", n as f64 / elapsed_ns as f64 * 1000.0);
    eprintln!("ALLOC bytes={alloc_bytes} allocs={alloc_count}  ({:.3} bytes/op)", alloc_bytes as f64 / n as f64);
    eprintln!(
        "latency ns  p50={} p99={} p999={} max={}",
        pct(0.50),
        pct(0.99),
        pct(0.999),
        s[s.len() - 1]
    );
    Ok(())
}
