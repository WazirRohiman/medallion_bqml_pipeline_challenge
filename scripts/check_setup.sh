#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project_env.sh
source "${script_directory}/lib/project_env.sh"

load_project_environment

setup_is_valid=true

for required_command in gcloud bq; do
  if command -v "${required_command}" >/dev/null 2>&1; then
    printf '[ok] %s is installed\n' "${required_command}"
  else
    printf '[missing] %s is not installed\n' "${required_command}" >&2
    setup_is_valid=false
  fi
done

source_csv="$(resolve_project_path "${SOURCE_CSV_PATH:-}")"

if [[ -f "${source_csv}" ]]; then
  printf '[ok] source CSV exists\n'
else
  printf '[missing] source CSV does not exist at configured path\n' >&2
  setup_is_valid=false
fi

printf '[ok] project configuration loaded from %s\n' "${PROJECT_ENV_FILE}"
printf '[ok] commands will use project %s in %s\n' \
  "${GCP_PROJECT_ID}" "${BQ_LOCATION}"

if [[ "${setup_is_valid}" != true ]]; then
  exit 1
fi
