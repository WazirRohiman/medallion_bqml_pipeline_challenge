-- Fail before replacing the model if Silver no longer satisfies the required
-- two-feature training contract.
ASSERT (
    SELECT COUNT(*)
    FROM retail_silver.cleaned_transactions
) >= 4 AS 'K-means training rows must not be fewer than the configured clusters';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.cleaned_transactions
    WHERE
        amount IS NULL
        OR amount <= 0
        OR item_category IS NULL
) AS 'Gold model features must be populated and satisfy the Silver amount rule';

ASSERT (
    SELECT COUNT(*)
    FROM (
        SELECT DISTINCT
            amount,
            item_category
        FROM retail_silver.cleaned_transactions
    ) AS distinct_feature_vectors
) >= 4
AS 'K-means training data must contain at least four distinct feature vectors';

CREATE OR REPLACE MODEL retail_gold.customer_segmentation_model
OPTIONS (
    MODEL_TYPE = 'KMEANS',
    NUM_CLUSTERS = 4,
    STANDARDIZE_FEATURES = TRUE
)
AS
SELECT
    amount,
    item_category
FROM retail_silver.cleaned_transactions;
