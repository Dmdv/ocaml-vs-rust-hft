(* Benchmark harness for the idiomatic OCaml engine. See spec/protocol.md §5.
   Pass L: timed per-op latency -> latencies.csv.
   Pass T: timed bulk throughput + GC allocation, then trade-stream hash + book digest. *)

open Lob

external now_ns : unit -> int = "ocaml_now_ns" [@@noalloc]

let[@inline] get_u32 s off =
  Char.code (String.unsafe_get s off)
  lor (Char.code (String.unsafe_get s (off + 1)) lsl 8)
  lor (Char.code (String.unsafe_get s (off + 2)) lsl 16)
  lor (Char.code (String.unsafe_get s (off + 3)) lsl 24)

let () =
  let in_path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "bench/orders.bin" in
  let out_dir =
    if Array.length Sys.argv > 2 then Sys.argv.(2) else "bench/results/ocaml_idiomatic"
  in
  (try Sys.mkdir out_dir 0o755 with _ -> ());
  let data = In_channel.with_open_bin in_path In_channel.input_all in
  let n = String.length data / 24 in
  let warmup = n / 10 in

  (* ---- Pass L: timed per-op latency ---- *)
  let b = create ~trade_cap:(max 1 n) () in
  let lat = Array.make (max 1 n) 0 in
  for i = 0 to n - 1 do
    let off = i * 24 in
    let mtype = Char.code (String.unsafe_get data off) in
    let side = Char.code (String.unsafe_get data (off + 1)) in
    let id = get_u32 data (off + 4) in
    let price = get_u32 data (off + 8) in
    let qty = get_u32 data (off + 12) in
    let nprice = get_u32 data (off + 16) in
    let nqty = get_u32 data (off + 20) in
    let t0 = now_ns () in
    process b mtype side id price qty nprice nqty;
    lat.(i) <- now_ns () - t0
  done;
  let oc = open_out (Filename.concat out_dir "latencies.csv") in
  let buf = Buffer.create (1 lsl 16) in
  for i = warmup to n - 1 do
    Buffer.add_string buf (string_of_int lat.(i));
    Buffer.add_char buf '\n';
    if Buffer.length buf > (1 lsl 16) then begin
      output_string oc (Buffer.contents buf);
      Buffer.clear buf
    end
  done;
  output_string oc (Buffer.contents buf);
  close_out oc;

  (* ---- Pass T: timed bulk throughput + allocations ---- *)
  let b = create ~trade_cap:(max 1 n) () in
  let g0 = Gc.minor_words () in
  let mc0 = (Gc.quick_stat ()).Gc.minor_collections in
  let t0 = now_ns () in
  for i = 0 to n - 1 do
    let off = i * 24 in
    let mtype = Char.code (String.unsafe_get data off) in
    let side = Char.code (String.unsafe_get data (off + 1)) in
    let id = get_u32 data (off + 4) in
    let price = get_u32 data (off + 8) in
    let qty = get_u32 data (off + 12) in
    let nprice = get_u32 data (off + 16) in
    let nqty = get_u32 data (off + 20) in
    process b mtype side id price qty nprice nqty
  done;
  let elapsed = now_ns () - t0 in
  let minor_words = Gc.minor_words () -. g0 in
  let minor_colls = (Gc.quick_stat ()).Gc.minor_collections - mc0 in

  (* trade-stream hash + book digest (Int64, matching Rust's wrapping u64) *)
  let prime = 0x100000001b3L in
  let thash = ref 0xcbf29ce484222325L in
  let feed32 v =
    for k = 0 to 3 do
      let by = (v lsr (k * 8)) land 0xff in
      thash := Int64.mul (Int64.logxor !thash (Int64.of_int by)) prime
    done
  in
  let feedb by = thash := Int64.mul (Int64.logxor !thash (Int64.of_int by)) prime in
  for i = 0 to b.tr_n - 1 do
    feed32 b.tr_maker.(i);
    feed32 b.tr_taker.(i);
    feed32 b.tr_price.(i);
    feed32 b.tr_qty.(i);
    feedb b.tr_aggr.(i)
  done;
  let dg = digest b in
  let oc = open_out (Filename.concat out_dir "digest.txt") in
  Printf.fprintf oc "trades=%d\ntrades_hash=%016Lx\nbook_digest=%016Lx\n" b.tr_n !thash dg;
  close_out oc;

  (* percentiles for immediate feedback (analyze.py is authoritative) *)
  let m = max 0 (n - warmup) in
  let s = Array.sub lat warmup m in
  Array.sort compare s;
  let len = Array.length s in
  let pct p = if len = 0 then 0 else s.(int_of_float (float (len - 1) *. p)) in
  Printf.eprintf "messages         %d\n" n;
  Printf.eprintf "trades           %d\n" b.tr_n;
  Printf.eprintf "trades_hash      %016Lx\n" !thash;
  Printf.eprintf "book digest      %016Lx\n" dg;
  Printf.eprintf "resting orders   %d\n" (resting_count b);
  Printf.eprintf "THROUGHPUT msgs=%d elapsed_ns=%d  (%.2f M msg/s)\n" n elapsed
    (float n /. float elapsed *. 1000.);
  Printf.eprintf "ALLOC minor_words=%.0f minor_colls=%d  (%.3f words/op)\n" minor_words minor_colls
    (minor_words /. float (max 1 n));
  Printf.eprintf "latency ns  p50=%d p99=%d p999=%d max=%d\n" (pct 0.50) (pct 0.99) (pct 0.999)
    (if len > 0 then s.(len - 1) else 0)
