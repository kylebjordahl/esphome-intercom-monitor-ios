#!/bin/sh
# Protocol-layer checks for the legacy PBX-lite and voip-pcm/1 wire formats and
# the RTSP monitoring path.
#
# These compile the REAL files from Sources/Shared (not copies) into a host
# binary and assert against them, so they catch wire-format regressions without
# needing a device or a simulator.  AudioEngine is excluded because it needs
# iOS-only AVFoundation APIs; everything it touches is host-order PCM either way.
# RTSPAudioDecoder is included even though it uses AVFoundation — it only touches
# the cross-platform AVAudioConverter APIs, which build fine on the host.
#
# Usage:  sh Tests/run-protocol-tests.sh
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SHARED="$ROOT/Sources/Shared"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -o "$OUT/protocoltests" -swift-version 5 \
  "$SHARED/VoipAudioFormat.swift" \
  "$SHARED/RTSPMessage.swift" \
  "$SHARED/RTSPAudioFormat.swift" \
  "$SHARED/RTSPAudioDecoder.swift" \
  "$SHARED/RTSPStreamSession.swift" \
  "$SHARED/SIPMessage.swift" \
  "$SHARED/SDPSession.swift" \
  "$SHARED/SIPEndpoint.swift" \
  "$SHARED/SIPCall.swift" \
  "$SHARED/RTPAudioSession.swift" \
  "$SHARED/IntercomDevice.swift" \
  "$SHARED/IntercomProtocol.swift" \
  "$SHARED/IntercomConnection.swift" \
  "$SHARED/NetworkInfo.swift" \
  "$SHARED/HomeAssistantClient.swift" \
  "$ROOT/Tests/ProtocolTests/main.swift"

"$OUT/protocoltests"
