#!/usr/bin/env bash
set -euxo pipefail

output=data.csv
tmp="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

./heroku psql DATABASE_URL <<EOF | jq --exit-status --raw-input --slurp --slurpfile existing <(
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
  SELECT username,email,ip,"createdAt"
  FROM "User"
  WHERE locked = true
  ORDER BY "createdAt" DESC
) r;
EOF

mv "$tmp" "$output"
trap - EXIT

command -v whois >/dev/null
whois_delay="${WHOIS_DELAY_SECONDS:-0}"
whois_retries="${WHOIS_RETRIES:-3}"
whois_retry_delay="${WHOIS_RETRY_DELAY_SECONDS:-5}"
whois_rate_delay="${WHOIS_RATE_DELAY_SECONDS:-30}"

while IFS= read -r ip; do
  isp="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .isp) // empty
  ' "$output")"
  isp_date="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .["isp-date"]) // empty
  ' "$output")"
  queried=false

  if [[ -z "$isp" ]]; then
    for ((attempt = 1; attempt <= whois_retries; attempt++)); do
      whois_tmp="$(mktemp)"
      trap 'rm -f "$whois_tmp"' EXIT
      whois_status=0
      LC_ALL=C whois "$ip" > "$whois_tmp" 2>&1 || whois_status=$?
      rate_limited=false
      if LC_ALL=C grep -Eiq 'rate.?limit|query limit|too many (queries|requests)|quota exceeded|access denied' "$whois_tmp"; then
        rate_limited=true
      fi

      # Some WHOIS clients return nonzero after a failed referral even though
      # the response already contains enough registry data for this purpose.
      isp="$(LC_ALL=C awk '
        BEGIN { best = 999 }
        {
          separator = index($0, ":")
          if (separator == 0) next
          key = tolower(substr($0, 1, separator - 1))
          value = substr($0, separator + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          priority = 999
          if (key == "org-name" || key == "orgname") priority = 1
          else if (key == "organization" || key == "owner") priority = 2
          else if (key == "descr") priority = 3
          else if (key == "netname") priority = 4
          if (value != "" && priority < best) {
            result = value
            best = priority
          }
        }
        END { print result }
      ' "$whois_tmp")"

      rm -f "$whois_tmp"
      trap - EXIT

      if [[ -n "$isp" ]]; then
        isp_date="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
        queried=true
        break
      fi

      if ((attempt < whois_retries)); then
        if "$rate_limited"; then
          printf 'WHOIS rate limit detected for %s; retrying in %s seconds.\n' "$ip" "$whois_rate_delay" >&2
          sleep "$whois_rate_delay"
        else
          printf 'WHOIS attempt %s/%s failed for %s (exit %s); retrying in %s seconds.\n' \
            "$attempt" "$whois_retries" "$ip" "$whois_status" "$whois_retry_delay" >&2
          sleep "$whois_retry_delay"
        fi
      fi
    done

    if [[ -z "$isp" ]]; then
      printf 'No ISP found for %s after %s attempts; leaving it for the next run.\n' \
        "$ip" "$whois_retries" >&2
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
    sleep "$whois_delay"
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
