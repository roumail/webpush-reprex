#!/usr/bin/env bash
# Runs the Common Test suite.
# Uses a local rebar3 if there is one (brew install erlang rebar3),
# otherwise the official Erlang image, pinned by digest (OTP 27, rebar 3.27).
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="erlang:27@sha256:b59ebb8896568c227b2905c18bac6f458f10527952c079264dcca463b93dfcb1"

if command -v rebar3 >/dev/null 2>&1; then
  exec rebar3 ct "$@"
else
  exec docker run --rm -v "$PWD":/app -w /app "$IMAGE" rebar3 ct "$@"
fi
