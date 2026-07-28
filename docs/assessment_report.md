# Technical Assessment Review: Medallion Pipeline and BQML

**Date:** 2026-07-27

**Reviewed:** the screening brief in Markdown, the supplied PDF metadata, the full initial plan, the
repository state, and an independent byte- and row-level profile of
`raw_transactions_10000.csv`.

For the implementation prerequisites and first milestone, see `start_here.md`.

## Executive verdict

The initial plan is on the right track. Its strongest decisions are the source-faithful Bronze
layer, exact data types in Silver, full-refresh idempotency, explicit grain discussion, native BQML,
BigQuery assertions, Dataform as the production recommendation, and its refusal to add an enterprise
toolchain to a seven-column exercise.

The submission should remain a **small BigQuery ELT pipeline**, not become a data-science project or a
platform build.

The highest-risk issues to fix in the plan are:

1. Build a thin, mandatory end-to-end path before optional engineering additions.
2. Treat the output as transaction-grain clustering despite its customer-oriented name.
3. Preserve the literal text `NULL` in Bronze; distinguish expected missing values from malformed
   values in Silver.
4. Predict against rows carrying `transaction_id`; never join predictions back on the two model
   features.
5. Select the prediction output explicitly so the nested nearest-centroid array does not leak into
   the Gold schema.
6. Set one BigQuery location for all datasets, jobs, and the model.
7. Do not disable numeric standardisation merely because it produces a numerically lower evaluation
   score. That comparison changes the feature space and effectively causes `amount` to drown out
   `item_category`.
8. Do not oversell partitioning, clustering, customer segmentation, or model quality on this tiny,
   synthetic dataset.

The dataset contains engineering conditions that directly exercise the written requirements, but no
evidence of malformed records, unexpected encodings, or complex parsing failures. Most of its
oddities are synthetic-generation artefacts. The assessment is testing whether those artefacts are
handled with correct layer boundaries, types, grain, lineage, rerun behaviour, and honest
documentation.

## What the task is really evaluating

The brief is nominally Bronze → Silver → Gold plus K-means. The likely differentiators are:

- whether raw values remain raw;
- whether transformations are safe and typed;
- whether a rerun duplicates data;
- whether rows are silently lost or multiplied;
- whether the candidate understands the table grain;
- whether the BQML feature and prediction schemas are controlled;
- whether required evidence is reproducible;
- whether the solution is proportionate to a 2.5–3 hour screening task.

Model optimisation is secondary. A large hyperparameter exercise would signal that the candidate
misread a data-engineering challenge as a data-science challenge.

## Independently verified source profile

### File structure

| Check | Result |
|---|---:|
| Data rows | 10,000 |
| Columns | 7 |
| Lines with the wrong field count | 0 |
| Encoding/content | ASCII |
| Line endings | CRLF on all 10,001 lines |
| Embedded quotes/newlines | None |
| Blank fields | 0 |
| Leading/trailing field whitespace | 0 |
| Complete duplicate rows | 0 |
| File ends with newline | Yes |

CRLF is not a BigQuery problem. It only justifies a cheap domain assertion on the last column; it
does not warrant a custom preprocessing step.

### Grain and identifiers

The source grain is **one row per transaction**.

| Check | Result |
|---|---:|
| Distinct `transaction_id` | 10,000 |
| Transaction ID range | `TXN1001`–`TXN11000` |
| Transaction IDs dense | Yes |
| Transaction IDs in ascending numeric order | Yes |
| Distinct customers | 4,861 |
| Customers with more than one row | 2,944 |
| Maximum transactions per customer | 9 |

The ordered, dense transaction IDs are a snapshot property, not a safe production contract. In
particular, lexical ordering is unsuitable as an incremental watermark: `TXN9999` sorts after
`TXN10000`. Treat identifiers as strings and use source ingestion metadata or a real event/update
timestamp for future incremental processing.

### Nulls and invalid amounts

