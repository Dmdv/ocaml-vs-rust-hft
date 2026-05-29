#!/usr/bin/env bash
# Phase 2: runs on the post-reboot boot via the lob-bench systemd unit. Applies runtime tuning,
# runs the benchmark pinned to the isolated core inside the prebuilt Docker image, uploads the
# results + environment proof to S3, and (by default) terminates this instance.
#
# Config is read from /opt/lob/config.env, written by phase 1 (userdata.sh).
set -uo pipefail
exec >>/var/log/lob-bench.log 2>&1

# shellcheck disable=SC1091
source /opt/lob/config.env
cd /opt/lob/repo || exit 1
mkdir -p /opt/lob/out
log() { printf '[bench %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# instance identity (IMDSv2)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 600" || true)
IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || echo unknown)

finish() {
  rc=$?
  log "run finished rc=$rc; uploading to $S3_URI"
  echo "$rc" >/opt/lob/out/EXIT_CODE
  aws s3 cp /opt/lob/out "$S3_URI/results/" --recursive --region "$AWS_REGION" || true
  aws s3 cp /var/log/lob-bench.log "$S3_URI/results/log.txt" --region "$AWS_REGION" || true
  aws s3 cp /opt/lob/out/EXIT_CODE "$S3_URI/DONE" --region "$AWS_REGION" || true
  if [ "${TERMINATE:-1}" = "1" ] && [ "$IID" != "unknown" ]; then
    log "terminating $IID"
    aws ec2 terminate-instances --instance-ids "$IID" --region "$AWS_REGION" || shutdown -h now
  fi
}
trap finish EXIT

command -v aws >/dev/null 2>&1 || dnf install -y awscli-2 >/dev/null 2>&1 || true

# 1. Tune the host; capture the proof into the results.
PIN_CORE="$PIN_CORE" ISOL_CPUS="$ISOL_CPUS" bash deploy/ec2/tune.sh >/opt/lob/out/environment.txt 2>/dev/null || true

# 2. Get the engine image: pull the prebuilt one, else build from source on the box.
if docker pull "$IMAGE" >/dev/null 2>&1; then
  log "pulled prebuilt image $IMAGE"
  RUN_IMAGE="$IMAGE"
else
  log "no prebuilt image; building from docker/Dockerfile (slower)"
  docker build -f docker/Dockerfile -t lob:linux . && RUN_IMAGE="lob:linux"
fi

# 3. NUMA node of the pinned core, for memory locality (--cpuset-mems).
NODE=0
for nd in /sys/devices/system/cpu/cpu${PIN_CORE}/node*; do
  [ -e "$nd" ] && NODE=$(basename "$nd" | sed 's/node//') && break
done

# 4. Run the full pipeline (build is a no-op in the prebuilt image): regenerate workload, run each
#    engine pinned to the isolated core, verify the differential, render charts.
log "running run_all.sh N=$N RUNS=$RUNS pinned to core $PIN_CORE (numa node $NODE)"
docker run --rm \
  --cpuset-cpus="$PIN_CORE" --cpuset-mems="$NODE" \
  -e PIN_CPU="$PIN_CORE" \
  -v /opt/lob/out:/work/bench/results \
  "$RUN_IMAGE" bash scripts/run_all.sh "$N" "$RUNS"
log "run_all.sh exited $?"
