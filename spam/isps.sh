#!/usr/bin/env bash
set -euo pipefail

jq -r '
  [.[] | .isp? | select(. != null)]
  | group_by(.)
  | map({isp: .[0], count: length})
  | sort_by([-.count, .isp])[]
  | [.count, .isp]
  | @tsv
' "${1:-data.csv}"