The apparent nulls are the four-character text `NULL`, not empty CSV fields.

| Condition | All Bronze rows | Rows surviving `amount > 0` |
|---|---:|---:|
| `signup_date = 'NULL'` | 823 | 781 |
| `is_returned = 'NULL'` | 1,009 | 974 |
| Both fields are `'NULL'` | 91 | 88 |
| Negative amount | 407 | — |
| Zero amount | 0 | — |

The 407 negative rows include 42 rows with missing signup dates and 35 with missing return flags.
Those missing fields are still useful lineage facts on rejected rows, but they are not additional
rejection reasons because the brief explicitly provides imputation rules for them.

Amounts range from `-149.65` to `1199.88`. After the required `amount > 0` rule:

- Silver contains 9,593 transactions;
- Silver contains 4,789 customers;
- positive-amount quartiles are 311.66, 608.40, and 902.19;
- mean positive amount is approximately 606.22.

The implementation assumption is that non-positive amounts are invalid purchase records because the
brief explicitly instructs us to filter them. We cannot establish from this extract whether a
negative value would represent a refund, correction, or source error in a real system. In the absence
of access to the data provider, preserve the source row in Bronze, route it to rejects with
`amount_not_positive`, and avoid assigning a more specific business meaning. A production discovery
question would confirm how sales, refunds, cancellations, and corrections are represented.

### Dates and the derived field

| Check | Result |
|---|---:|
| Purchase range | 2025-01-01–2026-02-05 |
| Populated signup range | 2024-12-02–2026-02-04 |
| Invalid ISO date strings | 0 |
| Populated signup after purchase | 0 |
| Required post-filter day-gap range | 0–30 |
| Required post-filter median day gap | 14 |

`DATE_DIFF` must be written as:

```sql
DATE_DIFF(purchase_date, signup_date, DAY)
```

BigQuery subtracts the second argument from the first. Reversing them produces negative values and
contradicts the name `days_to_first_purchase`.

The required signup imputation creates a synthetic zero-day spike. In all 10,000 source rows there
are 1,127 zero gaps; 823 of those are created by imputation. In the valid Silver population there are
1,075 zero gaps; 781 are imputed. Keep `signup_date_was_missing` so downstream users can distinguish
observed zero from imputed zero.

February 2026 contains only 137 transactions because the extract stops on 5 February. Do not present
the apparent monthly collapse as a trend.

### Categories and returns

The six categories are broadly balanced:

| Category | Bronze rows | Valid rows | Mean valid amount |
|---|---:|---:|---:|
| Apparel | 1,677 | 1,605 | 610.50 |
| Automotive | 1,695 | 1,614 | 618.21 |
| Beauty | 1,662 | 1,604 | 596.10 |
| Electronics | 1,668 | 1,607 | 605.12 |
| Home | 1,628 | 1,555 | 613.94 |
| Sports | 1,670 | 1,608 | 593.63 |

Among valid rows with a known return flag, 1,872 of 8,619 are returned: **21.72%**. Applying the
required default of `FALSE` changes the reported rate to 1,872 of 9,593: **19.51%**. Keep
`is_returned_was_missing`; if a profile reports return rates, show both the known-value and defaulted
rates.

## Engineering risks and the correct response

### 1. Bronze fidelity can be destroyed at load time

Autodetect or `--null_marker=NULL` can perform Silver work during ingestion. Validate the exact
supplied header before the load, use an explicit seven-column `STRING` schema, skip exactly one
header row, and do not configure `NULL` as the loader's null marker. The preflight prevents a
reordered or renamed header from being accepted silently under explicitly configured positional
loading. The current BigQuery load path does not allow `source_column_match=NAME` together with a
supplied table schema.

Because `bq load` appends by default, the assessment working rule is to use
`--replace`/`WRITE_TRUNCATE` for this one fixed snapshot, with zero tolerated malformed records.
Otherwise a second run duplicates the source rows. This is not the proposed design for an
unspecified live feed: recurring production data would require an agreed append, deduplication,
replay, and late-arrival strategy backed by source metadata.

