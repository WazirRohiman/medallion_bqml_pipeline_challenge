-- Observed metrics describe the loaded snapshot without turning its volume or
-- missing-value rates into permanent data-contract thresholds.
SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT transaction_id) AS distinct_transaction_ids,
    COUNTIF(signup_date = 'NULL') AS signup_literal_null_rows,
    COUNTIF(is_returned = 'NULL') AS returned_literal_null_rows,
    COUNTIF(signup_date IS NULL) AS signup_sql_null_rows,
    COUNTIF(is_returned IS NULL) AS returned_sql_null_rows
FROM retail_bronze.raw_transactions;
