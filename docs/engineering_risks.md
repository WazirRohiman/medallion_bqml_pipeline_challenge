# Worked Examples: Engineering Risks and Controls

This document complements `assessment_report.md`. It explains the important implementation choices
in data-engineering terms and uses real source rows where possible. Hypothetical malformed rows are
labelled clearly. The `Review interaction log` in `assessment_report.md` preserves the WR feedback
that led to these revisions and records how each note changed the design.

## Reference rows

| ID | Transaction | Signup text | Purchase text | Amount text | Category | Returned text | Purpose |
|---|---|---|---|---|---|---|---|
| A | `TXN1001` | `2025-09-11` | `2025-09-14` | `1039.19` | Beauty | `TRUE` | Fully valid row |
| B | `TXN1013` | `NULL` | `2025-08-18` | `134.45` | Apparel | `FALSE` | Expected missing signup marker |
| C | `TXN1006` | `2025-04-10` | `2025-05-04` | `747.17` | Sports | `NULL` | Expected missing return marker |
| D | `TXN1068` | `2025-04-21` | `2025-04-23` | `-123.65` | Apparel | `NULL` | Invalid amount and an expected missing return marker |
| E | `TXN1199` | `NULL` | `2025-06-29` | `-79.51` | Electronics | `FALSE` | Invalid amount and an expected missing signup marker |
| F | `TXN1018` | `2025-10-09` | `2025-11-08` | `827.98` | Sports | `NULL` | Maximum observed 30-day gap |

Every source field is a `STRING` in Bronze, including the four-character text `NULL`.

## 1. `DATE_DIFF` argument order

BigQuery's `DATE_DIFF(a, b, DAY)` calculates `a - b`. The business meaning of
`days_to_first_purchase` therefore requires:

```sql
DATE_DIFF(purchase_date, signup_date, DAY) AS days_to_first_purchase
```

Concrete examples:

```sql
-- Row A: 14 September minus 11 September
SELECT DATE_DIFF(DATE '2025-09-14', DATE '2025-09-11', DAY); -- 3

-- Reversing the arguments contradicts the column's meaning.
SELECT DATE_DIFF(DATE '2025-09-11', DATE '2025-09-14', DAY); -- -3
```

After the required signup imputation, row B uses its purchase date as its signup date and produces
zero days.

The reusable assertion tests the rule, not this snapshot's exact distribution:

```sql
ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_silver.cleaned_transactions
  WHERE days_to_first_purchase < 0
) AS 'days_to_first_purchase must be non-negative';
```

## 2. Preserve the source representation in Bronze

### Why autodetect is unsuitable here

The brief asks for the CSV to be loaded as supplied and for type conversion to occur in Silver.
Autodetect can infer `DATE`, `FLOAT64`, and `BOOL`, while a configured `--null_marker=NULL` converts
the literal text `NULL` to a SQL null. Either choice moves cleansing into Bronze.

Use an explicit schema:

```json
[
  {"name": "transaction_id", "type": "STRING", "mode": "NULLABLE"},
  {"name": "customer_id", "type": "STRING", "mode": "NULLABLE"},
  {"name": "signup_date", "type": "STRING", "mode": "NULLABLE"},
  {"name": "purchase_date", "type": "STRING", "mode": "NULLABLE"},
  {"name": "amount", "type": "STRING", "mode": "NULLABLE"},
  {"name": "item_category", "type": "STRING", "mode": "NULLABLE"},
  {"name": "is_returned", "type": "STRING", "mode": "NULLABLE"}
]
```

For this fixed assessment snapshot, overwrite the destination:

```bash
bq load \
  --location=africa-south1 \
  --source_format=CSV \
  --skip_leading_rows=1 \
  --source_column_match=POSITION \
  --max_bad_records=0 \
  --replace \
  "${PROJECT_ID}:retail_bronze.raw_transactions" \
  ./local_data/raw_transactions_10000.csv \
  ./schemas/raw_transactions.json
```

