# Running the benchmark on EC2 (core-isolated, low-jitter)

The repo's headline numbers come from a laptop, which can't be core-pinned (see the main README's
*Core pinning* section). This directory runs the **same** benchmark on a tuned x86 bare-metal EC2
instance — core isolation, fixed clocks, IRQs steered away, SMT sibling offlined — so the tail
reflects the engine, not the OS. The whole thing is headless and **auto-terminating**.

```
run.sh / ec2-bench Action ──launch──▶  EC2 x86 metal
                                       phase 1 (cloud-init): install docker, set
                                         isolcpus/nohz_full/rcu_nocbs on the kernel cmdline,
                                         install a boot-time runner + TTL timer, REBOOT
                                       phase 2 (systemd @ boot): tune.sh, then
                                         docker run --cpuset-cpus=<isolated core> the benchmark,
                                         upload results+environment.txt to S3, self-terminate
run.sh / Action            ◀─results─  S3        (TTL timer + shutdown=terminate are kill-switches)
```

`isolcpus` is a kernel boot parameter, so the one reboot between phase 1 and phase 2 is required.

## A note on "kernel-bypass"

Kernel-bypass (DPDK, Solarflare Onload, AF_XDP, EFA/RDMA) removes the **kernel network stack** from
the latency path. This benchmark has **no network I/O** — it reads `orders.bin` into memory and
runs a CPU-bound loop — so there is nothing to bypass, and wiring up DPDK here would measure
nothing. What this setup does instead is take the **OS scheduler/timer/IRQ jitter** off the hot
core, which is the equivalent "get the kernel out of the way" lever for a compute-bound workload.

Kernel-bypass becomes relevant only if the engine is fed by a **live market-data socket** (a
UDP/multicast ITCH-style ingest). That is real new scope — a networked feed handler — and the one
case where a separate repo makes sense. It is intentionally out of scope here.

## Instance specs

| | recommendation | why |
|---|---|---|
| **Type** | `c7i.metal-24xl` (96 vCPU, Sapphire Rapids) | bare metal = no hypervisor jitter, full control of the kernel cmdline; compute-optimized, high sustained clock. `m7i.metal-24xl` is an equivalent alt. For max single-thread clock, `z1d.metal` if available in your region. |
| **AMI** | latest Amazon Linux 2023 x86_64 | `grubby` makes setting kernel args one line; resolved automatically via SSM in `run.sh`. |
| **Arch** | x86_64 | production-typical; leaves the door open for OxCaml's x86-only SIMD later. (Graviton/arm64 metal also works — set `INSTANCE_TYPE=c7g.metal` and use the arm64 AMI param.) |
| **Storage/network** | defaults | the workload is in-memory; no EBS/network tuning needed. |

Bare-metal instances take ~10–15 min to provision and boot, plus the reboot — budget ~15–25 min
end-to-end if pulling the prebuilt image, more if building on the box.

## One-time AWS setup

You provide three things; everything else is automatic.

**1. An S3 bucket** for results (any name; set `S3_BUCKET`/`vars.BENCH_S3_BUCKET`).

**2. An IAM instance profile** the instance runs under. Attach a role with this policy (replace
`YOUR_BUCKET`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::YOUR_BUCKET/*" },
    { "Effect": "Allow", "Action": ["ec2:TerminateInstances"], "Resource": "*",
      "Condition": { "StringEquals": { "ec2:ResourceTag/project": "ocaml-vs-rust-hft" } } }
  ]
}
```

The terminate permission is tag-scoped to instances this tooling launches, so it can only kill its
own. Pass its name via `INSTANCE_PROFILE` (local) or `vars.BENCH_INSTANCE_PROFILE` (Action).

**3. (Action path only) a GitHub OIDC role** so the workflow needs no stored keys. Create an IAM
OIDC provider for `token.actions.githubusercontent.com`, then a role trusting your repo:

```json
{ "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringLike": { "token.actions.githubusercontent.com:sub": "repo:Dmdv/ocaml-vs-rust-hft:*" } } }
```

with permissions: `ec2:RunInstances`, `ec2:CreateTags`, `ec2:DescribeInstances`,
`ec2:TerminateInstances` (tag-scoped as above), `ssm:GetParameters` (for the AMI lookup),
`iam:PassRole` (scoped to the instance-profile role, condition `iam:PassedToService = ec2`), and
`s3:ListBucket` + `s3:GetObject` on the bucket. Then set repo **Variables** `AWS_REGION`,
`BENCH_S3_BUCKET`, `BENCH_INSTANCE_PROFILE` and **Secret** `AWS_ROLE_ARN`.

## (Recommended) publish the image first

`docker/Dockerfile` compiles two OCaml compilers (~40 min). Run the **publish-image** workflow once
to build `linux/amd64` and push it to GHCR, then set the GHCR package to **Public** (repo →
Packages → package settings). EC2 then `docker pull`s in seconds. If the image isn't available,
`bench.sh` falls back to building on the box (slower, burns metal-instance minutes).

## Run it

**Locally** (uses your `aws` CLI credentials):

```bash
export AWS_REGION=us-east-1
export S3_BUCKET=your-bench-bucket
export INSTANCE_PROFILE=lob-bench-profile
# optional: INSTANCE_TYPE, N, RUNS, PIN_CORE, ISOL_CPUS, TTL_MIN
deploy/ec2/run.sh
```

It launches, waits for the S3 `DONE` marker, downloads to `./results-<run-id>/`, and terminates the
instance (which has also self-terminated). Smaller/faster smoke run: `N=1000000 RUNS=3 deploy/ec2/run.sh`.

**Via GitHub Actions**: set the Variables/Secret above, then run the **ec2-bench** workflow
(Actions → ec2-bench → Run workflow). Results come back as the `ec2-results` artifact.

## What you get back

In `results-<run-id>/` (and under `s3://$S3_BUCKET/<run-id>/results/`):

- `summary.md`, `latency_tail.png`, `throughput.png` — the same tables/charts as a local run, but
  core-pinned.
- `rust/`, `ocaml_idiomatic/`, `ocaml_oxcaml/` — per-engine `latencies.csv`, `digest.txt`, `summary.txt`.
- **`environment.txt`** — the proof: `/proc/cmdline` (isolcpus active?), governor, turbo, THP, the
  pinned core's frequency, `lscpu`. Always read this to confirm the run actually got the isolated
  environment.
- `log.txt`, `EXIT_CODE` — `run_all.sh` also enforces the **differential gate**, so a `0` exit
  means all three engines reproduced the golden on this host too.

## Cost & safety

You run this briefly, so the bill is dollars, not a standing cost — but bare metal is ~$4–7/hr, so
the auto-terminate matters. Three independent kill-switches:

1. `bench.sh` terminates the instance when the run finishes (default `TERMINATE=1`).
2. A `lob-ttl` systemd timer runs `shutdown -h now` `TTL_MIN` minutes after boot (default 60), and
   the instance is launched with `--instance-initiated-shutdown-behavior terminate`.
3. `run.sh` / the Action terminate the instance on exit, even on error.

After the first GHCR publish, **double-check the running instance is gone** in the EC2 console the
first time you use this, then trust the automation.

## Honest limit

Even core-isolated bare metal is a benchmark host, not a colocated, kernel-bypassed exchange
gateway. It removes the OS jitter this comparison can control; it does not model network path,
NIC, or cross-host effects. The point is a *clean, pinned, reproducible* version of the same
relative comparison — tighter tails than the laptop, same conclusions to verify.
