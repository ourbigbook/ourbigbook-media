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
command -v base64 >/dev/null
db_dir="$script_dir/db"
db_output="$db_dir/users.json"
mkdir -p "$db_dir"
if [[ -f "$db_output" ]]; then
  downloaded_usernames_base64="$(jq --compact-output '[.[].username]' "$db_output" | base64 --wrap=0)"
else
  downloaded_usernames_base64="W10="
fi
db_new_tmp="$(mktemp "$db_dir/users.new.json.tmp.XXXXXX")"
trap 'rm -f "$db_new_tmp"' EXIT

heroku psql -a ourbigbook DATABASE_URL <<EOF > "$db_new_tmp"
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
      SELECT json_agg(json_build_object(
        'id', a.id,
        'slug', a.slug,
        'title', a."titleSource",
        'body', f."bodySource"
      ) ORDER BY a.id)
      FROM "Article" a
      LEFT JOIN "File" f ON f.id = a."fileId"
      WHERE a."authorId" = u.id
    ), '[]'::json) AS articles,
    coalesce((
      SELECT json_agg(json_build_object(
        'id', i.id,
        'title', i."titleSource",
        'body', i."bodySource"
      ) ORDER BY i.id)
      FROM "Issue" i
      WHERE i."authorId" = u.id
    ), '[]'::json) AS issues,
    coalesce((
      SELECT json_agg(json_build_object(
        'id', c.id,
        'source', c.source
      ) ORDER BY c.id)
      FROM "Comment" c
      WHERE c."authorId" = u.id
    ), '[]'::json) AS comments
  FROM "User" u
  WHERE
    u.locked = true
    AND NOT EXISTS (
      SELECT 1
      FROM json_array_elements_text(
        convert_from(decode('${downloaded_usernames_base64}', 'base64'), 'UTF8')::json
      ) AS downloaded(username)
      WHERE downloaded.username = u.username
    )
  ORDER BY u."createdAt" DESC
) r;
EOF

jq --exit-status 'if type == "array" then true else error("expected a JSON array") end' \
  "$db_new_tmp" >/dev/null

db_tmp="$(mktemp "$db_dir/users.json.tmp.XXXXXX")"
if [[ -f "$db_output" ]]; then
  jq --slurpfile fresh "$db_new_tmp" '
    reduce $fresh[0][] as $user (
      .;
      if any(.[]; .username == $user.username) then
        map(if .username == $user.username then $user else . end)
      else
        . + [$user]
      end
    )
  ' "$db_output" > "$db_tmp"
else
  jq '.' "$db_new_tmp" > "$db_tmp"
fi
chmod 0600 "$db_tmp"
mv "$db_tmp" "$db_output"

tmp="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
python3 "$script_dir/extract_identifiers.py" "${existing_args[@]}" \
  < "$db_new_tmp" > "$tmp"

if [[ -f "$existing" ]]; then
  chmod --reference="$existing" "$tmp"
else
  chmod 0644 "$tmp"
fi
mv "$tmp" "$output"
rm -f "$db_new_tmp"
trap - EXIT

if [[ "${SKIP_ISP_LOOKUPS:-0}" == 1 ]]; then
  exit 0
fi

command -v curl >/dev/null
ripestat_url="${RIPESTAT_URL:-https://stat.ripe.net/data/prefix-overview/data.json}"
ripestat_delay="${RIPESTAT_DELAY_SECONDS:-0.25}"
ripestat_retries="${RIPESTAT_RETRIES:-3}"
ripestat_max_attempts="${RIPESTAT_MAX_ATTEMPTS:-9}"
ripestat_retry_delay="${RIPESTAT_RETRY_DELAY_SECONDS:-5}"
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
  isp_failure="$(jq --raw-output --arg ip "$ip" '
    first(.[] | select(.ip == $ip and (.ispFailure? | type == "string")) | .ispFailure) // empty
  ' "$output")"
  has_isp_failure=false
  if jq --exit-status --arg ip "$ip" '
    any(.[]; .ip == $ip and (.ispFailure? | type == "string"))
  ' "$output" >/dev/null; then
    has_isp_failure=true
  fi
  queried=false

  if [[ -z "$isp" ]] && "$has_isp_failure"; then
    tmp="$(mktemp "${output}.tmp.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    jq \
      --arg ip "$ip" \
      --arg isp_failure "$isp_failure" \
      --argjson isp_attempts "$isp_attempts" '
      map(
        if .ip == $ip and ((.isp? // "") == "") then
          . + {
            "ispFailure": $isp_failure,
            "isp-attempts": $isp_attempts
          }
        else
          .
        end
      )
    ' "$output" > "$tmp"
    mv "$tmp" "$output"
    trap - EXIT
    continue
  fi

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

      # curl reports both connect and overall operation timeouts with exit 28.
      if ((ripestat_status != 28)) && [[ -z "$isp" ]]; then
        isp_failure="$(<"$ripestat_tmp")"
        has_isp_failure=true
      fi

      rm -f "$ripestat_tmp"
      trap - EXIT

      if [[ -n "$isp" ]]; then
        isp_date="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
        queried=true
        break
      fi

      if "$has_isp_failure"; then
        printf 'RIPEstat lookup failed for %s without a timeout (curl exit %s); recording ispFailure and not retrying.\n' \
          "$ip" "$ripestat_status" >&2
        break
      fi

      if ((attempt < ripestat_retries && isp_attempts < ripestat_max_attempts)); then
        printf 'RIPEstat attempt %s/%s timed out for %s; retrying in %s seconds.\n' \
          "$attempt" "$ripestat_retries" "$ip" "$ripestat_retry_delay" >&2
        sleep "$ripestat_retry_delay"
      fi
    done

    if [[ -z "$isp" ]]; then
      tmp="$(mktemp "${output}.tmp.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT
      jq \
        --arg ip "$ip" \
        --argjson isp_attempts "$isp_attempts" \
        --arg isp_failure "$isp_failure" \
        --argjson has_isp_failure "$has_isp_failure" '
        map(
          if .ip == $ip and ((.isp? // "") == "") then
            . + {"isp-attempts": $isp_attempts}
            | if $has_isp_failure then . + {"ispFailure": $isp_failure} else . end
          else
            .
          end
        )
      ' "$output" > "$tmp"
      mv "$tmp" "$output"
      trap - EXIT

      if "$has_isp_failure"; then
        printf 'No ISP found for %s; saved the non-timeout failure output.\n' "$ip" >&2
      elif ((isp_attempts >= ripestat_max_attempts)); then
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
        and (.ispFailure? | type != "string")
        and (.ip? | type == "string")
        and (.ip | length > 0)
      )
    | .ip
  ]
  | unique[]
' "$output")
