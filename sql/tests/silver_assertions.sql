-- Schema checks protect the table interface expected by Gold and reviewers.
ASSERT (
    SELECT
        STRING_AGG(
            FORMAT('%s:%s:%s', column_name, data_type, is_nullable),
            ',' ORDER BY ordinal_position
        )
    -- BigQuery information-schema view names are case-sensitive.
    FROM retail_silver.INFORMATION_SCHEMA.COLUMNS  -- noqa: CP02
    WHERE table_name = 'cleaned_transactions'
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
    'is_returned_was_missing:BOOL:YES'
) AS 'Clean Silver table must have the expected ordered schema';

ASSERT (
    SELECT
        STRING_AGG(
            FORMAT('%s:%s:%s', column_name, data_type, is_nullable),
            ',' ORDER BY ordinal_position
        )
    -- BigQuery information-schema view names are case-sensitive.
    FROM retail_silver.INFORMATION_SCHEMA.COLUMNS  -- noqa: CP02
    WHERE table_name = 'rejected_transactions'
) = CONCAT(
    'transaction_id:STRING:YES,',
    'customer_id:STRING:YES,',
    'signup_date:STRING:YES,',
    'purchase_date:STRING:YES,',
    'amount:STRING:YES,',
    'item_category:STRING:YES,',
    'is_returned:STRING:YES,',
    'signup_date_was_missing:BOOL:YES,',
    'is_returned_was_missing:BOOL:YES,',
    'rejection_reasons:ARRAY<STRING>:NO'
) AS 'Rejected Silver table must preserve raw columns and rejection lineage';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.cleaned_transactions
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
) AS 'Clean Silver required fields must be populated';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.cleaned_transactions
    WHERE
        amount <= 0
        OR signup_date > purchase_date
        OR days_to_first_purchase < 0
        OR days_to_first_purchase != DATE_DIFF(purchase_date, signup_date, DAY)
) AS 'Clean Silver rows must satisfy amount and date rules';

ASSERT (
    SELECT COUNT(*)
    FROM retail_silver.cleaned_transactions
) = (
    SELECT COUNT(DISTINCT transaction_id)
    FROM retail_silver.cleaned_transactions
) AS 'Clean Silver transaction_id must be unique';

ASSERT (
    SELECT COUNTIF(transaction_id IS NOT NULL)
    FROM retail_silver.rejected_transactions
) = (
    SELECT COUNT(DISTINCT transaction_id)
    FROM retail_silver.rejected_transactions
) AS 'Non-missing rejected Silver transaction_id values must be unique';

ASSERT (
    (SELECT COUNT(*) FROM retail_silver.cleaned_transactions)
    + (SELECT COUNT(*) FROM retail_silver.rejected_transactions)
) = (
    SELECT COUNT(*)
    FROM retail_bronze.raw_transactions
) AS 'Clean and rejected Silver rows must reconcile to Bronze';

ASSERT NOT EXISTS (
    SELECT transaction_id
    FROM retail_silver.cleaned_transactions
    INTERSECT DISTINCT
    SELECT transaction_id
    FROM retail_silver.rejected_transactions
) AS 'A transaction cannot exist in both Silver outputs';

ASSERT NOT EXISTS (
    SELECT transaction_id
    FROM retail_bronze.raw_transactions
    EXCEPT DISTINCT
    (
        SELECT transaction_id
        FROM retail_silver.cleaned_transactions
        UNION DISTINCT
        SELECT transaction_id
        FROM retail_silver.rejected_transactions
    )
) AS 'Every Bronze transaction must exist in one Silver output';

ASSERT NOT EXISTS (
    (
        SELECT transaction_id
        FROM retail_silver.cleaned_transactions
        UNION DISTINCT
        SELECT transaction_id
        FROM retail_silver.rejected_transactions
    )
    EXCEPT DISTINCT
    SELECT transaction_id
    FROM retail_bronze.raw_transactions
) AS 'Silver outputs cannot introduce transaction identifiers';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.rejected_transactions
    WHERE
        ARRAY_LENGTH(rejection_reasons) = 0
        OR EXISTS (
            SELECT 1
            FROM UNNEST(rejection_reasons) AS reason
            WHERE reason IS NULL
        )
) AS 'Every rejected row must contain non-null rejection reasons';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.cleaned_transactions AS silver
    INNER JOIN retail_bronze.raw_transactions AS bronze
        ON
            silver.transaction_id
            = NULLIF(NULLIF(TRIM(bronze.transaction_id), ''), 'NULL')
    WHERE
        silver.customer_id IS DISTINCT FROM TRIM(bronze.customer_id)
        OR silver.item_category IS DISTINCT FROM TRIM(bronze.item_category)
        OR silver.signup_date_was_missing IS DISTINCT FROM (
            NULLIF(TRIM(bronze.signup_date), 'NULL') IS NULL
        )
        OR silver.is_returned_was_missing IS DISTINCT FROM (
            NULLIF(TRIM(bronze.is_returned), 'NULL') IS NULL
        )
        OR silver.signup_date IS DISTINCT FROM COALESCE(
            SAFE_CAST(NULLIF(TRIM(bronze.signup_date), 'NULL') AS DATE),
            SAFE_CAST(
                NULLIF(NULLIF(TRIM(bronze.purchase_date), ''), 'NULL') AS DATE
            )
        )
        OR silver.purchase_date IS DISTINCT FROM SAFE_CAST(
            NULLIF(NULLIF(TRIM(bronze.purchase_date), ''), 'NULL') AS DATE
        )
        OR silver.amount IS DISTINCT FROM SAFE_CAST(
            NULLIF(NULLIF(TRIM(bronze.amount), ''), 'NULL') AS NUMERIC
        )
        OR silver.is_returned IS DISTINCT FROM COALESCE(
            SAFE_CAST(NULLIF(TRIM(bronze.is_returned), 'NULL') AS BOOL),
            FALSE
        )
) AS 'Clean Silver values and missingness flags must agree with Bronze lineage';

ASSERT NOT EXISTS (
    SELECT 1
    FROM retail_silver.rejected_transactions AS silver
    INNER JOIN retail_bronze.raw_transactions AS bronze
        ON silver.transaction_id = bronze.transaction_id
    WHERE
        silver.customer_id IS DISTINCT FROM bronze.customer_id
        OR silver.signup_date IS DISTINCT FROM bronze.signup_date
        OR silver.purchase_date IS DISTINCT FROM bronze.purchase_date
        OR silver.amount IS DISTINCT FROM bronze.amount
        OR silver.item_category IS DISTINCT FROM bronze.item_category
        OR silver.is_returned IS DISTINCT FROM bronze.is_returned
        OR silver.signup_date_was_missing IS DISTINCT FROM (
            NULLIF(TRIM(bronze.signup_date), 'NULL') IS NULL
        )
        OR silver.is_returned_was_missing IS DISTINCT FROM (
            NULLIF(TRIM(bronze.is_returned), 'NULL') IS NULL
        )
) AS 'Rejected Silver rows must preserve original Bronze values';
