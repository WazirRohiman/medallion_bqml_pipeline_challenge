# Medallion Pipeline and BQML Challenge

This repository implements a small, source-controlled retail data pipeline for a data-engineering
screening assessment. It uses BigQuery for ingestion, transformation, data-quality validation, and
native BQML clustering. This README explains what has been developed, how data moves through the
layers, and what engineering decisions were made.

## Challenge coverage

| Challenge requirement | What this implementation does | Evidence | Status |
|---|---|---|---|
| Create the three Medallion datasets | Creates `retail_bronze`, `retail_silver`, and `retail_gold` in one configured BigQuery location | Dataset setup script and wrapper tests | Complete |
| Load the supplied CSV into `retail_bronze.raw_transactions` | Loads the fixed snapshot unchanged with an explicit all-`STRING` schema and rerun-safe replacement | Bronze contract assertions and profile | Complete |
| Produce `retail_silver.cleaned_transactions` | Casts dates, amount, and return flag; applies the required defaults; filters non-positive amounts; calculates `days_to_first_purchase` | Pre-publication checks, reusable Silver assertions, fixture, and profile | Complete |
| Build a native K-means model | Trains a four-cluster BigQuery model using only the required `amount` and `item_category` features | Model SQL, feature inspection, centroids, and evaluation | Complete |
| Save predictions to `retail_gold.analytics_customer_segments` | Retains every clean transaction column and adds a controlled, flat `cluster_id` | Gold pre-publication and reusable assertions | Complete |
| Explain production orchestration | Documents dependency order, quality gates, retries, and a proportionate Dataform design | Production orchestration section | Complete |
| Provide final schema, preview, and model evidence | Supplies reproducible evidence queries; the console screenshots require final manual capture | `proof/` checklist | Uploaded |

The required clean Silver table is kept deliberately simple as per the brief. The rejected-row
table, missingness flags, source-contract checks, fixtures, and profiles are small supporting
controls: they make row loss and silent coercion visible without changing the challenge’s rules.

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
        | BQML K-means model using amount and item_category
        v
