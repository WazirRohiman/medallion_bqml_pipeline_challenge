# Medallion Pipeline and BQML Challenge

A source-controlled BigQuery implementation of the retail Bronze, Silver, and Gold pipeline required
by the screening assessment.

The project is currently in its setup phase. Pipeline SQL will be added after the local tooling and
cloud connectivity checks pass.

## Local prerequisites

- Google Cloud CLI, including `gcloud` and `bq`
- `uv`
- A configured, ignored `.env` copied from `.env.example`

## Project-local commands

The wrappers load `.env` inside child processes, so environment loading does not alter `.bashrc` or
the parent shell. The `gcloud` wrapper pins the project from `.env` and rejects attempts to override
or mutate the active CLI configuration. Explicit cloud commands still perform their requested
Google Cloud or BigQuery operation.

```bash
./scripts/check_setup.sh
./scripts/bq.sh query --use_legacy_sql=false 'SELECT 1 AS connection_test'
./scripts/run_sql.sh sql/path/to/query.sql
```

Install the development tools and Git hooks:

```bash
uv sync
uv run pre-commit install
./tests/test_project_wrappers.sh
uv run pre-commit run --all-files
```

The supplied CSV and assessment instructions are intentionally excluded from Git.
