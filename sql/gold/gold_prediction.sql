-- Pass the complete transaction through ML.PREDICT so transaction_id remains
-- attached to its prediction without a non-unique feature join.
-- Materialize Silver once so prediction and validation use one immutable script
-- snapshot even if the persistent Silver table is replaced concurrently.
-- SQLFluff parses MODEL and TABLE in this BigQuery ML call as identifiers.
-- noqa: disable=CP02
CREATE TEMP TABLE prediction_source AS
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
    is_returned_was_missing
FROM retail_silver.cleaned_transactions;

-- BQML imputes missing model inputs instead of necessarily failing. Keep that
-- behavior from concealing a Silver contract regression between training and
-- prediction.
ASSERT NOT EXISTS (
    SELECT 1
    FROM prediction_source
    WHERE
        amount IS NULL
        OR amount <= 0
        OR item_category IS NULL
) AS 'Gold prediction features must satisfy the Silver model-input contract';

CREATE TEMP TABLE predicted_transactions AS
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
    TABLE prediction_source
);

-- Validates the complete prediction result before replacing the persistent table.
ASSERT (
    SELECT COUNT(*)
    FROM predicted_transactions
) = (
    SELECT COUNT(*)
    FROM prediction_source
) AS 'Gold prediction must retain every clean Silver transaction';

ASSERT NOT EXISTS (
    SELECT 1
    FROM predicted_transactions
    WHERE
        transaction_id IS NULL
        OR cluster_id IS NULL
) AS 'Every predicted transaction must retain its identifier and receive a cluster';

ASSERT (
    SELECT COUNT(*)
    FROM predicted_transactions
) = (
    SELECT COUNT(DISTINCT transaction_id)
    FROM predicted_transactions
) AS 'Gold prediction must remain unique at transaction grain';

ASSERT NOT EXISTS (
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
        is_returned_was_missing
    FROM prediction_source
    EXCEPT DISTINCT
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
        is_returned_was_missing
    FROM predicted_transactions
) AND NOT EXISTS (
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
        is_returned_was_missing
    FROM predicted_transactions
    EXCEPT DISTINCT
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
        is_returned_was_missing
    FROM prediction_source
) AS 'Gold prediction must preserve the exact Silver snapshot values';

CREATE OR REPLACE TABLE retail_gold.analytics_customer_segments (
    transaction_id STRING OPTIONS (
        description = 'Unique transaction identifier retained from clean Silver.'
    ),
    customer_id STRING OPTIONS (
        description = 'Customer identifier; customers can have multiple transaction clusters.'
    ),
    signup_date DATE OPTIONS (
        description = 'Signup date after the required Silver defaulting rule.'
    ),
    purchase_date DATE OPTIONS (
        description = 'Transaction purchase date.'
    ),
    amount NUMERIC OPTIONS (
        description = 'Positive transaction amount used as a model feature.'
    ),
    item_category STRING OPTIONS (
        description = 'Transaction category used as a model feature.'
    ),
    is_returned BOOL OPTIONS (
        description = 'Return flag after the required Silver defaulting rule.'
    ),
    days_to_first_purchase INT64 OPTIONS (
        description = 'Calendar days from the row signup date to its purchase date.'
    ),
    signup_date_was_missing BOOL OPTIONS (
        description = 'Whether Silver defaulted signup_date from purchase_date.'
    ),
    is_returned_was_missing BOOL OPTIONS (
        description = 'Whether Silver defaulted is_returned to FALSE.'
    ),
    cluster_id INT64 OPTIONS (
        description = 'Model-local K-means centroid ID; not a stable business identifier.'
    )
)
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
    cluster_id
FROM predicted_transactions;

DROP TABLE predicted_transactions;
DROP TABLE prediction_source;