Do not set `--autodetect` or `--null_marker=NULL`.

The load wrapper checks that the source header exactly matches the seven committed schema fields
before invoking BigQuery. This makes a reordered, renamed, or unexpected header visible instead of
silently loading values into the wrong string columns. The current BigQuery load path rejects
`--source_column_match=NAME` when a table schema is supplied, so the compatible design combines this
preflight with explicitly configured positional loading. `--max_bad_records=0` makes the documented
default explicit: one malformed record fails the load.

### Reusable assertions versus snapshot evidence

Hard-coding 823 or 1,009 into the core tests would make them fail when a valid future file has a
different missing-value rate. The reusable tests should validate the source contract:

```sql
-- The source contract for this feed uses literal 'NULL', not actual SQL nulls.
ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_bronze.raw_transactions
  WHERE signup_date IS NULL OR is_returned IS NULL
) AS 'Bronze must preserve the source literal NULL convention';

-- Every non-missing signup value must be a valid date.
ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_bronze.raw_transactions
  WHERE signup_date != 'NULL'
    AND SAFE_CAST(signup_date AS DATE) IS NULL
) AS 'Non-missing signup_date values must be parseable dates';

-- The return field may contain only the documented source values.
ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_bronze.raw_transactions
  WHERE is_returned NOT IN ('TRUE', 'FALSE', 'NULL')
) AS 'is_returned contains an undocumented source value';
```

These assertions allow the number of literal `NULL` values to change. The figures 823 and 1,009
belong in a data profile or snapshot evidence query:

```sql
SELECT
  COUNTIF(signup_date = 'NULL') AS signup_missing_rows,
  COUNTIF(is_returned = 'NULL') AS returned_missing_rows
FROM retail_bronze.raw_transactions;
```

For the supplied snapshot, that query returns 823 and 1,009. It informs the reviewer without turning
those counts into permanent production rules.

There is one unavoidable contract decision: if a future producer starts sending genuine empty CSV
fields, the “no SQL nulls” assertion will fail. That is desirable until the new missing-value
convention is agreed and implemented deliberately.

## 3. What `SAFE_CAST` protects—and what it can conceal

`CAST` fails the whole query when a value cannot be converted:

```sql
SELECT CAST('NULL' AS DATE);       -- query error
SELECT CAST('2025-02-31' AS DATE); -- query error
```

`SAFE_CAST` keeps the pipeline running by returning a SQL null:

```sql
SELECT SAFE_CAST('2025-08-18' AS DATE); -- 2025-08-18
SELECT SAFE_CAST('NULL' AS DATE);       -- NULL
SELECT SAFE_CAST('2025-02-31' AS DATE); -- NULL
```

The important nuance is that the last two inputs now have the same typed result:

| Raw value | Meaning | `SAFE_CAST(... AS DATE)` |
|---|---|---|
| `NULL` | Expected missing marker | SQL `NULL` |
| `2025-02-31` | Unexpected corrupt date | SQL `NULL` |

If the transformation immediately runs `COALESCE(typed_signup_date, purchase_date)`, it silently
treats the corrupt date as ordinary missing data. That is the cost of `SAFE_CAST`: availability
improves, but failure information is lost unless the raw value is retained and tested.

The “tripwire” is a zero-tolerance assertion for **unexpected** cast failures:

```sql
ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_bronze.raw_transactions
  WHERE signup_date != 'NULL'
    AND SAFE_CAST(signup_date AS DATE) IS NULL
) AS 'signup_date contains a non-missing value that cannot be parsed';

ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_bronze.raw_transactions
  WHERE amount IS NULL
     OR SAFE_CAST(amount AS NUMERIC) IS NULL
) AS 'amount must be present and parseable as NUMERIC';
```

This does not depend on knowing how many missing signup dates exist:

- `NULL` is allowed by the signup-date source contract and later imputed.
- `2025-02-31` is not allowed and fails the assertion.
- Any missing or non-numeric amount fails because the brief provides no amount-imputation rule.

