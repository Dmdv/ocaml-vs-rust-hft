#!/usr/bin/env bash
# Launch an x86 bare-metal EC2 instance that runs the pinned benchmark headlessly, uploads results
# to S3, and self-terminates. This orchestrator waits for the S3 DONE marker, downloads results,
# and (belt-and-braces) terminates the instance on exit. No SSH / no inbound rules required.
#
# Required (env or exported):
#   AWS_REGION         e.g. us-east-1
#   S3_BUCKET          results go to s3://$S3_BUCKET/<run-id>/
#   INSTANCE_PROFILE   IAM instance-profile NAME with: s3:PutObject on the bucket,
#                      ec2:TerminateInstances (tag-scoped), and read of EC2 metadata
# Optional (defaults shown): INSTANCE_TYPE, REPO_URL, REPO_REF, IMAGE, N, RUNS, PIN_CORE,
#                            ISOL_CPUS, TERMINATE, TTL_MIN
# Prereq: AWS CLI v2 configured (or, in CI, credentials from the OIDC role).
set -euo pipefail

: "${AWS_REGION:?set AWS_REGION}"
: "${S3_BUCKET:?set S3_BUCKET}"
: "${INSTANCE_PROFILE:?set INSTANCE_PROFILE (IAM instance profile name)}"

INSTANCE_TYPE="${INSTANCE_TYPE:-c7i.metal-24xl}"
REPO_URL="${REPO_URL:-https://github.com/Dmdv/ocaml-vs-rust-hft.git}"
REPO_REF="${REPO_REF:-master}"
IMAGE="${IMAGE:-ghcr.io/dmdv/ocaml-vs-rust-hft:linux-amd64}"
N="${N:-5000000}"
RUNS="${RUNS:-5}"
PIN_CORE="${PIN_CORE:-2}"
ISOL_CPUS="${ISOL_CPUS:-2,3}"
TERMINATE="${TERMINATE:-1}"
TTL_MIN="${TTL_MIN:-60}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="lobbench-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
s3_uri="s3://${S3_BUCKET}/${run_id}"

echo "== resolving latest Amazon Linux 2023 x86_64 AMI =="
ami=$(aws ssm get-parameters --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
echo "   AMI=$ami  type=$INSTANCE_TYPE  results=$s3_uri"

ud="$(mktemp)"
trap 'rm -f "$ud"' EXIT
sed -e "s|__S3_URI__|${s3_uri}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s|__REPO_URL__|${REPO_URL}|g" \
    -e "s|__REPO_REF__|${REPO_REF}|g" \
    -e "s|__N__|${N}|g" \
    -e "s|__RUNS__|${RUNS}|g" \
    -e "s|__PIN_CORE__|${PIN_CORE}|g" \
    -e "s|__ISOL_CPUS__|${ISOL_CPUS}|g" \
    -e "s|__TERMINATE__|${TERMINATE}|g" \
    -e "s|__TTL_MIN__|${TTL_MIN}|g" \
    "$here/userdata.sh" >"$ud"

echo "== launching =="
iid=$(aws ec2 run-instances --region "$AWS_REGION" \
  --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
  --instance-initiated-shutdown-behavior terminate \
  --user-data "file://$ud" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${run_id}},{Key=project,Value=ocaml-vs-rust-hft}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "   instance=$iid"

terminate() { aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$iid" >/dev/null 2>&1 || true; }
trap 'rm -f "$ud"; terminate' EXIT

echo "== waiting for results (phase 1 provision+reboot, then run; ~10-40 min) =="
deadline=$(( $(date +%s) + TTL_MIN*60 + 2400 ))   # TTL + generous build/boot slack
until aws s3 ls "${s3_uri}/DONE" --region "$AWS_REGION" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "   timed out waiting for DONE marker"; break; fi
  sleep 30
done

out="results-${run_id}"
mkdir -p "$out"
aws s3 cp "${s3_uri}/results/" "$out/" --recursive --region "$AWS_REGION" || true
code=$(cat "$out/EXIT_CODE" 2>/dev/null || echo '?')
echo "== done: results in ./$out  (benchmark exit code: $code) =="
echo "   latency table : $out/summary.md"
echo "   environment   : $out/environment.txt"
[ "$code" = "0" ] || echo "   NOTE: non-zero exit — check $out/log.txt"
