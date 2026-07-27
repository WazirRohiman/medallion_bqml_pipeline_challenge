-- Snapshot metrics are evidence, not hard-coded acceptance thresholds.
SELECT
    (SELECT COUNT(*) FROM retail_bronze.raw_transactions) AS bronze_rows,
    (SELECT COUNT(*) FROM retail_silver.cleaned_transactions) AS cleaned_rows,
    (SELECT COUNT(*) FROM retail_silver.rejected_transactions) AS rejected_rows,
    (
        SELECT COUNTIF(signup_date_was_missing)
        FROM retail_silver.cleaned_transactions
    ) AS cleaned_signup_imputations,
    (
        SELECT COUNTIF(is_returned_was_missing)
        FROM retail_silver.cleaned_transactions
    ) AS cleaned_return_imputations;

SELECT
    reason AS rejection_reason,
    COUNT(*) AS rejected_rows
FROM retail_silver.rejected_transactions
CROSS JOIN UNNEST(rejection_reasons) AS reason
GROUP BY reason
ORDER BY rejected_rows DESC, rejection_reason ASC;
