#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_directory}/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "${temporary_directory}"' EXIT

fake_bin="${temporary_directory}/bin"
fake_bq_log="${temporary_directory}/bq.args"
environment_file="${temporary_directory}/project.env"
source_csv="${temporary_directory}/source.csv"

mkdir -p "${fake_bin}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "${FAKE_BQ_LOG}"' \
  > "${fake_bin}/bq"
chmod +x "${fake_bin}/bq"

printf '%s\n' \
  'transaction_id,customer_id,signup_date,purchase_date,amount,item_category,is_returned' \
  'TXN1,CUST1,NULL,2026-01-01,10.00,Apparel,NULL' \
  > "${source_csv}"

printf '%s\n' \
  'GCP_PROJECT_ID=test-project-123' \
  'BQ_LOCATION=africa-south1' \
  "SOURCE_CSV_PATH=${source_csv}" \
  > "${environment_file}"

export PATH="${fake_bin}:${PATH}"
export PIPELINE_ENV_FILE="${environment_file}"
export FAKE_BQ_LOG="${fake_bq_log}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_arguments_equal() {
  local -a expected_arguments=("$@")
  local -a actual_arguments
  local index

  mapfile -t actual_arguments < "${fake_bq_log}"

  if [[ ${#actual_arguments[@]} -ne ${#expected_arguments[@]} ]]; then
    fail "bq received ${#actual_arguments[@]} arguments; expected ${#expected_arguments[@]}"
  fi

  for ((index = 0; index < ${#expected_arguments[@]}; index++)); do
    if [[ "${actual_arguments[index]}" != "${expected_arguments[index]}" ]]; then
      fail "bq argument ${index} was '${actual_arguments[index]}'; expected '${expected_arguments[index]}'"
    fi
  done
}

"${project_root}/scripts/load_bronze.sh"

assert_arguments_equal \
  '--project_id=test-project-123' \
  '--location=africa-south1' \
  'load' \
  '--source_format=CSV' \
  '--encoding=UTF-8' \
  '--field_delimiter=,' \
  '--skip_leading_rows=1' \
  '--source_column_match=POSITION' \
  '--max_bad_records=0' \
  '--replace' \
  'test-project-123:retail_bronze.raw_transactions' \
  "${source_csv}" \
  "${project_root}/schemas/raw_transactions.json"

printf '%s\n' \
  'GCP_PROJECT_ID=test-project-123' \
  'BQ_LOCATION=africa-south1' \
  "SOURCE_CSV_PATH=${temporary_directory}/missing.csv" \
  > "${environment_file}"

rm -f "${fake_bq_log}"
if "${project_root}/scripts/load_bronze.sh" >/dev/null 2>&1; then
  fail 'Bronze load accepted a missing source file'
fi
if [[ -e "${fake_bq_log}" ]]; then
  fail 'bq was executed after source-file validation failed'
fi

printf '%s\n' \
  'customer_id,transaction_id,signup_date,purchase_date,amount,item_category,is_returned' \
  'CUST1,TXN1,NULL,2026-01-01,10.00,Apparel,NULL' \
  > "${source_csv}"

printf '%s\n' \
  'GCP_PROJECT_ID=test-project-123' \
  'BQ_LOCATION=africa-south1' \
  "SOURCE_CSV_PATH=${source_csv}" \
  > "${environment_file}"

if "${project_root}/scripts/load_bronze.sh" >/dev/null 2>&1; then
  fail 'Bronze load accepted a reordered source header'
fi
if [[ -e "${fake_bq_log}" ]]; then
  fail 'bq was executed after source-header validation failed'
fi

printf 'PASS: Bronze load wrapper tests\n'
