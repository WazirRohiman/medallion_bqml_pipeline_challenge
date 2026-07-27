-- These checks express the reusable source contract. Snapshot-specific counts
-- are reported by bronze_profile.sql and are not permanent acceptance rules.
ASSERT (
    SELECT
        STRING_AGG(
            FORMAT('%s:%s:%s', column_name, data_type, is_nullable),
            ',' ORDER BY ordinal_position
        )
    -- BigQuery information-schema view names are case-sensitive.
    FROM retail_bronze.INFORMATION_SCHEMA.COLUMNS  -- noqa: CP02
    WHERE table_name = 'raw_transactions'
) = CONCAT(
    'transaction_id:STRING:YES,',
    'customer_id:STRING:YES,',
    'signup_date:STRING:YES,',
    'purchase_date:STRING:YES,',
    'amount:STRING:YES,',
    'item_category:STRING:YES,',
    'is_returned:STRING:YES'
) AS 'Bronze must have the expected seven nullable STRING columns in source order';

ASSERT (
    SELECT
        COUNTIF(
            transaction_id IS NULL
            OR customer_id IS NULL
            OR signup_date IS NULL
            OR purchase_date IS NULL
            OR amount IS NULL
            OR item_category IS NULL
            OR is_returned IS NULL
        )
    FROM retail_bronze.raw_transactions
) = 0 AS 'Bronze must preserve the feed convention of populated text or literal NULL';

ASSERT (
    SELECT
        COUNTIF(
            transaction_id = 'NULL'
            OR customer_id = 'NULL'
            OR purchase_date = 'NULL'
            OR amount = 'NULL'
            OR item_category = 'NULL'
        )
    FROM retail_bronze.raw_transactions
) = 0 AS 'Literal NULL is allowed only in signup_date and is_returned';

ASSERT (
    SELECT
        COUNTIF(
            TRIM(transaction_id) = ''
            OR TRIM(customer_id) = ''
            OR TRIM(item_category) = ''
        )
    FROM retail_bronze.raw_transactions
) = 0 AS 'Bronze identifiers and item categories must not be blank';

ASSERT (
    SELECT COUNT(*)
    FROM retail_bronze.raw_transactions
) = (
    SELECT COUNT(DISTINCT transaction_id)
    FROM retail_bronze.raw_transactions
) AS 'Bronze transaction_id must be unique';

ASSERT (
    SELECT
        COUNTIF(
            signup_date != 'NULL'
            AND SAFE_CAST(signup_date AS DATE) IS NULL
        )
    FROM retail_bronze.raw_transactions
) = 0 AS 'Non-missing signup_date values must be parseable dates';

ASSERT (
    SELECT COUNTIF(SAFE_CAST(purchase_date AS DATE) IS NULL)
    FROM retail_bronze.raw_transactions
) = 0 AS 'purchase_date must be fully parseable as DATE';

ASSERT (
    SELECT COUNTIF(SAFE_CAST(amount AS NUMERIC) IS NULL)
    FROM retail_bronze.raw_transactions
) = 0 AS 'amount must be fully parseable as NUMERIC';

ASSERT (
    SELECT COUNTIF(is_returned NOT IN ('TRUE', 'FALSE', 'NULL'))
    FROM retail_bronze.raw_transactions
) = 0 AS 'is_returned must use the documented source values';
