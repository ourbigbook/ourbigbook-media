#!/usr/bin/env bash
set -euxo pipefail

output=data.json
tmp="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

heroku psql -a ourbigbook DATABASE_URL <<EOF | jq --exit-status --raw-input --slurp --slurpfile existing <(
  if [[ -f "$output" ]]; then
    cat "$output"
  else
    printf '[]\n'
  fi
) '
  ($existing[0]
    | if . == null then [] elif type == "array" then . else error("expected a JSON array") end
  ) as $old
  | fromjson
  | if type == "array" then . else error("expected a JSON array") end
  | reduce .[] as $new (
      $old;
      if any(.[]; .username == $new.username) then . else . + [$new] end
    )
' > "$tmp"
\\set QUIET 1
\\a
\\t
select coalesce(json_agg(r), '[]'::json) from (
  SELECT "displayName",username,email,ip,"createdAt"
  FROM "User"
  WHERE locked = true
  ORDER BY "createdAt" DESC
) r;
EOF

mv "$tmp" "$output"
trap - EXIT

command -v curl >/dev/null
ripestat_url="${RIPESTAT_URL:-https://stat.ripe.net/data/prefix-overview/data.json}"
ripestat_delay="${RIPESTAT_DELAY_SECONDS:-0.25}"
ripestat_retries="${RIPESTAT_RETRIES:-3}"
ripestat_retry_delay="${RIPESTAT_RETRY_DELAY_SECONDS:-5}"
ripestat_rate_delay="${RIPESTAT_RATE_DELAY_SECONDS:-30}"

while IFS= read -r ip; do
  isp="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .isp) // empty
  ' "$output")"
  isp_date="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .["isp-date"]) // empty
  ' "$output")"
  queried=false

  if [[ -z "$isp" ]]; then
    for ((attempt = 1; attempt <= ripestat_retries; attempt++)); do
      ripestat_tmp="$(mktemp)"
      trap 'rm -f "$ripestat_tmp"' EXIT
      ripestat_status=0
      curl \
        --connect-timeout 10 \
        --fail \
        --get \
        --location \
        --max-time 30 \
        --show-error \
        --silent \
        --data-urlencode "resource=$ip" \
        "$ripestat_url" > "$ripestat_tmp" 2>&1 || ripestat_status=$?
      rate_limited=false
      if LC_ALL=C grep -Eiq '(^|[^0-9])429([^0-9]|$)|rate.?limit|too many (queries|requests)' "$ripestat_tmp"; then
        rate_limited=true
      fi

      isp=""
      if ((ripestat_status == 0)); then
        isp="$(jq --raw-output '
          if .status == "ok" then
            [.data.asns[]?.holder | select(type == "string" and length > 0)]
            | unique
            | join(", ")
          else
            empty
          end
        ' "$ripestat_tmp" 2>/dev/null || true)"
      fi

      rm -f "$ripestat_tmp"
      trap - EXIT

      if [[ -n "$isp" ]]; then
        isp_date="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
        queried=true
        break
      fi

      if ((attempt < ripestat_retries)); then
        if "$rate_limited"; then
          printf 'RIPEstat rate limit detected for %s; retrying in %s seconds.\n' "$ip" "$ripestat_rate_delay" >&2
          sleep "$ripestat_rate_delay"
        else
          printf 'RIPEstat attempt %s/%s failed for %s (curl exit %s); retrying in %s seconds.\n' \
            "$attempt" "$ripestat_retries" "$ip" "$ripestat_status" "$ripestat_retry_delay" >&2
          sleep "$ripestat_retry_delay"
        fi
      fi
    done

    if [[ -z "$isp" ]]; then
      printf 'No ISP found for %s after %s attempts; leaving it for the next run.\n' \
        "$ip" "$ripestat_retries" >&2
      continue
    fi
  elif [[ -z "$isp_date" ]]; then
    isp_date="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
  fi

  tmp="$(mktemp "${output}.tmp.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  jq --arg ip "$ip" --arg isp "$isp" --arg isp_date "$isp_date" '
    map(
      if .ip == $ip and ((.isp? // "") == "") then
        . + {"isp": $isp, "isp-date": $isp_date}
      else
        .
      end
    )
  ' "$output" > "$tmp"
  mv "$tmp" "$output"
  trap - EXIT

  if "$queried"; then
    sleep "$ripestat_delay"
  fi
done < <(jq --raw-output '
  [.[]
    | select(
        ((.isp? // "") == "")
        and (.ip? | type == "string")
        and (.ip | length > 0)
      )
    | .ip
  ]
  | unique[]
' "$output")
