# Medallion Pipeline and BQML Challenge

This repository implements a small, source-controlled retail data pipeline for a data-engineering
screening assessment. It uses BigQuery for ingestion, transformation, data-quality validation, and
eventually native BQML clustering. This README is the reviewer’s guided tour: it explains what has
been delivered, how data moves through the layers, and why the important engineering decisions were
made without requiring the SQL and Bash files to be read first.

Bronze ingestion and Silver transformation are complete. Gold modelling and prediction are the next
phase.

## Challenge coverage

| Challenge requirement | What this implementation does | Evidence | Status |
|---|---|---|---|
| Create the three Medallion datasets | Creates `retail_bronze`, `retail_silver`, and `retail_gold` in one configured BigQuery location | Dataset setup script and wrapper tests | Complete |
| Load the supplied CSV into `retail_bronze.raw_transactions` | Loads the fixed snapshot unchanged with an explicit all-`STRING` schema and rerun-safe replacement | Bronze contract assertions and profile | Complete |
| Produce `retail_silver.cleaned_transactions` | Casts dates, amount, and return flag; applies the required defaults; filters non-positive amounts; calculates `days_to_first_purchase` | Pre-publication checks, reusable Silver assertions, fixture, and profile | Complete |
| Build a native K-means model | Will train in BigQuery using the required `amount` and `item_category` features | Model SQL and evaluation evidence | Next phase |
| Save predictions to `retail_gold.analytics_customer_segments` | Will retain the clean transaction columns and add a controlled, flat cluster result | Gold assertions and BigQuery proof | Next phase |
| Explain production orchestration | Will describe the dependency order, quality gates, retries, and recommended BigQuery-native orchestration | README production section | Pending Gold completion |
| Provide final schema, preview, and model evidence | Will be captured only after the completed Gold pipeline has run | `proof/` artefacts | Pending Gold completion |

The required clean Silver table is kept deliberately simple. The rejected-row table, missingness
flags, source-contract checks, fixtures, and profiles are small supporting controls: they make row
loss and silent coercion visible without changing the challenge’s business rules.

## Pipeline overview

```text
Gitignored source CSV
        |
        | explicit all-STRING schema and replacement load
        v
retail_bronze.raw_transactions
        |
        | normalise expected missing markers
        | cast once, validate once, route every row
        +-------------------------------+
        |                               |
        v                               v
retail_silver.cleaned_transactions   retail_silver.rejected_transactions
        |
        | planned BQML K-means model using amount and item_category
        v
retail_gold.analytics_customer_segments
```

The source and all outputs remain at one row per transaction. Despite the future Gold table’s
customer-oriented name, the required model features describe transactions; the project will not
silently aggregate them into customer records.

A reviewer can use the remainder of this README as the primary explanation of the solution. The
linked SQL, tests, and engineering notes provide implementation evidence and deeper decision
lineage when required.

## Design decisions

### Bronze preserves the supplied source

The assessment asks for the CSV to be loaded before cleansing. Bronze therefore uses a committed
seven-column `STRING` schema and keeps the source text `NULL` as text. Type inference and
loader-level null conversion are deliberately disabled because they would move Silver
responsibilities into ingestion.

Before loading, the wrapper validates the exact CSV header. The load then:

- skips the header;
- maps fields by explicit position;
- accepts no malformed records;
- replaces the fixed assessment snapshot instead of appending it.

Replacement makes rerunning this one supplied file idempotent. It is not presented as a general
production ingestion strategy. A recurring feed would require agreed append, deduplication, replay,
late-arrival, and source-manifest rules.

### Silver separates expected missing data from invalid data

Silver converts dates to `DATE`, amounts to `NUMERIC`, and return flags to `BOOL`. The documented
missing markers have explicit business handling:

- missing `signup_date` defaults to `purchase_date`;
- missing `is_returned` defaults to `FALSE`;
- both decisions are retained in missingness flags.

`SAFE_CAST` prevents one malformed value from crashing parsing, but it can also hide corruption by
returning a SQL null. The transformation therefore keeps the original strings until validation is
complete. Expected missing values are defaulted, while unexpected values are rejected with clear
reasons.

Clean rows must have positive amounts and non-negative signup-to-purchase intervals. Invalid rows
are excluded from the mandatory `cleaned_transactions` table.

The challenge does not require a rejected-row table; `rejected_transactions` is a small,
intentional extension. Filtering alone would make invalid rows disappear without showing which
records were removed or why. Routing them to a separate table preserves their original Bronze
values and every applicable rejection reason, while keeping Gold dependent only on the required
clean table. It also makes the pipeline auditable through the reconciliation:

