# Local Command Wrappers

These wrappers load the selected ignored environment file inside a child process. Environment
loading itself does not modify `.bashrc` or the parent terminal. The `gcloud` wrapper pins the
project from `.env` and rejects project/configuration overrides and configuration-mutating
subcommands.

The wrappers still execute the operation explicitly requested by the caller. Commands such as
`services enable`, table creation, and query execution intentionally change Google Cloud or BigQuery
resources.

Run them from any directory:

```bash
./scripts/check_setup.sh
./scripts/bq.sh ls
./scripts/gcloud.sh services list --enabled
./scripts/run_sql.sh sql/path/to/query.sql
```

Pass normal command arguments after the wrapper:

```bash
./scripts/bq.sh query --use_legacy_sql=false 'SELECT 1 AS connection_test'
```

The SQL runner automatically supplies the configured project, BigQuery location, and GoogleSQL
dialect. It does not accept extra `bq query` flags, so callers cannot override that execution
contract:

```bash
./scripts/run_sql.sh sql/silver/silver_transform.sql
```

Do not run a wrapper with `source`. Executing it normally ensures its environment is discarded when
the command exits.

To use a different environment file for a one-off command:

```bash
PIPELINE_ENV_FILE=/absolute/path/to/another.env ./scripts/bq.sh ls
```

`check_setup.sh` reports the selected path, including when this override is used.

Run the wrapper regression tests without contacting Google Cloud:

```bash
./tests/test_project_wrappers.sh
```
