#!/usr/bin/env bash

# Shared project configuration loader.
#
# Execute the scripts that source this file; do not source those scripts into an
# interactive shell. Each script runs in a child process, so these variables do
# not leak into the parent terminal or another project.

project_script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${project_script_directory}/../.." && pwd)"
PROJECT_ENV_FILE="${PIPELINE_ENV_FILE:-${PROJECT_ROOT}/.env}"

require_project_variable() {
  local variable_name="$1"
  local variable_value="${!variable_name:-}"

  if [[ -z "${variable_value}" || "${variable_value}" == replace-* ]]; then
    printf 'Missing or placeholder value for %s in %s\n' \
      "${variable_name}" "${PROJECT_ENV_FILE}" >&2
    return 1
  fi
}

resolve_project_path() {
  local configured_path="$1"

  if [[ "${configured_path}" == /* ]]; then
    printf '%s\n' "${configured_path}"
  else
    printf '%s/%s\n' "${PROJECT_ROOT}" "${configured_path#./}"
  fi
}

load_project_environment() {
  if [[ ! -r "${PROJECT_ENV_FILE}" ]]; then
    printf 'Cannot read %s. Copy .env.example to .env and configure it.\n' \
      "${PROJECT_ENV_FILE}" >&2
    return 1
  fi

  local allexport_was_enabled=false
  if [[ "$-" == *a* ]]; then
    allexport_was_enabled=true
  else
    set -a
  fi

  # The local .env file is trusted shell syntax and is excluded from Git.
  # shellcheck disable=SC1090
  source "${PROJECT_ENV_FILE}"

  if [[ "${allexport_was_enabled}" == false ]]; then
    set +a
  fi

  require_project_variable GCP_PROJECT_ID
  require_project_variable BQ_LOCATION
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf '%s is not installed or not available on PATH.\n' "${command_name}" >&2
    return 1
  fi
}
