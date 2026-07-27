#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project_env.sh
source "${script_directory}/lib/project_env.sh"

load_project_environment
require_project_variable SOURCE_CSV_PATH

source_csv="$(resolve_project_path "${SOURCE_CSV_PATH}")"
schema_file="${PROJECT_ROOT}/schemas/raw_transactions.json"

if [[ ! -r "${source_csv}" || ! -f "${source_csv}" ]]; then
  printf 'Cannot read source CSV: %s\n' "${source_csv}" >&2
  exit 1
fi

if [[ ! -r "${schema_file}" || ! -f "${schema_file}" ]]; then
  printf 'Cannot read Bronze schema: %s\n' "${schema_file}" >&2
  exit 1
fi

expected_header='transaction_id,customer_id,signup_date,purchase_date,amount,item_category,is_returned'
IFS= read -r source_header < "${source_csv}"
source_header="${source_header%$'\r'}"

if [[ "${source_header}" != "${expected_header}" ]]; then
  printf 'Source CSV header does not match the Bronze contract.\n' >&2
  exit 1
fi

# This assessment supplies one fixed snapshot. Replacement makes an identical
# replay idempotent; a recurring feed would require separately agreed semantics.
exec "${PROJECT_ROOT}/scripts/bq.sh" load \
  --source_format=CSV \
  --encoding=UTF-8 \
  --field_delimiter=, \
  --skip_leading_rows=1 \
  --source_column_match=POSITION \
  --max_bad_records=0 \
  --replace \
  "${GCP_PROJECT_ID}:retail_bronze.raw_transactions" \
  "${source_csv}" \
  "${schema_file}"
