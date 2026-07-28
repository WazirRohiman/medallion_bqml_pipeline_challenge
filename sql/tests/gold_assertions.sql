-- Schema checks keep the final reviewer-facing and downstream interface flat.
-- SQLFluff parses BigQuery ML table functions as identifiers.
-- noqa: disable=CP02
ASSERT (
    SELECT
        STRING_AGG(
            FORMAT('%s:%s:%s', column_name, data_type, is_nullable),
            ',' ORDER BY ordinal_position
        )
    -- BigQuery information-schema view names are case-sensitive.
    FROM retail_gold.INFORMATION_SCHEMA.COLUMNS  -- noqa: CP02
    WHERE table_name = 'analytics_customer_segments'
) = CONCAT(
    'transaction_id:STRING:YES,',
    'customer_id:STRING:YES,',
    'signup_date:DATE:YES,',
    'purchase_date:DATE:YES,',
    'amount:NUMERIC:YES,',
    'item_category:STRING:YES,',
    'is_returned:BOOL:YES,',
    'days_to_first_purchase:INT64:YES,',
    'signup_date_was_missing:BOOL:YES,',
    'is_returned_was_missing:BOOL:YES,',
    'cluster_id:INT64:YES'
) AS 'Gold table must have the expected flat ordered schema';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_gold.analytics_customer_segments
    WHERE
        transaction_id IS NULL
        OR customer_id IS NULL
        OR signup_date IS NULL
        OR purchase_date IS NULL
        OR amount IS NULL
        OR item_category IS NULL
        OR is_returned IS NULL
        OR days_to_first_purchase IS NULL
        OR signup_date_was_missing IS NULL
        OR is_returned_was_missing IS NULL
        OR cluster_id IS NULL
) AS 'Gold required fields and cluster assignments must be populated';

ASSERT (
    SELECT COUNT(*)
    FROM retail_gold.analytics_customer_segments
) = (
    SELECT COUNT(*)
    FROM retail_silver.cleaned_transactions
) AS 'Gold row count must equal clean Silver row count';

ASSERT (
    SELECT COUNT(*)
    FROM retail_gold.analytics_customer_segments
) = (
    SELECT COUNT(DISTINCT transaction_id)
    FROM retail_gold.analytics_customer_segments
) AS 'Gold transaction_id must remain unique';

ASSERT NOT EXISTS (
    SELECT transaction_id
    FROM retail_silver.cleaned_transactions
    EXCEPT DISTINCT
    SELECT transaction_id
    FROM retail_gold.analytics_customer_segments
) AS 'Every clean Silver transaction must exist in Gold';

ASSERT NOT EXISTS (
    SELECT transaction_id
    FROM retail_gold.analytics_customer_segments
    EXCEPT DISTINCT
    SELECT transaction_id
    FROM retail_silver.cleaned_transactions
) AS 'Gold cannot introduce transaction identifiers';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_gold.analytics_customer_segments AS gold
    INNER JOIN retail_silver.cleaned_transactions AS silver
        ON gold.transaction_id = silver.transaction_id
    WHERE
        gold.customer_id IS DISTINCT FROM silver.customer_id
        OR gold.signup_date IS DISTINCT FROM silver.signup_date
        OR gold.purchase_date IS DISTINCT FROM silver.purchase_date
        OR gold.amount IS DISTINCT FROM silver.amount
        OR gold.item_category IS DISTINCT FROM silver.item_category
        OR gold.is_returned IS DISTINCT FROM silver.is_returned
        OR gold.days_to_first_purchase IS DISTINCT FROM silver.days_to_first_purchase
        OR gold.signup_date_was_missing
        IS DISTINCT FROM silver.signup_date_was_missing
        OR gold.is_returned_was_missing
        IS DISTINCT FROM silver.is_returned_was_missing
) AS 'Gold must preserve every clean Silver value';

ASSERT (
    SELECT STRING_AGG(input, ',' ORDER BY input)
    FROM
        ML.FEATURE_INFO (
            MODEL retail_gold.customer_segmentation_model
        )
) = 'amount,item_category' AS 'The model must use exactly the two required features';

ASSERT (
    SELECT COUNT(DISTINCT centroid_id)
    FROM
        ML.CENTROIDS (
            MODEL retail_gold.customer_segmentation_model
        )
) = 4 AS 'The model must contain the configured four centroids';

ASSERT NOT EXISTS (
    SELECT cluster_id
    FROM retail_gold.analytics_customer_segments
    EXCEPT DISTINCT
    SELECT centroid_id
    FROM
        ML.CENTROIDS (
            MODEL retail_gold.customer_segmentation_model
        )
) AS 'Every Gold cluster ID must belong to the current model';

ASSERT (
    SELECT COUNT(DISTINCT cluster_id)
    FROM retail_gold.analytics_customer_segments
) = (
    SELECT COUNT(DISTINCT centroid_id)
    FROM
        ML.CENTROIDS (
            MODEL retail_gold.customer_segmentation_model
        )
) AS 'Every trained centroid must be represented in the Gold snapshot';

ASSERT NOT EXISTS (
    SELECT 1
    FROM
        ML.EVALUATE (
            MODEL retail_gold.customer_segmentation_model
        )
    WHERE
        davies_bouldin_index IS NULL
        OR davies_bouldin_index < 0
        OR mean_squared_distance IS NULL
        OR mean_squared_distance < 0
) AS 'K-means evaluation metrics must be populated and non-negative';