retail_gold.analytics_customer_segments
```

The source and all outputs remain at one row per transaction. Despite the Gold table’s
customer-oriented name, the required model features describe transactions; the project does not
silently aggregate them into customer records.

Please use the remainder of this README as the primary explanation of the solution. The
linked SQL, tests, and engineering notes provide implementation evidence and deeper decision
lineage when required.

## Design decisions

### Bronze preserves the supplied source

The assessment asks for the CSV to be loaded before cleansing. Bronze uses a committed
seven-column `STRING` schema and keeps the source text `NULL` as text. Type inference and
loader-level null conversion are deliberately disabled because they would move Silver layer
responsibilities into ingestion, which we do not want.

Before loading, the wrapper validates the exact CSV header. The load then:

- skips the header;
- maps fields by explicit position;
- accepts no malformed records;
- replaces the fixed assessment snapshot instead of appending it.

Replacement makes rerunning this one supplied file idempotent. Idempotency in this case is fine
because this single small dataset can be dropped and recreated at any time. I would not recommend
this approach as a production ingestion strategy. A recurring data feed would require agreed
append, deduplication, replay, late-arrival, and source-manifest rules plus a metadata tracking
strategy to manage ingestion and processing.

### Silver separates expected missing data from invalid data

Silver converts dates to `DATE`, amounts to `NUMERIC`, and return flags to `BOOL`. The documented
missing markers have explicit business handling:

- missing `signup_date` defaults to `purchase_date`;
- missing `is_returned` defaults to `FALSE`;
- both decisions are retained in missingness flags.

I opted for `SAFE_CAST` because it prevents one malformed value from crashing parsing, but it can
also hide corruption by returning a SQL null. The transformation therefore keeps the original
strings until validation is complete. Expected missing values are defaulted, while unexpected
values are rejected with clear reasons.

Clean rows must have positive amounts and non-negative signup-to-purchase intervals. Invalid rows
are excluded from the mandatory `cleaned_transactions` table.

The challenge does not require a rejected-row table. I added `rejected_transactions` as a small,
intentional extension for sanity checks. Filtering alone would make invalid rows disappear without
showing which records were removed or why. Routing them to a separate table preserves their
original Bronze values and every applicable rejection reason, while keeping Gold dependent only on
the required clean table. It also makes the pipeline auditable through the reconciliation:

```text
Bronze rows = clean Silver rows + rejected Silver rows
```

Expected row-level problems are routed rather than allowed to fail the whole transformation.
Broken pipeline invariants such as lost rows, duplicated routing, or invalid values reaching the
clean table still fail an assertion and stop publication.

### Silver validation is defined once

`silver_transform.sql` creates one temporary validated table containing the normalised values,
typed values, lineage flags, and rejection reasons. Both Silver outputs are derived from that shared
result, avoiding separate casting logic that could drift over time.

Before either persistent table is replaced, the script verifies that:

- validation retained every Bronze row;
- every row was routed to exactly one output;
- clean rows contain all required values;
- clean amounts and date calculations satisfy the brief's requirements.

If one of these assertions fails, the BigQuery script stops immediately and the existing persistent
Silver tables remain unchanged.

BigQuery cannot include permanent `CREATE OR REPLACE TABLE` statements in a multi-statement
transaction. After the pre-publication checks pass, the script therefore replaces the rejected
table first and the mandatory clean table last. Each replacement is atomic individually, but the
two replacements are not one transaction. A later independent assertion suite detects any
inconsistency and must pass before Gold processing begins.

### Gold keeps model features and warehouse grain explicit

The model uses exactly the two features named by the challenge: numeric `amount` and categorical
`item_category`. I added `STANDARDIZE_FEATURES = TRUE` to prevent the larger raw amount scale from
overwhelming it. Four clusters are configured explicitly as a small, conscious decision, but this
does not mean that four clusters are statistically optimal. A data scientist would need to verify
the approach and results.

Since K-means is unsupervised clustering, it describes similar transaction behaviour, not a durable
customer segment. Based on the dataset, one customer may have transactions in different clusters.

The complete Silver row is passed through `ML.PREDICT`, so its `transaction_id` remains attached to
the prediction without joining on duplicated feature values. Gold selects every output column
explicitly, renames `centroid_id` to `cluster_id`, and omits the nested diagnostic
`nearest_centroids_distance` array to keep the table clean.

`CREATE OR REPLACE MODEL` and `CREATE OR REPLACE TABLE` make operational reruns safe, but retraining
can change centroids or numeric cluster IDs. A cluster ID is consequently documented as a
model-local identifier rather than a stable business code.

## Current data contracts

| Asset | Purpose | Grain |
|---|---|---|
| `retail_bronze.raw_transactions` | Source-faithful CSV contents stored as strings | One row per source transaction |
| `retail_silver.cleaned_transactions` | Typed, validated transactions used by Gold | One row per valid transaction |
| `retail_silver.rejected_transactions` | Original invalid rows with all rejection reasons | One row per rejected transaction |
| `retail_gold.customer_segmentation_model` | Four-cluster native BQML model using the two required features | Trained from valid transactions |
| `retail_gold.analytics_customer_segments` | Clean transactions plus their model-local cluster assignment | One row per valid transaction |

The supplied snapshot currently produces:

| Metric | Result |
|---|---:|
| Bronze rows | 10,000 |
| Clean Silver rows | 9,593 |
| Rejected Silver rows | 407 |
| Gold rows | 9,593 |
| Clean signup imputations | 781 |
| Clean return-flag imputations | 974 |

These figures describe the assessed snapshot. Instead of hard-coding these counts as permanent
rules, I added reusable assertions that validate schemas, relationships, domains, uniqueness, and
lineage.

## Running the project

### Prerequisites

- Google Cloud CLI, including `gcloud` and `bq`
- `uv`
- An ignored `.env` copied from `.env.example`
- The supplied CSV at the configured `SOURCE_CSV_PATH`

The wrappers load `.env` only inside their child processes. The bash commands are pinned to the configured project and
BigQuery location.

Install the local dev tools and hooks:

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

The fixture creates temporary resources only.

### Gold

```bash
./scripts/run_sql.sh sql/gold/gold_model_training.sql
./scripts/run_sql.sh sql/gold/gold_prediction.sql
./scripts/run_sql.sh sql/tests/gold_assertions.sql
./scripts/run_sql.sh sql/tests/gold_guardrail_fixture.sql
./scripts/run_sql.sh sql/gold/gold_model_evaluation.sql
./scripts/run_sql.sh sql/gold/gold_cluster_profile.sql
```

Training and prediction are separate files because the challenge requests both deliverables. Run
them as one ordered Gold unit. If either job or the following assertions fail, stop downstream use,
investigate, and rerun model training followed by prediction so the model and table remain aligned.
Training checks the row count, model-feature contract, and the presence of at least four distinct
feature vectors before replacing the four-cluster model.

Prediction first copies clean Silver into a temporary source table. It rechecks the feature
contract because BQML can impute missing feature values, then uses that same snapshot for
`ML.PREDICT` and the pre-publication comparisons. A concurrent Silver replacement therefore cannot
make prediction and validation observe different Silver versions. Only an exact, unique,
one-prediction-per-source-row result replaces the persistent Gold table. The guardrail fixture
covers duplicate feature vectors and every invalid model-input branch without creating a model.

### Local checks

These checks do not interact with Google Cloud:

```bash
./tests/test_project_wrappers.sh
./tests/test_bronze_load.sh
uv run pre-commit run --all-files
```

## Production orchestration

For recurring data in a production pipeline, Dataform would be an appropriate Google Cloud choice.
Its action graph would order dataset setup → Bronze load contract → Silver transformation → Silver
assertions → model training → Gold prediction → Gold assertions, with evaluation and profiling
downstream of the quality gate.

That assertion gate must be configured explicitly in a future Dataform implementation. An ordinary
dependency on a table orders the actions but does not automatically make downstream actions depend
on that table's assertions. Gold training must name the Silver assertion actions as dependencies,
or use `includeDependentAssertions: true` for the selected Silver dependency (or
`dependOnDependencyAssertions: true` for all direct dependencies). Evaluation and profiling must
similarly depend on the Gold assertion actions. With those dependencies declared, a failed
assertion prevents dependent actions from running; retries restart from the failed dependency, with
the model and prediction rerun together after a Gold failure. This README documents that production
design briefly and does not include a Dataform project.

See Google's documentation on
[setting assertions as Dataform dependencies](https://cloud.google.com/dataform/docs/dependencies#set_assertions_as_dependencies).
Workflow logs and BigQuery job metadata would provide execution evidence.

Scheduled Queries could run this small pipeline, but dependency management, assertion gating, and
notifications would need more manual coordination. Production execution should use a dedicated
least-privilege service account and separate environment-specific projects or datasets rather than
the interactive credentials used for this assessment.

## Proof and AI use

The model evaluation, feature inspection, centroid inspection, and cluster profile are reproducible
from the Gold commands above. Supporting proof and evidence have been added to [`proof/`](proof/).

AI tools, specifically Codex GPT-5.6, assisted with project setup, pre-commit configuration,
architecture review, source profiling, core SQL, test reviews, edge-case analysis, and
documentation. I manually read through every code output to verify that it aligns with the brief's
requirements. Every generated artefact was reviewed and sanity-checked against the official
BigQuery documentation.

## Repository organisation

All SQL scripts executed in BigQuery are located in [`sql/`](sql/).

All Bash command wrappers are located in [`scripts/`](scripts/).
[`load_bronze.sh`](scripts/load_bronze.sh) validates the source CSV header and loads data into
`retail_bronze.raw_transactions` in the configured Google Cloud project.

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
