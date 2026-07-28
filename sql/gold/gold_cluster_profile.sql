-- Read-only business profile of each model-local cluster.
SELECT
    cluster_id,
    COUNT(*) AS transaction_count,
    COUNT(DISTINCT customer_id) AS customer_count,
    ROUND(AVG(amount), 2) AS average_amount,
    APPROX_QUANTILES(amount, 100)[OFFSET(50)] AS median_amount,
    SAFE_DIVIDE(COUNTIF(is_returned), COUNT(*)) AS return_rate_after_defaulting,
    SAFE_DIVIDE(
        COUNTIF(is_returned AND NOT is_returned_was_missing),
        COUNTIF(NOT is_returned_was_missing)
    ) AS return_rate_when_known
FROM retail_gold.analytics_customer_segments
GROUP BY cluster_id
ORDER BY cluster_id;

-- Category mix prevents numeric cluster IDs from being presented as unsupported
-- business labels.
SELECT
    cluster_id,
    item_category,
    COUNT(*) AS transaction_count,
    SAFE_DIVIDE(
        COUNT(*),
        SUM(COUNT(*)) OVER (PARTITION BY cluster_id)
    ) AS share_of_cluster
FROM retail_gold.analytics_customer_segments
GROUP BY cluster_id, item_category
ORDER BY cluster_id ASC, transaction_count DESC, item_category ASC;
