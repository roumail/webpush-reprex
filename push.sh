#!/usr/bin/env bash
# Manual check on a real phone (see README.md).
#   ./push.sh keys            make the VAPID key pair (once)
#   ./push.sh send "text"     push "text" to subscription.local.json
# Uses a local rebar3/erl if installed, otherwise the pinned Erlang image.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="erlang:27@sha256:b59ebb8896568c227b2905c18bac6f458f10527952c079264dcca463b93dfcb1"
COMMAND="${1:-}"
export PUSH_MESSAGE="${2:-Hello from Erlang}"

# The message travels as an environment variable, never inside the command.
RUN='rebar3 compile >/dev/null && erl -noshell -pa _build/default/lib/webpush/ebin -run webpush_manual main "$0"'

if command -v rebar3 >/dev/null 2>&1; then
  exec sh -c "$RUN" "$COMMAND"
else
  exec docker run --rm -e PUSH_MESSAGE -v "$PWD":/app -w /app "$IMAGE" sh -c "$RUN" "$COMMAND"
fi