Bronze assertions should prove:

- seven expected columns;
- transaction IDs are non-null and unique;
- the feed's documented literal-`NULL` convention is preserved;
- non-missing date and numeric text is parseable;
- return values are only `TRUE`, `FALSE`, or `NULL`.

The observed counts—10,000 rows, 823 missing signup markers, and 1,009 missing return markers—belong
in the data profile and execution evidence, not in reusable assertions.

### 2. `SAFE_CAST` can both protect and conceal

Plain casts fail on the expected literal `NULL` strings. `SAFE_CAST` is appropriate, but blindly
coalescing every failed cast converts new corruption into apparently valid imputation.

Normalise expected missing markers first, keep the original values, then distinguish:

- expected missing signup → default to purchase date;
- expected missing return flag → default to false;
- non-null, unparseable date/amount/boolean → reject or fail an assertion.

This makes schema drift and new source corruption visible.

### 3. Silver must be a lossless, disjoint split

For this snapshot the observed reconciliation is:

```text
Bronze 10,000 = cleaned 9,593 + rejected 407
```

Also assert:

- no transaction appears in both outputs;
- each output is unique on `transaction_id`;
- the union of output IDs equals the Bronze ID set.

Counts alone do not detect one dropped row plus one duplicated row.

Use one temporary typed/validated table inside a BigQuery multi-statement script if both Silver
outputs need identical parsing logic. A CTE is scoped to only one statement; copying the casting CTE
into two `CREATE TABLE` statements creates drift risk.

### 4. The requested “customer segment” is not at customer grain

Training uses `amount` and `item_category` from transaction rows. It therefore clusters transaction
behaviour, not customers. The final table should remain one row per transaction to comply with the
brief.

The source reinforces the mismatch:

- 2,681 customers have multiple distinct populated signup dates;
- one customer can have as many as nine distinct signup dates;
- 2,543 valid customers transact in more than one category.

`signup_date` may have been synthetically generated per row and cannot support a trustworthy customer
dimension. `days_to_first_purchase` is also not a true customer-first-purchase metric.

State this explicitly in the Gold table description and README. Do not rename the required asset or
silently aggregate to customer grain. A customer-level model would be a separate future design using
customer-level features and a declared aggregation policy.

This is also a production discovery question for the data provider: confirm the intended customer
grain, whether signup date should be stable per customer, what “first purchase” means, and whether
the requested output is meant to segment customers or individual transactions.

### 5. Joining predictions back can multiply rows

There are 59 duplicated `(amount, item_category)` feature keys among valid rows, covering 119 rows.
A self-join on those model features would turn 9,593 predictions into 9,715 rows—122 unwanted rows.
A join on `customer_id` is worse because that is also non-unique.

Pass the full Silver rows to `ML.PREDICT`. BigQuery requires the model features and permits additional
columns, which are returned with the prediction. Preserve `transaction_id` through prediction and
avoid a join entirely.

### 6. `ML.PREDICT` has a nested output field

For K-means, BigQuery returns:

- `centroid_id`;
- `nearest_centroids_distance`, an `ARRAY<STRUCT>`.

Do not use `SELECT *` to create the proof table. Select every desired Silver column explicitly and
rename `centroid_id` to `cluster_id`. Omit the nested field unless there is a documented use for it.
If distance is retained, extract the element whose centroid ID equals the assigned centroid rather
than assuming array position.

### 7. Feature scaling is easy to reason about incorrectly

BigQuery ML automatically one-hot encodes `item_category`. `STANDARDIZE_FEATURES` affects numerical
features and defaults to `TRUE`.

Set it explicitly to `TRUE`. If it is `FALSE`, raw amounts roughly spanning 0–1,200 dominate binary
category coordinates, so the nominal two-feature model is effectively an amount-banding model.
A lower Davies–Bouldin value from the unstandardised model is not evidence that it is better: the
metric was calculated in a different feature geometry and is not directly comparable.

