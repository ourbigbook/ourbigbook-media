#!/usr/bin/env bash
set -euxo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="$script_dir/data.json"
existing="$output"
existing_args=()
if [[ -f "$existing" ]]; then
  existing_args=(--existing "$existing")
fi

command -v python3 >/dev/null
tmp="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

heroku psql -a ourbigbook DATABASE_URL <<EOF | \
  python3 "$script_dir/extract_identifiers.py" "${existing_args[@]}" > "$tmp"
\\set QUIET 1
\\a
\\t
\\pset pager off
select coalesce(json_agg(r), '[]'::json) from (
  SELECT
    u."displayName",
    u.username,
    u.email,
    u.ip,
    u."createdAt",
    coalesce((
      SELECT json_agg(authored.text)
      FROM (
        SELECT concat_ws(E'\\n', a."titleSource", f."bodySource") AS text
        FROM "Article" a
        LEFT JOIN "File" f ON f.id = a."fileId"
        WHERE a."authorId" = u.id

        UNION ALL

        SELECT concat_ws(E'\\n', i."titleSource", i."bodySource") AS text
        FROM "Issue" i
        WHERE i."authorId" = u.id

        UNION ALL

        SELECT c.source AS text
        FROM "Comment" c
        WHERE c."authorId" = u.id
      ) authored
      WHERE authored.text IS NOT NULL
    ), '[]'::json) AS content
  FROM "User" u
  WHERE u.locked = true
  ORDER BY u."createdAt" DESC
) r;
EOF

if [[ -f "$existing" ]]; then
  chmod --reference="$existing" "$tmp"
else
  chmod 0644 "$tmp"
fi
mv "$tmp" "$output"
trap - EXIT

command -v curl >/dev/null
ripestat_url="${RIPESTAT_URL:-https://stat.ripe.net/data/prefix-overview/data.json}"
ripestat_delay="${RIPESTAT_DELAY_SECONDS:-0.25}"
ripestat_retries="${RIPESTAT_RETRIES:-3}"
ripestat_max_attempts="${RIPESTAT_MAX_ATTEMPTS:-9}"
ripestat_retry_delay="${RIPESTAT_RETRY_DELAY_SECONDS:-5}"
ripestat_rate_delay="${RIPESTAT_RATE_DELAY_SECONDS:-30}"
if [[ ! "$ripestat_max_attempts" =~ ^[1-9][0-9]*$ ]]; then
  printf 'RIPESTAT_MAX_ATTEMPTS must be a positive integer: %s\n' "$ripestat_max_attempts" >&2
  exit 1
fi

while IFS= read -r ip; do
  isp="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .isp) // empty
  ' "$output")"
  isp_date="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and ((.isp? // "") != "")) | .["isp-date"]) // empty
  ' "$output")"
  isp_attempts="$(jq --raw-output --arg ip "$ip" '
    [
      .[]
      | select(.ip == $ip and ((.isp? // "") == ""))
      | (. ["isp-attempts"]? // 0)
      | select(type == "number" and floor == .)
    ]
    | max // 0
  ' "$output")"
  queried=false

  if [[ -z "$isp" ]]; then
    if ((isp_attempts >= ripestat_max_attempts)); then
      printf 'ISP lookup limit reached for %s (%s attempts); skipping.\n' \
        "$ip" "$isp_attempts" >&2
      continue
    fi

    for ((
      attempt = 1;
      attempt <= ripestat_retries && isp_attempts < ripestat_max_attempts;
      attempt++
    )); do
      ((isp_attempts += 1))
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

      if ((attempt < ripestat_retries && isp_attempts < ripestat_max_attempts)); then
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
      tmp="$(mktemp "${output}.tmp.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT
      jq --arg ip "$ip" --argjson isp_attempts "$isp_attempts" '
        map(
          if .ip == $ip and ((.isp? // "") == "") then
            . + {"isp-attempts": $isp_attempts}
          else
            .
          end
        )
      ' "$output" > "$tmp"
      mv "$tmp" "$output"
      trap - EXIT

      if ((isp_attempts >= ripestat_max_attempts)); then
        printf 'No ISP found for %s; lifetime limit reached after %s attempts.\n' \
          "$ip" "$isp_attempts" >&2
      else
        printf 'No ISP found for %s after %s lifetime attempts; leaving it for the next run.\n' \
          "$ip" "$isp_attempts" >&2
      fi
      continue
    fi
  elif [[ -z "$isp_date" ]]; then
    isp_date="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
  fi

  tmp="$(mktemp "${output}.tmp.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  jq \
    --arg ip "$ip" \
    --arg isp "$isp" \
    --arg isp_date "$isp_date" \
    --argjson isp_attempts "$isp_attempts" '
    map(
      if .ip == $ip and ((.isp? // "") == "") then
        . + {
          "isp": $isp,
          "isp-date": $isp_date,
          "isp-attempts": $isp_attempts
        }
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
