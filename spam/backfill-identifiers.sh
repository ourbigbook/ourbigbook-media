#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# With no arguments, rebuild identifiers for every audited user. Pass one or
# more usernames to update only that subset. This never accesses the database.
exec python3 "$script_dir/extract_identifiers.py" \
  --audit "$script_dir/db/users.json" \
  --update "$script_dir/data.json" \
  "$@"