Because the data may be synthetic and categories have very similar amount distributions, expect limited
business meaning. Choose a small explicit `NUM_CLUSTERS`—four is reasonable for interpretability—and
do not claim the data proves it is statistically optimal. `ML.EVALUATE`, `ML.CENTROIDS`, and
`ML.FEATURE_INFO` are sufficient evidence. A k-sweep is a low-priority data-science detour.

### 8. Model reruns are replaceable but not necessarily identical

`CREATE OR REPLACE MODEL` makes the asset operationally rerunnable. Default random initialisation can
still change centroids and numeric cluster IDs.

For the mandatory submission, document that cluster IDs are model-local identifiers and should not
be treated as stable business codes. BigQuery supports deterministic custom initial centroids, but
we will not introduce the seed-selection policy unless stable model results become a stated
requirement. The assessment priority is operational rerun safety and correct data delivery, not
model-development experimentation.

### 9. BigQuery location is an immutable cross-layer dependency

Create Bronze, Silver, Gold, jobs, and the BQML model in one explicitly selected location. BigQuery
cannot query tables across dataset locations, and a dataset's location cannot later be changed in
place. If Cloud Storage is introduced in production, its location must also be selected with
BigQuery colocation and transfer cost in mind.

### 10. Physical optimisation can become performative

`NUMERIC` for currency, `DATE` for calendar dates, `BOOL` for flags, and `INT64` for day counts are
real optimisations.

Partitioning and clustering a 9,593-row table will not materially improve this workload. Adding them
only to “win points” conflicts with YAGNI and can prompt a reviewer to ask for the measured benefit.
The stronger answer is:

- leave the assessment tables simple;
- document `purchase_date` partitioning and likely `customer_id`/`item_category` clustering as a
  production option once volume and query patterns justify them;
- demonstrate awareness of partition pruning and cost using an example, not a false performance
  claim.

Table and column descriptions are a better low-cost addition because they appear directly in the
required schema proof.

## Review of the proposed architecture

### Keep

- Three exact datasets and required asset names.
- Explicit all-string Bronze schema so the load makes the minimum possible change to the source.
- `NUMERIC` money and typed Silver.
- Missingness lineage flags.
- A rejected-records table retaining the raw values and an array of applicable rejection reasons.
- Full-refresh `CREATE OR REPLACE` processing for a fixed file.
- Explicit model features: only `amount` and `item_category`.
- Transaction-grain required Gold output.
- BigQuery `ASSERT` contract tests plus an inline transformation fixture covering a happy path, a sad
  path, and at least three edge cases.
- Model evaluation and centroid inspection.
- Dataform as the production orchestration recommendation.
- No Airflow, dbt, Docker, Terraform, Python transformation service, or dimensional model. Apply
  YAGNI and prioritise maintainable, readable SQL; comments should explain why a non-obvious decision
  exists rather than narrate what clear SQL already does.
- AI usage disclosure and proof redaction.
- A concise decision-lineage section recording the request or constraint that triggered each major
  implementation decision.

### Change

- Build the complete minimal vertical slice in the first work session.
- Treat invalid non-null casts differently from expected missing markers.
- Separate invariant tests from source-snapshot expectations.
- Add set-equality/anti-overlap checks, not only row-count reconciliation.
- Keep prediction identity through `ML.PREDICT`; do not “join predictions back” on non-key fields.
- Explicitly enable standardisation.
- Describe non-positive amounts as invalid under the assessment rule without inferring their
  real-world semantics.
- Keep the supplied sample in the existing, gitignored `local_data/` directory and use that path
  consistently in local commands.
- Commit `uv.lock` if `uv` is used.

### Defer or remove

- Actual Dataform implementation until mandatory work and proof are complete.
- A customer-level rollup unless everything else is finished.
- A model k-sweep.
- Custom run-log tables.
- Physical partitioning/clustering at this volume.
- Dataplex scans, lineage configuration, dashboards, and alerts.

