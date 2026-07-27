#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_directory}/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "${temporary_directory}"' EXIT

fake_bin="${temporary_directory}/bin"
mkdir -p "${fake_bin}"

fake_gcloud_log="${temporary_directory}/gcloud.args"
fake_bq_log="${temporary_directory}/bq.args"
fake_bq_input="${temporary_directory}/bq.stdin"
environment_file="${temporary_directory}/project.env"
sql_file="${temporary_directory}/query.sql"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "${FAKE_GCLOUD_LOG}"' \
  > "${fake_bin}/gcloud"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "${FAKE_BQ_LOG}"' \
  'while IFS= read -r line; do printf "%s\n" "${line}"; done > "${FAKE_BQ_INPUT}"' \
  > "${fake_bin}/bq"

chmod +x "${fake_bin}/gcloud" "${fake_bin}/bq"

printf '%s\n' \
  'GCP_PROJECT_ID=test-project-123' \
  'BQ_LOCATION=africa-south1' \
  "SOURCE_CSV_PATH=${project_root}/local_data/raw_transactions_10000.csv" \
  > "${environment_file}"

printf '%s\n' 'SELECT 1 AS connection_test;' > "${sql_file}"

export PATH="${fake_bin}:${PATH}"
export PIPELINE_ENV_FILE="${environment_file}"
export FAKE_GCLOUD_LOG="${fake_gcloud_log}"
export FAKE_BQ_LOG="${fake_bq_log}"
export FAKE_BQ_INPUT="${fake_bq_input}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"

  if ! grep -Fqx -- "${expected_text}" "${file_path}"; then
    fail "${file_path} does not contain expected argument: ${expected_text}"
  fi
}

setup_output="$("${project_root}/scripts/check_setup.sh")"
if [[ "${setup_output}" != *"${environment_file}"* ]]; then
  fail 'check_setup.sh did not report the selected PIPELINE_ENV_FILE'
fi

rm -f "${fake_gcloud_log}"
"${project_root}/scripts/gcloud.sh" services list --enabled
assert_file_contains "${fake_gcloud_log}" '--project=test-project-123'
assert_file_contains "${fake_gcloud_log}" 'services'

rm -f "${fake_gcloud_log}"
if "${project_root}/scripts/gcloud.sh" config set project other-project >/dev/null 2>&1; then
  fail 'gcloud.sh accepted a configuration-mutating command'
fi
if [[ -e "${fake_gcloud_log}" ]]; then
  fail 'gcloud was executed for a rejected configuration-mutating command'
fi

if "${project_root}/scripts/gcloud.sh" --project=other-project services list >/dev/null 2>&1; then
  fail 'gcloud.sh accepted a project override'
fi

rm -f "${fake_bq_log}" "${fake_bq_input}"
"${project_root}/scripts/run_sql.sh" "${sql_file}"
assert_file_contains "${fake_bq_log}" '--project_id=test-project-123'
assert_file_contains "${fake_bq_log}" '--location=africa-south1'
assert_file_contains "${fake_bq_log}" '--use_legacy_sql=false'
if ! grep -Fqx -- 'SELECT 1 AS connection_test;' "${fake_bq_input}"; then
  fail 'run_sql.sh did not send the SQL file to bq stdin'
fi

rm -f "${fake_bq_log}"
if "${project_root}/scripts/run_sql.sh" \
  "${sql_file}" --use_legacy_sql=true >/dev/null 2>&1; then
  fail 'run_sql.sh accepted an additional dialect override'
fi
if [[ -e "${fake_bq_log}" ]]; then
  fail 'bq was executed for a rejected dialect override'
fi

unset GCP_PROJECT_ID BQ_LOCATION SOURCE_CSV_PATH
"${project_root}/scripts/check_setup.sh" >/dev/null
if [[ -n "${GCP_PROJECT_ID:-}" || -n "${BQ_LOCATION:-}" || -n "${SOURCE_CSV_PATH:-}" ]]; then
  fail 'wrapper environment leaked into the parent shell'
fi

printf 'PASS: project wrapper regression tests\n'
