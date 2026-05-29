#!/usr/bin/env bash
# Phase 1 — cloud-init user-data, first boot, Amazon Linux 2023 (x86_64). Provisions the box, sets
# core isolation on the kernel cmdline (boot-time only), installs a oneshot systemd unit that runs
# the benchmark on the NEXT boot, installs a TTL self-destruct timer, then reboots.
#
# The __PLACEHOLDERS__ are filled in by deploy/ec2/run.sh before launch.
set -euxo pipefail

mkdir -p /opt/lob/out
cat >/opt/lob/config.env <<EOF
S3_URI="__S3_URI__"
AWS_REGION="__AWS_REGION__"
IMAGE="__IMAGE__"
REPO_URL="__REPO_URL__"
REPO_REF="__REPO_REF__"
N="__N__"
RUNS="__RUNS__"
PIN_CORE="__PIN_CORE__"
ISOL_CPUS="__ISOL_CPUS__"
TERMINATE="__TERMINATE__"
TTL_MIN="__TTL_MIN__"
EOF
# shellcheck disable=SC1091
source /opt/lob/config.env

dnf install -y git docker grubby >/dev/null
command -v aws >/dev/null 2>&1 || dnf install -y awscli-2 >/dev/null 2>&1 || true
systemctl enable --now docker

git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" /opt/lob/repo

# Core isolation: keep the kernel scheduler, RCU callbacks and the tick off the benchmark cpus.
grubby --update-kernel=ALL --args="isolcpus=${ISOL_CPUS} nohz_full=${ISOL_CPUS} rcu_nocbs=${ISOL_CPUS} intel_idle.max_cstate=1 processor.max_cstate=1"

# Phase-2 runner, fired once on the next boot.
cat >/etc/systemd/system/lob-bench.service <<'EOF'
[Unit]
Description=OCaml-vs-Rust pinned benchmark (phase 2)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/bash /opt/lob/repo/deploy/ec2/bench.sh
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
systemctl enable lob-bench.service

# Hard safety net: self-destruct TTL minutes after each boot, regardless of what the run does.
# (Instance is launched with --instance-initiated-shutdown-behavior terminate, so this terminates.)
cat >/etc/systemd/system/lob-ttl.service <<'EOF'
[Unit]
Description=Benchmark instance TTL self-destruct
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -h now
EOF
cat >/etc/systemd/system/lob-ttl.timer <<EOF
[Unit]
Description=Fire TTL self-destruct ${TTL_MIN} min after boot
[Timer]
OnBootSec=${TTL_MIN}min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF
systemctl enable lob-ttl.timer

reboot