## Recommended minimal architecture

```text
gitignored local CSV
    |
    | bq load: explicit STRING schema, skip header, WRITE_TRUNCATE
    v
retail_bronze.raw_transactions
    |
    | normalise expected NULL marker
    | SAFE_CAST + explicit validity rules
    +-------------------------------+
    |                               |
    v                               v
retail_silver.cleaned_transactions  retail_silver.rejected_transactions
    |
    | CREATE OR REPLACE MODEL
    | features: amount, item_category
    v
retail_gold.customer_segmentation_model
    |
    | ML.PREDICT with transaction_id retained
    v
retail_gold.analytics_customer_segments
    |
    +--> assertions, ML.EVALUATE, ML.CENTROIDS, proof
```

Use a source checksum in the local runbook or README to identify the assessed snapshot:

```text
SHA-256 1c9fc6932427cb78b3e807dc994e92af0ae8f1578ad4c0f727525d4672481b72
```

Do not add that checksum as a column to the required raw table. If operational metadata is desired,
put it in a separate load manifest.

## Decision lineage

| Triggering request or constraint | Decision | Scope and rationale |
|---|---|---|
| “Load the CSV exactly as it is” and perform cleansing in Silver | Exact header preflight plus an explicit seven-column `STRING` Bronze schema; no autodetect or `NULL` loader marker | Prevents silent column misalignment while preserving layer responsibility and the source's literal `NULL` representation |
| One supplied static CSV and an idempotent pipeline requirement | `WRITE_TRUNCATE` for Bronze and `CREATE OR REPLACE` downstream | Safe for the assessed snapshot; a live feed needs separately agreed ingestion semantics |
| The brief declares non-positive amounts invalid | Route them to rejects with `amount_not_positive` | Implements the stated rule without claiming they are refunds or corrections |
| Missing signup and return values have explicit defaults | Preserve missingness flags and default only expected missing markers | Keeps required output usable without concealing lineage or malformed non-null values |
| The clean-table contract requires a non-negative signup-to-purchase interval | Reject populated signup dates after purchase with `signup_date_after_purchase` | Prevents a misleading negative engineered feature while retaining the original row and reason |
| Clean and rejected outputs require identical parsing decisions | Materialise validation once in a BigQuery temporary table, assert the split, then publish both outputs | Avoids duplicated casting logic without introducing a stored procedure or framework |
| BigQuery transactions do not support permanent table-replacement DDL | Validate both temporary outputs before publication, then replace rejects first and the mandatory clean table last | Reduces partial-publication risk proportionately; transactional dual-table DML is deferred unless it becomes a production requirement |
| The requested model features are transaction columns, while the asset name says customer segments | Keep the required output at transaction grain and document the mismatch | Avoids silently inventing a customer aggregation rule |
| Native BQML is required, while this remains a data-engineering assessment | Use one simple K-means model with explicit features and standardisation; defer custom seeding and k-sweeps | Meets the requirement without turning the submission into model research |
| The proof table should be business-consumable | Select Gold columns explicitly and omit the nested distance array | Prevents a diagnostic repeated record from becoming an accidental public interface |
| The source contains only 10,000 rows | Do not implement partitioning or clustering for performance | No measured benefit; document the production option instead |
| Production orchestration must be discussed | Recommend Dataform but defer its implementation until the mandatory path works | Fits a SQL-first BigQuery pipeline and protects delivery time |

### Review interaction log

This log preserves the human review that refined the plan. The notes are summarized for readability;
they are not presented as unresolved annotations.

