#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project_env.sh
source "${script_directory}/lib/project_env.sh"

load_project_environment
require_command gcloud

arguments=("$@")

for argument in "${arguments[@]}"; do
  case "${argument}" in
    --project | --project=* | --configuration | --configuration=* | --flags-file | --flags-file=*)
      printf 'Project, configuration, and flags-file overrides are not allowed through this wrapper.\n' >&2
      printf 'Update .env for this project or run gcloud directly for an intentional global configuration change.\n' >&2
      exit 2
      ;;
  esac
done

for ((index = 0; index < ${#arguments[@]}; index++)); do
  if [[ "${arguments[index]}" != config ]]; then
    continue
  fi

  config_command="${arguments[index + 1]:-}"
  if [[ "${config_command}" == set || "${config_command}" == unset ]]; then
    printf 'gcloud config %s is not allowed through this project-scoped wrapper.\n' \
      "${config_command}" >&2
    exit 2
  fi

  if [[ "${config_command}" == configurations ]]; then
    configuration_command="${arguments[index + 2]:-}"
    if [[ "${configuration_command}" != list && "${configuration_command}" != describe ]]; then
      printf 'Mutating gcloud configurations is not allowed through this project-scoped wrapper.\n' >&2
      exit 2
    fi
  fi
done

exec gcloud \
  --project="${GCP_PROJECT_ID}" \
  "${arguments[@]}"