```text
Bronze rows = clean Silver rows + rejected Silver rows
```

Expected row-level problems are routed rather than allowed to fail the whole transformation.
Broken pipeline invariants—such as lost rows, duplicated routing, or invalid values reaching the
clean table—still fail an assertion and stop publication.

### Silver validation is defined once

`silver_transform.sql` creates one temporary validated table containing the normalised values,
typed values, lineage flags, and rejection reasons. Both Silver outputs are derived from that shared
result, avoiding separate casting logic that could drift over time.

Before either persistent table is replaced, the script verifies that:

- validation retained every Bronze row;
- every row was routed to exactly one output;
- clean rows contain all required values;
- clean amounts and date calculations satisfy their business rules.

If one of these assertions fails, the BigQuery script stops immediately and the existing persistent
Silver tables remain unchanged.

BigQuery cannot include permanent `CREATE OR REPLACE TABLE` statements in a multi-statement
transaction. After the pre-publication checks pass, the script therefore replaces the rejected
table first and the mandatory clean table last. Each replacement is atomic individually, but the two
replacements are not one transaction. A later independent assertion suite detects any inconsistency
and must pass before Gold processing begins.

## Current data contracts

| Table | Purpose | Grain |
|---|---|---|
| `retail_bronze.raw_transactions` | Source-faithful CSV contents stored as strings | One row per source transaction |
| `retail_silver.cleaned_transactions` | Typed, validated transactions used by Gold | One row per valid transaction |
| `retail_silver.rejected_transactions` | Original invalid rows with all rejection reasons | One row per rejected transaction |

The supplied snapshot currently produces:

| Metric | Result |
|---|---:|
| Bronze rows | 10,000 |
| Clean Silver rows | 9,593 |
| Rejected Silver rows | 407 |
| Clean signup imputations | 781 |
| Clean return-flag imputations | 974 |

These figures describe the assessed snapshot. Reusable assertions validate schemas, relationships,
domains, uniqueness, and lineage rather than hard-coding these counts as permanent rules.

## Running the project

### Prerequisites

- Google Cloud CLI, including `gcloud` and `bq`
- `uv`
- An ignored `.env` copied from `.env.example`
- The supplied CSV at the configured `SOURCE_CSV_PATH`

The wrappers load `.env` only inside their child processes. They do not modify `.bashrc` or leak
project variables into the parent terminal. Commands are pinned to the configured project and
BigQuery location.

Install the local quality tools and hooks:

```bash
uv sync
uv run pre-commit install
./scripts/check_setup.sh
```

### Bronze

```bash
./scripts/run_sql.sh sql/setup/create_datasets.sql
./scripts/load_bronze.sh
./scripts/run_sql.sh sql/bronze/bronze_assertions.sql
./scripts/run_sql.sh sql/bronze/bronze_profile.sql
```

### Silver

```bash
./scripts/run_sql.sh sql/silver/silver_transform.sql
./scripts/run_sql.sh sql/tests/silver_assertions.sql
./scripts/run_sql.sh sql/tests/silver_transform_fixture.sql
./scripts/run_sql.sh sql/silver/silver_profile.sql
```

The reusable Silver assertions run after publication. If they fail, BigQuery does not roll the
tables back; the failed validation job is the signal to stop the pipeline before Gold, investigate,
and rerun after correction.

The fixture creates temporary resources only. It covers every rejection reason plus both required
imputations, padded missing markers, mixed-case Boolean text, zero and negative amounts, multiple
simultaneous errors, and genuine same-day activity.

### Local checks

These checks do not contact Google Cloud:

```bash
./tests/test_project_wrappers.sh
./tests/test_bronze_load.sh
uv run pre-commit run --all-files
```

## Security and scope

- The supplied CSV and private assessment instructions are excluded from Git.
- `.env` files and credential files are excluded from Git.
- Interactive Google authentication is used; no service-account JSON key is required.
- SQL uses portable `dataset.table` paths, while project and location selection are owned by the
  command wrappers.
- There is no frontend, backend service, Python transformation package, container, or orchestration
  platform because none is required for this SQL-first assessment.
- Partitioning and clustering are deferred because the current tables are too small to receive a
  measured benefit.

## Further detail

- [Assessment and architecture review](docs/assessment_report.md)
- [Worked engineering risks and examples](docs/engineering_risks.md)
- [Command-wrapper behavior](scripts/README.md)
- [SQL organisation](sql/README.md)
