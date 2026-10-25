#!/usr/bin/env bash
# Scripted MCP Inspector session against `zender serve --stdio` (TRD §15),
# in both protocol eras: modern (2026-07-28, stateless) and legacy
# (2025-11-25 initialize). The Inspector starts a fresh server for every
# call, so each check stands alone. tools/list runs with --strict, which
# fails on tool schemas that are not portable across model providers.
#
#   scripts/inspector-session.sh [path/to/zender]
#
# The official conformance suite tests servers over HTTP only; it joins CI
# with Streamable HTTP in P3.
set -euo pipefail

bin=${1:-zig-out/bin/zender}
inspector=(npx -y @modelcontextprotocol/inspector@2.12.0 --cli)

call() {
  local era=$1
  shift
  "${inspector[@]}" --protocol-era "$era" --format json -q "$bin" serve --stdio --log-format off "$@"
}

# expect <label> <regex> <output>
expect() {
  if grep -Eq -- "$2" <<<"$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected /$2/ in:"
    head -c 2000 <<<"$3"
    echo
    exit 1
  fi
}

for era in modern legacy; do
  expect "$era tools/list --strict" '"name": ?"collection.update"' "$(call "$era" --method tools/list --strict)"
  expect "$era resources/list" '"zender://scenes"' "$(call "$era" --method resources/list)"
  expect "$era resources/templates/list" 'zender://scene/\{scene_id\}/outline' "$(call "$era" --method resources/templates/list)"
  expect "$era resources/read docs" 'Z up' "$(call "$era" --method resources/read --uri zender://docs/conventions)"
  expect "$era prompts/list" '"build_scene_from_description"' "$(call "$era" --method prompts/list)"
  expect "$era prompts/get" '"messages"' "$(call "$era" --method prompts/get --prompt-name build_scene_from_description --prompt-args 'description=a table and two chairs')"
  expect "$era tools/call scene.create" '"scene_id": ?"scn_' "$(call "$era" --method tools/call --tool-name scene.create --tool-args-json '{"template":"default"}')"
  expect "$era tools/call schema.describe" '"hide_viewport"' "$(call "$era" --method tools/call --tool-name schema.describe --tool-args-json '{"type":"collection"}')"
  # A tool error is a result with isError, not a protocol error.
  expect "$era tools/call error" '"isError": ?true' "$(call "$era" --method tools/call --tool-name object.add_primitive --tool-args-json '{"scene_id":"scn_missing","kind":"cube"}' 2>&1 || true)"
done
