#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project_env.sh
source "${script_directory}/lib/project_env.sh"

load_project_environment
require_command bq

exec bq \
  --project_id="${GCP_PROJECT_ID}" \
  --location="${BQ_LOCATION}" \
  "$@"