In operational terms, `SAFE_CAST` converts a transformation outage into a data-quality event. The
pipeline must still detect, count, and route that event.

Official reference:

- [BigQuery conversion functions and `SAFE_CAST`](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/conversion_functions#safe_casting)

## 4. Cast once, validate once, then route

The Silver process should retain raw text long enough to distinguish missing values from malformed
values. The following is a concrete version of the CTE pattern:

```sql
WITH normalized AS (
  SELECT
    transaction_id,
    customer_id,
    signup_date AS raw_signup_date,
    purchase_date AS raw_purchase_date,
    amount AS raw_amount,
    item_category,
    is_returned AS raw_is_returned,
    NULLIF(TRIM(signup_date), 'NULL') AS signup_date_text,
    NULLIF(TRIM(purchase_date), 'NULL') AS purchase_date_text,
    NULLIF(TRIM(amount), 'NULL') AS amount_text,
    NULLIF(TRIM(is_returned), 'NULL') AS is_returned_text
  FROM retail_bronze.raw_transactions
),
typed AS (
  SELECT
    *,
    SAFE_CAST(signup_date_text AS DATE) AS typed_signup_date,
    SAFE_CAST(purchase_date_text AS DATE) AS typed_purchase_date,
    SAFE_CAST(amount_text AS NUMERIC) AS typed_amount,
    SAFE_CAST(is_returned_text AS BOOL) AS typed_is_returned
  FROM normalized
),
validated AS (
  SELECT
    *,
    ARRAY(
      SELECT reason
      FROM UNNEST([
        IF(amount_text IS NULL, 'amount_missing', NULL),
        IF(amount_text IS NOT NULL AND typed_amount IS NULL, 'amount_unparseable', NULL),
        IF(typed_amount <= 0, 'amount_not_positive', NULL),
        IF(purchase_date_text IS NULL, 'purchase_date_missing', NULL),
        IF(
          purchase_date_text IS NOT NULL AND typed_purchase_date IS NULL,
          'purchase_date_unparseable',
          NULL
        ),
        IF(
          signup_date_text IS NOT NULL AND typed_signup_date IS NULL,
          'signup_date_unparseable',
          NULL
        ),
        IF(
          is_returned_text IS NOT NULL AND typed_is_returned IS NULL,
          'is_returned_unparseable',
          NULL
        ),
        IF(
          typed_signup_date > typed_purchase_date,
          'signup_date_after_purchase',
          NULL
        )
      ]) AS reason WITH OFFSET AS reason_offset
      WHERE reason IS NOT NULL
      ORDER BY reason_offset
    ) AS rejection_reasons
  FROM typed
)
SELECT *
FROM validated;
```

What each stage does:

1. `normalized` preserves the original strings and converts only the documented text marker `NULL`
   into a SQL null in separate working columns.
2. `typed` performs every conversion exactly once.
3. `validated` compares the original meaning with the cast result and builds zero, one, or several
   rejection reasons.
4. Clean rows have `ARRAY_LENGTH(rejection_reasons) = 0`.
5. Rejected rows have `ARRAY_LENGTH(rejection_reasons) > 0`.

Example outcomes:

| Example | Relevant raw input | Typed result | Rejection reasons | Route |
|---|---|---|---|---|
| Real row A | amount `1039.19` | `NUMERIC 1039.19` | `[]` | Clean |
| Real row B | signup `NULL` | SQL `NULL` | `[]` | Clean; signup is imputed |
| Real row D | amount `-123.65`, returned `NULL` | negative amount, SQL-null return | `[amount_not_positive]` | Reject |
| Hypothetical | amount `one hundred` | SQL `NULL` | `[amount_unparseable]` | Reject |
| Hypothetical | purchase `2025-02-31` | SQL `NULL` | `[purchase_date_unparseable]` | Reject |
| Hypothetical | amount `0.00`, purchase `bad-date` | zero, SQL `NULL` | `[amount_not_positive, purchase_date_unparseable]` | Reject |

Expected missing signup and return markers are not rejection reasons because the brief explicitly
defines their defaults. Their missingness flags should still be preserved on clean and rejected
records.

After routing, the clean projection applies the required defaults:

```sql
SELECT
  transaction_id,
  customer_id,
  COALESCE(typed_signup_date, typed_purchase_date) AS signup_date,
  typed_purchase_date AS purchase_date,
  typed_amount AS amount,
  item_category,
  COALESCE(typed_is_returned, FALSE) AS is_returned,
  DATE_DIFF(
    typed_purchase_date,
    COALESCE(typed_signup_date, typed_purchase_date),
    DAY
  ) AS days_to_first_purchase,
  signup_date_text IS NULL AS signup_date_was_missing,
  is_returned_text IS NULL AS is_returned_was_missing
FROM validated
WHERE ARRAY_LENGTH(rejection_reasons) = 0;
```

A temporary table in a multi-statement Silver script can materialize `validated` once and feed both
the clean and rejected tables. A CTE alone is scoped to one SQL statement.

BigQuery does not allow DDL that creates or replaces permanent tables inside a multi-statement
transaction. The assessment script therefore builds both temporary outputs and runs its routing and
business-rule assertions before replacing either permanent table. It publishes rejects first and
the mandatory clean table last. Each replacement is atomic on its own, but the pair is not one
transaction. A production requirement for atomic dual-table publication would justify pre-created
schemas plus transactional `TRUNCATE`/`INSERT` DML; that extra lifecycle is not warranted for this
fixed assessment snapshot.

Official reference:

- [BigQuery multi-statement transaction limitations](https://docs.cloud.google.com/bigquery/docs/transactions)

Losslessness requires more than a row-count equation:

```sql
ASSERT (
  (SELECT COUNT(*) FROM retail_silver.cleaned_transactions)
  + (SELECT COUNT(*) FROM retail_silver.rejected_transactions)
  = (SELECT COUNT(*) FROM retail_bronze.raw_transactions)
) AS 'Clean and rejected row counts must cover Bronze';

ASSERT NOT EXISTS (
  SELECT transaction_id
  FROM retail_silver.cleaned_transactions
  INTERSECT DISTINCT
  SELECT transaction_id
  FROM retail_silver.rejected_transactions
) AS 'A transaction cannot be both clean and rejected';
```

Also test transaction-ID uniqueness in each output. Counts alone cannot detect one lost row combined
with one duplicated row.

## 5. Type choices

| Column | Bronze | Silver | Reason |
|---|---|---|---|
| `transaction_id` | `STRING` | `STRING` | Identifier, not a quantity |
| `customer_id` | `STRING` | `STRING` | Identifier, not a quantity |
| `signup_date` | `STRING` | `DATE` | No time or timezone component |
| `purchase_date` | `STRING` | `DATE` | No time or timezone component |
| `amount` | `STRING` | `NUMERIC` | Exact base-10 currency arithmetic |
| `item_category` | `STRING` | `STRING` | Categorical business value |
| `is_returned` | `STRING` | `BOOL` | Two-state value after imputation |
| `days_to_first_purchase` | — | `INT64` | Whole calendar days |

For money, the practical distinction is:

```sql
SELECT CAST(0.1 AS FLOAT64) + CAST(0.2 AS FLOAT64) = CAST(0.3 AS FLOAT64); -- FALSE
SELECT CAST(0.1 AS NUMERIC) + CAST(0.2 AS NUMERIC) = CAST(0.3 AS NUMERIC); -- TRUE
```

Table and column descriptions should explain business meaning and non-obvious decisions. Comments in
SQL should primarily explain **why**, such as why literal `NULL` is preserved or why the output is
transaction-grain.

The assessment tables are too small for partitioning or clustering to provide a measured benefit.
Those physical designs can be documented as production options once volume and query patterns
justify them.

## 6. `ML.PREDICT` in data-engineering terms

### What K-means produces

K-means creates a configured number of representative points called **centroids**. With four
clusters, think of the model as maintaining four prototypes. For each input transaction, BigQuery:

1. converts the required features into the representation used by the model;
2. measures the transaction's distance from each centroid;
3. assigns the transaction to the nearest centroid.

The assigned cluster is not a probability or a business label. `centroid_id = 2` only means “nearest
to centroid 2 in this trained model.” It does not inherently mean “high value” or “loyal customer.”

### Why the prediction result contains an array

For K-means, `ML.PREDICT` returns:

- `centroid_id`: the one assigned cluster;
- `nearest_centroids_distance`: up to five candidate centroids and their distances.

With four clusters, one transaction might conceptually produce:

```text
transaction_id: TXN1001
centroid_id: 2
nearest_centroids_distance: [
  {centroid_id: 2, distance: 0.42},
  {centroid_id: 4, distance: 0.90},
  {centroid_id: 1, distance: 1.31},
  {centroid_id: 3, distance: 1.72}
]
```

`ARRAY<STRUCT<centroid_id INT64, distance FLOAT64>>` is BigQuery's way of storing a one-to-many child
collection inside one parent row:

- `ARRAY` means repeated child elements;
- `STRUCT` means each child has named fields;
- relationally, it resembles a child `prediction_distances` table keyed by transaction and centroid.

The nested representation is useful for model inspection, but most BI consumers need only the
assigned cluster. Keeping it accidentally through `SELECT *` produces a repeated `RECORD` column:

```sql
-- Valid SQL, but unnecessarily exposes the nested diagnostic output.
CREATE OR REPLACE TABLE retail_gold.analytics_customer_segments AS
SELECT *
FROM ML.PREDICT(
  MODEL retail_gold.customer_segmentation_model,
  TABLE retail_silver.cleaned_transactions
);
```

### Recommended Gold projection

Keep the required Gold output flat and explicit:

```sql
CREATE OR REPLACE TABLE retail_gold.analytics_customer_segments
OPTIONS (
  description = 'Clean transactions enriched with a BQML K-means assignment; transaction grain.'
)
AS
SELECT
  transaction_id,
  customer_id,
  signup_date,
  purchase_date,
  amount,
  item_category,
  is_returned,
  days_to_first_purchase,
  signup_date_was_missing,
  is_returned_was_missing,
  centroid_id AS cluster_id
FROM ML.PREDICT(
  MODEL retail_gold.customer_segmentation_model,
  TABLE retail_silver.cleaned_transactions
);
```

If an assigned-centroid distance is genuinely useful, flatten only the matching child:

```sql
WITH predictions AS (
  SELECT *
  FROM ML.PREDICT(
    MODEL retail_gold.customer_segmentation_model,
    TABLE retail_silver.cleaned_transactions
  )
)
SELECT
  * EXCEPT (centroid_id, nearest_centroids_distance),
  centroid_id AS cluster_id,
  (
    SELECT distance
    FROM UNNEST(nearest_centroids_distance)
    WHERE centroid_id = predictions.centroid_id
  ) AS distance_to_assigned_centroid
FROM predictions;
```

This is safer than assuming `[OFFSET(0)]` is the assigned centroid. Distances are measured in the
model's feature space. With `STANDARDIZE_FEATURES=TRUE`, a value such as `0.42` is not 42 cents or
42%; it is a relative geometric distance across the transformed amount and category features. A
smaller value means the row is closer to its assigned prototype, but it is not a confidence
probability.

### Gold assertions

```sql
ASSERT (
  SELECT COUNT(*)
  FROM retail_gold.analytics_customer_segments
) = (
  SELECT COUNT(*)
  FROM retail_silver.cleaned_transactions
) AS 'Gold must not drop or duplicate Silver rows';

ASSERT NOT EXISTS (
  SELECT 1
  FROM retail_gold.analytics_customer_segments
  WHERE cluster_id IS NULL
) AS 'Every clean transaction must receive a cluster';

ASSERT NOT EXISTS (
  SELECT transaction_id
  FROM retail_silver.cleaned_transactions
  EXCEPT DISTINCT
  SELECT transaction_id
  FROM retail_gold.analytics_customer_segments
) AS 'Every Silver transaction must exist in Gold';
```

Also test the reverse `EXCEPT DISTINCT` direction or assert Gold transaction-ID uniqueness.

Official reference:

- [BigQuery `ML.PREDICT` output for K-means](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-predict)

## 7. Filter only after numeric conversion

Bronze `amount` is a string. Comparing it with another string is lexicographical, not numeric:

```sql
-- Incorrect business logic.
WHERE amount <= '0'
```

This snapshot happens not to expose every failure mode:

| Raw text | String comparison `<= '0'` | Numeric comparison `<= 0` |
|---|---:|---:|
| `-123.65` | TRUE | TRUE |
| `1039.19` | FALSE | FALSE |
| `0.00` | FALSE | TRUE |
| `+3.00` | TRUE | FALSE |

Cast once, then validate `typed_amount <= 0`. The typed CTE in section 4 ensures the clean and reject
paths cannot implement different numeric rules.

## 8. Rerun behaviour and dataset location

### Fixed snapshot versus recurring production feed

`bq load` defaults to append. For this one supplied snapshot, the working rule is:

```text
Bronze load              WRITE_TRUNCATE / --replace
Silver and Gold tables   CREATE OR REPLACE TABLE
BQML model               CREATE OR REPLACE MODEL
```

This is an explicit scope assumption, not a general Bronze design. A recurring production feed might
instead use:

- an append-only Bronze table;
- source-file name, checksum, and ingestion timestamp in a load manifest;
- deduplication on a trusted business key;
- `MERGE` or partition replacement in downstream layers;
- late-arrival and replay rules.

Those rules require source-system service levels and change semantics that the assessment does not
provide.

### Dataset location

A Google Cloud project does not have one regional location that BigQuery datasets automatically
inherit. Location is a dataset property selected when the dataset is created. If no location or
applicable default is specified, BigQuery uses the `US` multi-region. Dataset location cannot be
changed in place, and all tables referenced by one query must be in the same location.

Pin the chosen location for every dataset:

```bash
PROJECT_ID='replace-with-project-id'
LOCATION='africa-south1'

for dataset in retail_bronze retail_silver retail_gold; do
  bq --location="${LOCATION}" mk --dataset \
    --description="Retail ${dataset#retail_} layer" \
    "${PROJECT_ID}:${dataset}"
done
```

Johannesburg currently supports BigQuery built-in model training, including K-means. The location
decision and its verification are recorded here because they affect every table, query job, and
model.

Official references:

- [Introduction to BigQuery datasets and location behaviour](https://docs.cloud.google.com/bigquery/docs/datasets-intro)
- [BigQuery and BigQuery ML supported locations](https://docs.cloud.google.com/bigquery/docs/locations)

### Model replacement versus stable cluster IDs

There are two different meanings of reproducibility:

1. **Operational rerun safety:** rerunning the pipeline replaces the model and Gold table without
   duplicate assets or rows.
2. **Model-result determinism:** the same transaction receives the same numeric cluster ID after
   every retraining.

`CREATE OR REPLACE MODEL` provides the first. It does not guarantee the second because the default
K-means initialisation is random. For example:

```text
Training run 1: transaction TXN1001 -> cluster_id 2
Training run 2: transaction TXN1001 -> cluster_id 4
```

That may be only an ID permutation—run 2's centroid 4 might represent the same prototype as run 1's
centroid 2—or the fitted groups may differ slightly. Numeric cluster IDs must therefore not be used
as durable business keys.

BigQuery supports deterministic custom initial centroids through
`KMEANS_INIT_METHOD='CUSTOM'` and `KMEANS_INIT_COL`. We are deliberately not adding that mechanism to
the mandatory implementation because:

- this is a data-engineering assessment, not a model-development exercise;
- selecting defensible seed rows introduces additional modelling policy;
- operational rerun safety and honest documentation satisfy the immediate requirement.

If stable model results become a real requirement, the seed-selection rule, model version, feature
schema, training snapshot, and acceptance tolerances must all be governed together.

Official reference:

- [BigQuery K-means model options and custom initialisation](https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/bigqueryml-syntax-create-kmeans)

### Rerun assertions without fixed snapshot counts

The core tests express relationships:

```sql
ASSERT (
  SELECT COUNT(*)
  FROM retail_bronze.raw_transactions
) = (
  SELECT COUNT(DISTINCT transaction_id)
  FROM retail_bronze.raw_transactions
) AS 'Bronze transaction IDs must be unique';

ASSERT (
  (SELECT COUNT(*) FROM retail_silver.cleaned_transactions)
  + (SELECT COUNT(*) FROM retail_silver.rejected_transactions)
  = (SELECT COUNT(*) FROM retail_bronze.raw_transactions)
) AS 'Silver routing must account for every Bronze row';

ASSERT (
  SELECT COUNT(*)
  FROM retail_gold.analytics_customer_segments
) = (
  SELECT COUNT(*)
  FROM retail_silver.cleaned_transactions
) AS 'Gold row count must equal clean Silver row count';
```

For this assessment, a before/after rerun evidence query may display 10,000, 9,593, 407, and 9,593.
Those are observed snapshot metrics, not embedded expectations in the reusable tests.

## 9. Suggested test cases

Use a small inline fixture or dedicated test CTE to exercise transformation behaviour independently
of the supplied file.

The standalone fixture intentionally mirrors the row-level validation expressions rather than
introducing a persistent helper routine solely for tests. That duplication is a known maintenance
trade-off. A reusable routine would expand the deployment contract, while BigQuery table functions
with table parameters are still a Pre-GA feature. For this assessment, the proportionate controls
are to keep the fixture beside the production SQL, cover every validation branch, and also execute
the real transformation followed by the independent post-publication assertions. A production
Dataform implementation could centralise the shared SQL dependency without adding a warehouse
routine.

Official references:

- [BigQuery user-defined functions](https://docs.cloud.google.com/bigquery/docs/user-defined-functions)
- [BigQuery table functions](https://docs.cloud.google.com/bigquery/docs/table-functions)

### Happy path

- Valid dates, positive amount, valid category, and `TRUE`/`FALSE`.
- Expected result: clean row with correct types and day difference.

### Sad path

- Non-null malformed amount such as `one hundred`.
- Expected result: rejected with `amount_unparseable`.

### Edge cases

At least these cases are valuable:

1. Literal `NULL` signup → clean, signup defaults to purchase date, missingness flag is true, gap is
   zero.
2. Literal `NULL` return → clean, return defaults to false, missingness flag is true.
3. Amount exactly `0.00` → rejected as `amount_not_positive`.
4. Negative amount → rejected as `amount_not_positive`.
5. Multiple invalid fields → one rejected row carrying every applicable reason.
6. Signup equal to purchase date → clean with a legitimate zero-day gap and missingness flag false.
7. Padded documented `NULL` markers → treated consistently with the transformation's trimming.
8. Mixed-case `true`/`false` → accepted because BigQuery's Boolean cast is case-insensitive.
9. Missing required identifiers, purchase date, amount, or category → rejected with a specific
   reason.
10. Blank optional fields → rejected as unparseable because blank text is not the documented
    missing marker.

The distinction in case 6 proves why the missingness flag matters: an observed zero and an imputed
zero have the same derived value but different lineage.