| WR review note | Resolution and effect on the design |
|---|---|
| Treat the interpretation of negative amounts as an assumption because the data provider is not available for clarification. | The report now states only that the brief requires non-positive purchases to be treated as invalid. It does not infer refunds or source errors, and records the real-world semantics as a provider discovery question. |
| Make it clear that `WRITE_TRUNCATE` is a working rule for the fixed assessment snapshot, not a universal live-data ingestion pattern. | Full refresh is explicitly scoped to this file. The production note lists append, deduplication, replay, late-arrival, and source-manifest decisions that would be required for a recurring feed. |
| Raise inconsistent customer signup dates and the meaning of “first purchase” with the data provider. | The grain section now records four provider questions and avoids creating a customer dimension or silently aggregating transactions. |
| Do not turn deterministic K-means initialization into a data-science exercise. | The mandatory design uses operational replacement and documents cluster-ID instability. Custom seeds and model experimentation are deferred unless stable results become a stated requirement. |
| Bronze should load the source with minimal-to-no change. | The design uses seven explicit `STRING` columns and avoids autodetect and loader-level conversion of the text `NULL`. |
| A rejected-records table is useful only if it records why each row was rejected. | Rejects retain raw values and an array of all applicable rejection reasons, rather than a single reason with arbitrary precedence. |
| Tests should include a happy path, a sad path, and at least three edge cases. | The temporary fixture now covers every rejection branch, both required imputations, padded missing markers, case-insensitive Boolean casting, multiple simultaneous errors, and genuine same-day purchases. The real transformation and independent assertions are also executed. |
| Apply YAGNI; prioritise maintainability and readability, and write comments that explain why rather than restating how. | Platform additions remain deferred, the small tables are not physically over-designed, and the SQL documentation standard is stated explicitly. |
| Preserve the prompt or review trigger behind decisions that materially affect development. | This decision-lineage table and interaction log connect each important constraint or review note to its implementation consequence. |
| Continue using the gitignored `local_data/` directory for the supplied sample. | All local load examples now use `./local_data/raw_transactions_10000.csv`; no second raw-data convention is introduced. |
| Keep the source checksum outside the required raw table. | The checksum remains an execution-manifest/runbook value and does not alter Bronze. |
| Prefer native job metadata to a hand-built logging framework. | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` remains the proposed source for job duration, bytes, slot usage, and failures. |
| Verify whether datasets inherit a project location and provide official documentation. | The engineering companion explains that a project has no BigQuery dataset region to inherit, that an unspecified/default-less location resolves to `US`, and that dataset location is immutable. It links the official dataset and location documentation. |
| Explain model rerun behavior with a concrete example and official documentation. | The engineering companion distinguishes operational replacement from deterministic assignments, shows a transaction changing numeric cluster ID between retrains, explains why cluster IDs are not durable keys, and links the K-means initialization documentation. |
| The typed DDL and the numeric filter-order observation are approved. | Both remain in the engineering guidance; fixed snapshot counts were removed from column descriptions and reusable tests. |
| Use common data-engineering incidents as working instincts without turning the assessment into an enterprise platform. | Bronze now fails fast on an unexpected header or malformed record, names every load behavior explicitly, and proves replacement by rerunning the fixed snapshot. No incremental framework, staging layer, or physical optimisation was added. |
| Bronze review requested stronger required-field and load-command contracts without hardcoding a cloud project in SQL. | Literal `NULL` is rejected from every field where the source contract does not document it, positional matching is explicit, and the fake CLI test compares the complete ordered command. Portable `dataset.table` SQL remains bound centrally by the project-scoped runner. |
| Silver implementation was approved only after checking its names, organisation, and transformations against the brief. | The required `sql/silver/silver_transform.sql` creates `retail_silver.cleaned_transactions`; rejected-row lineage, missingness flags, assertions, and temporary fixtures remain additive controls. |
| Gold must remain a data-engineering deliverable rather than become a model-tuning exercise. | The implementation uses exactly `amount` and `item_category`, four explicit clusters, standardised numeric features, a transaction-grain flat prediction table, executable model/table contracts, and read-only interpretation queries. No hyperparameter sweep, customer aggregate, or additional persistent profile table was added. |
| Gold review identified degenerate training input, prediction-time drift, and orchestration-gate risks. | Training now requires four distinct feature vectors as a structural—not statistical-quality—guard. Prediction revalidates features and uses one temporary Silver snapshot for prediction and exact pre-publication comparison. The Dataform recommendation now requires assertion actions to be explicit dependencies rather than implying ordinary table dependencies provide a gate. |

## Testing strategy

### Invariants

Bronze:

- expected names and string types;
- transaction ID populated and unique;
- source-domain checks for dates, amount text, category, and return flag;
- expected literal-null handling.

Silver:

- required fields non-null;
- correct Silver data types;
- `amount > 0`;
- `signup_date <= purchase_date`;
- `days_to_first_purchase >= 0`;
- missingness flags agree with the source;
- cleaned/rejected outputs are disjoint and losslessly cover Bronze.

Gold:

- Gold row count and transaction ID set equal Silver;
- `cluster_id` non-null;
- final grain remains one row per transaction;
- model input schema is exactly the two required features.

### Observed snapshot metrics

Record these in the data profile and proof output, not as hard-coded reusable assertions:

- Bronze rows: 10,000;
- Silver rows: 9,593;
- rejected rows: 407;
- Gold rows: 9,593;
- source literal-null counts: 823 and 1,009;
- post-filter imputation-flag counts: 781 and 974.

These values certify and describe the supplied snapshot. The invariant tests above should continue
to work when a valid future input has different volumes or missing-value rates.

### Transformation examples

Use an inline fixture to exercise:

- happy path: a fully valid transaction;
- sad path: a malformed non-null amount;
- edge case: literal `NULL` signup is imputed and flagged;
- edge case: literal `NULL` return is defaulted and flagged;
- edge case: zero amount is rejected;
- edge case: multiple invalid fields produce one rejected row with multiple reasons;
- edge case: a genuine same-day signup and purchase produces zero days without an imputation flag.
- edge case: every missing required field produces its specific rejection reason;
- edge case: padded documented missing markers follow the same normalization as production;
- edge case: mixed-case Boolean text accepted by BigQuery remains valid;
- edge case: blank optional fields are rejected because they are not the documented missing marker.

## Technology choices with highest value

### Highest value

1. **BigQuery multi-statement GoogleSQL and temporary tables** for a DRY Silver script with shared
   typed validation logic.
2. **Native BigQuery assertions** for executable data contracts.
3. **BQML inspection functions**: `ML.EVALUATE`, `ML.CENTROIDS`, and `ML.FEATURE_INFO`.
4. **Dataform in the production design**, because it provides SQL dependencies, assertions,
   documentation, scheduling, and run logs in the Google Cloud/BigQuery ecosystem. Downstream
   actions must explicitly depend on assertion actions; table dependencies alone do not create
   assertion gates.
5. **`INFORMATION_SCHEMA.JOBS_BY_PROJECT`** as an operational evidence query for duration, bytes
   processed, slot milliseconds, and failures instead of a custom logging framework.
6. **Table and column descriptions plus labels** for discoverability, ownership, and cost attribution.
7. **Pre-commit + SQLFluff BigQuery dialect + secret/large-file checks**, with the same checks in a
   credential-free GitHub Actions workflow.

### Mention in the production paragraph, do not build

- Cloud Storage as a governed landing zone;
- Cloud Scheduler/Workflows or a Dataform workflow configuration depending on the chosen trigger;
- Dataplex data quality scans and BigQuery lineage for a larger governed estate;
- least-privilege service accounts and separate dev/prod projects or datasets;
- budget alerts and per-query maximum-bytes-billed guardrails.

Budget alerts notify; they do not stop spend. BQML model creation has its own on-demand pricing, so
record actual bytes/cost from the executed jobs instead of claiming the run was free.

### Low value or actively distracting here

- Composer/Airflow;
- dbt alongside Dataform;
- Dataflow for seven columns;
- Vertex AI for a native BQML requirement;
- Terraform for a one-off screening project;
- Docker or a Python package;
- a star schema built from unstable synthetic customer attributes;
- an elaborate CI deployment with long-lived GCP credentials.

## Delivery plan for twelve available hours

### Session 1: produce a compliant vertical slice

1. Create one GCP project/location and the three datasets.
2. Load Bronze with the explicit schema and overwrite behaviour.
3. Implement only the mandatory Silver transformations.
4. Train the basic explicit four-cluster model.
5. Create the required Gold table with explicit prediction columns.
6. Run evaluation and capture provisional proof.

At this point there is a complete submission even if later time is lost.

### Session 2: engineering hardening

1. Add rejects and missingness flags.
2. Add invariant assertions and snapshot evidence queries.
3. Add descriptions, model inspection, and cluster profile.
4. Rerun twice and verify counts, key sets, and replacement behaviour.
5. Add local linting only after the SQL executes successfully in BigQuery.

### Session 3: reviewer experience

1. Write concise architecture, decisions, orchestration, data-quality, and AI-usage notes.
2. Capture final schema/table preview and evaluation proof.
3. Redact project numbers, account identity, billing information, and unrelated resources.
4. Verify required filenames and public-repository links.
5. Review the repository from a clean clone/runbook perspective.

## Public repository and confidentiality

The current `.gitignore` excludes `local_data/*` and `instructions/*`, which correctly keeps the CSV,
PDF, Markdown copy of the brief, and initial private notes out of the public repository. Do not
assume redistribution permission merely because the repository must be public.

Also exclude:

- service-account JSON keys and application credentials;
- `.env` files;
- console screenshots containing account email, project number, billing details, or unrelated
  resources.

The public README should disclose how AI helped with planning, profiling, SQL review, tests, and
documentation, and should say that every generated artefact was reviewed and executed by the
candidate.

## Final priority order

### Must ship

1. Exact Bronze, Silver, Gold datasets and required names.
2. Exact three requested SQL filenames.
3. Source-faithful Bronze ingestion instructions/schema.
4. Correct typed Silver rules.
5. Native K-means training and prediction.
6. Transaction-grain Gold table with a cluster ID.
7. Required proof screenshots/metrics.
8. Reproducible run order.
9. AI usage notes.

### Strong differentiators

1. Rejected-row lineage and imputation flags.
2. Invariant assertions plus clearly separated snapshot evidence.
3. Explicit location and rerun controls.
4. Explicit prediction schema and preserved transaction identity.
5. Model centroid/feature interpretation without overstating quality.
6. Table/column descriptions.
7. Concise Dataform production design.
8. Clean, credential-free repository quality checks.

### Only if time remains

1. `INFORMATION_SCHEMA` operational report.
2. A customer-level design note, not a misleading customer table.
3. Dataplex/lineage discussion.

## Official references

- [BigQuery batch loading and overwrite behaviour](https://docs.cloud.google.com/bigquery/docs/batch-loading-data)
- [BigQuery locations and same-location query requirement](https://docs.cloud.google.com/bigquery/docs/datasets-intro)
- [BigQuery multi-statement queries and temporary tables](https://docs.cloud.google.com/bigquery/docs/multi-statement-queries)
- [BigQuery `ASSERT`](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/debugging-statements)
- [BQML automatic preprocessing](https://docs.cloud.google.com/bigquery/docs/auto-preprocessing)
- [BQML K-means `CREATE MODEL` options](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create-kmeans)
- [BQML `ML.PREDICT` output](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-predict)
- [BQML model evaluation](https://docs.cloud.google.com/bigquery/docs/evaluate-overview)
- [Google Cloud workload orchestration choices](https://docs.cloud.google.com/bigquery/docs/orchestrate-workloads)
- [Dataform overview](https://docs.cloud.google.com/dataform/docs/overview)
- [BigQuery cost controls](https://docs.cloud.google.com/bigquery/docs/best-practices-costs)
- [BigQuery pricing](https://cloud.google.com/bigquery/pricing)
