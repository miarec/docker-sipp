#!/usr/bin/env bash
# Smoke test of a SIPp image: the tools are there, and SIPp sends rtp_stream
# RTP at the full rate for several calls at once.
#
# A SIPp UAC calls a SIPp UAS on a Docker network of its own. Each call loops
# an A-law WAV file with <exec rtp_stream> for TALK_SECONDS. tcpdump runs in
# the UAS network namespace and records each packet that reaches the UAS RTP
# ports. A 20 ms packet time gives 50 packets a second. The test fails if a
# call gets less than MIN_RATE packets a second or stops sending early.
#
# SIPp 3.7.0 to 3.7.2 fail this test: one process sends about 100 rtp_stream
# packets a second in total, so each of 8 calls gets about 12. See README.md.
#
# Usage: tests/smoke-test.sh <image>
# Environment: CALLS (default 8), TALK_SECONDS (default 10), MIN_RATE (default 45)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <image>" >&2
  exit 2
fi

image=$1
calls=${CALLS:-8}
talk=${TALK_SECONDS:-10}
min_rate=${MIN_RATE:-45}
scenarios=$(cd "$(dirname "$0")/scenarios" && pwd)
name=sipp-smoke-$$
work=$(mktemp -d)
# The UAS takes the RTP port of each call from this range. tcpdump captures
# only these ports, so it doesn't count SIP.
rtp_ports=20000-20999

cleanup() {
  docker rm --force "$name-capture" "$name-uas" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "==> Tools in ${image}"
docker run --rm "$image" sh -c '
  for tool in sh getent hostname tail stat base64 tcpdump sipp; do
    command -v "$tool" || { echo "missing: $tool" >&2; exit 1; }
  done'

# "sipp -v" exits with 99.
echo "==> SIPp version and features"
version=$({ docker run --rm "$image" sipp -v || [[ $? -eq 99 ]]; } | grep -m 1 'SIPp v')
echo "$version"
for feature in TLS SCTP PCAP; do
  if [[ "$version" != *"-${feature}"* ]]; then
    echo "FAIL: SIPp is built without ${feature}" >&2
    exit 1
  fi
done

# One second of G.711 A-law silence (0xD5), mono, 8 kHz: WAVE format 6.
python3 -I - "$work/alaw.wav" <<'EOF'
import struct
import sys

data = b"\xd5" * 8000
fmt = struct.pack("<HHIIHH", 6, 1, 8000, 8000, 1, 8)
with open(sys.argv[1], "wb") as wav:
    wav.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(data)) + b"WAVE")
    wav.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
    wav.write(b"data" + struct.pack("<I", len(data)) + data)
EOF
chmod 755 "$work"
chmod 644 "$work/alaw.wav"

echo "==> ${calls} calls of ${talk} s with rtp_stream"
docker network create "$name" >/dev/null
docker run --detach --name "$name-uas" --network "$name" --network-alias uas \
  --volume "$scenarios:/scenarios:ro" \
  "$image" \
  sipp -sf /scenarios/uas.xml -min_rtp_port "${rtp_ports%-*}" -max_rtp_port "${rtp_ports#*-}" -nostdin \
  >/dev/null
docker run --detach --name "$name-capture" --network "container:$name-uas" \
  "$image" \
  tcpdump -p -n -tt -l -i eth0 "udp and dst portrange ${rtp_ports}" \
  >/dev/null

for _ in $(seq 50); do
  if docker logs "$name-capture" 2>&1 | grep -q 'listening on'; then
    break
  fi
  sleep 0.2
done
if ! docker logs "$name-capture" 2>&1 | grep -q 'listening on'; then
  echo "FAIL: tcpdump did not start" >&2
  docker logs "$name-capture" >&2
  exit 1
fi

if ! docker run --rm --network "$name" \
  --volume "$scenarios:/scenarios:ro" --volume "$work:/audio:ro" \
  "$image" \
  sipp uas:5060 -sf /scenarios/uac.xml -s smoke \
    -m "$calls" -l "$calls" -r "$calls" -d "$((talk * 1000))" \
    -timeout "$((talk + 30))s" -timeout_error -nostdin \
  >"$work/uac.log" 2>&1; then
  echo "FAIL: the UAC calls failed" >&2
  tail -n 40 "$work/uac.log" >&2
  echo "--- UAS" >&2
  docker logs --tail 40 "$name-uas" >&2 2>&1
  exit 1
fi

docker stop --time 5 "$name-capture" >/dev/null
docker logs "$name-capture" 2>/dev/null >"$work/rtp.txt"

# A tcpdump line: <epoch> IP <src addr>.<port> > <dst addr>.<port>: UDP, length <n>
# Each call has its own pair of ports, so each pair is one call.
echo "==> RTP packets that reached the UAS"
awk -v calls="$calls" -v talk="$talk" -v min_rate="$min_rate" '
  $2 == "IP" {
    stream = $3 " > " $5
    sub(/:$/, "", stream)
    packets[stream]++
    if (!(stream in first)) first[stream] = $1
    last[stream] = $1
  }
  END {
    failed = 0
    for (stream in packets) {
      streams++
      span = last[stream] - first[stream]
      rate = span > 0 ? (packets[stream] - 1) / span : 0
      verdict = "ok"
      if (span < talk - 1) { verdict = "FAIL: stopped early"; failed = 1 }
      else if (rate < min_rate) { verdict = "FAIL: too slow"; failed = 1 }
      printf "%-44s %5d packets in %5.2f s = %5.1f packets/s  %s\n", stream, packets[stream], span, rate, verdict
    }
    if (streams != calls) {
      printf "FAIL: %d RTP streams, expected %d\n", streams, calls
      failed = 1
    }
    if (!failed) printf "PASS: each of %d calls sent at least %s packets/s\n", calls, min_rate
    exit failed
  }' "$work/rtp.txt" | sort
