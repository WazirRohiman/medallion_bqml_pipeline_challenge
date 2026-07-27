#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project_env.sh
source "${script_directory}/lib/project_env.sh"

usage() {
  printf 'Usage: %s PATH_TO_SQL\n' "$0" >&2
}

if [[ $# -ne 1 ]]; then
  if [[ $# -gt 1 ]]; then
    printf 'Additional bq flags are not accepted; the runner owns the GoogleSQL execution contract.\n' >&2
  fi
  usage
  exit 2
fi

sql_file="$1"

if [[ "${sql_file}" != /* ]]; then
  sql_file="${PROJECT_ROOT}/${sql_file#./}"
fi

if [[ ! -r "${sql_file}" ]]; then
  printf 'Cannot read SQL file: %s\n' "${sql_file}" >&2
  exit 1
fi

load_project_environment
require_command bq

exec bq \
  --project_id="${GCP_PROJECT_ID}" \
  --location="${BQ_LOCATION}" \
  query \
  --use_legacy_sql=false \
  < "${sql_file}"
