# Medallion Pipeline and BQML Challenge

A source-controlled BigQuery implementation of the retail Bronze, Silver, and Gold pipeline required
by the screening assessment. The current implementation covers source-faithful Bronze ingestion;
Silver and Gold will be added in their own phases.

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

## Bronze ingestion

The setup SQL creates the three required empty datasets in the location owned by the project
wrapper. This phase loads and validates only `retail_bronze.raw_transactions`.

```bash
./scripts/run_sql.sh sql/setup/create_datasets.sql
./scripts/load_bronze.sh
./scripts/run_sql.sh sql/bronze/bronze_assertions.sql
./scripts/run_sql.sh sql/bronze/bronze_profile.sql
```

The load validates the exact CSV header before using the committed seven-column `STRING` schema,
pins positional column matching, rejects any malformed record, and replaces the fixed assessment
snapshot on rerun. It deliberately does not use schema autodetection or convert the source text
`NULL` into a SQL null.

Run the focused local checks without contacting Google Cloud:

```bash
./tests/test_project_wrappers.sh
./tests/test_bronze_load.sh
uv run pre-commit run --all-files
```
