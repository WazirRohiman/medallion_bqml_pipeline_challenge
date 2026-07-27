-- Parse once and retain raw values until each row has been routed. This keeps
-- expected missing markers distinct from malformed non-missing values.
CREATE TEMP TABLE validated_transactions AS
WITH normalized AS (
    SELECT
        transaction_id AS raw_transaction_id,
        customer_id AS raw_customer_id,
        signup_date AS raw_signup_date,
        purchase_date AS raw_purchase_date,
        amount AS raw_amount,
        item_category AS raw_item_category,
        is_returned AS raw_is_returned,
        NULLIF(NULLIF(TRIM(transaction_id), ''), 'NULL') AS transaction_id_text,
        NULLIF(NULLIF(TRIM(customer_id), ''), 'NULL') AS customer_id_text,
        NULLIF(TRIM(signup_date), 'NULL') AS signup_date_text,
        NULLIF(NULLIF(TRIM(purchase_date), ''), 'NULL') AS purchase_date_text,
        NULLIF(NULLIF(TRIM(amount), ''), 'NULL') AS amount_text,
        NULLIF(NULLIF(TRIM(item_category), ''), 'NULL') AS item_category_text,
        NULLIF(TRIM(is_returned), 'NULL') AS is_returned_text
    FROM retail_bronze.raw_transactions
),

typed AS (
    SELECT
        raw_transaction_id,
        raw_customer_id,
        raw_signup_date,
        raw_purchase_date,
        raw_amount,
        raw_item_category,
        raw_is_returned,
        transaction_id_text,
        customer_id_text,
        signup_date_text,
        purchase_date_text,
        amount_text,
        item_category_text,
        is_returned_text,
        SAFE_CAST(signup_date_text AS DATE) AS typed_signup_date,
        SAFE_CAST(purchase_date_text AS DATE) AS typed_purchase_date,
        SAFE_CAST(amount_text AS NUMERIC) AS typed_amount,
        SAFE_CAST(is_returned_text AS BOOL) AS typed_is_returned
    FROM normalized
)

SELECT
    raw_transaction_id,
    raw_customer_id,
    raw_signup_date,
    raw_purchase_date,
    raw_amount,
    raw_item_category,
    raw_is_returned,
    transaction_id_text,
    customer_id_text,
    typed_signup_date,
    typed_purchase_date,
    typed_amount,
    item_category_text,
    typed_is_returned,
    signup_date_text IS NULL AS signup_date_was_missing,
    is_returned_text IS NULL AS is_returned_was_missing,
    ARRAY(
        SELECT reason
        FROM
            UNNEST([
                IF(transaction_id_text IS NULL, 'transaction_id_missing', NULL),
                IF(customer_id_text IS NULL, 'customer_id_missing', NULL),
                IF(purchase_date_text IS NULL, 'purchase_date_missing', NULL),
                IF(
                    purchase_date_text IS NOT NULL
                    AND typed_purchase_date IS NULL,
                    'purchase_date_unparseable',
                    NULL
                ),
                IF(amount_text IS NULL, 'amount_missing', NULL),
                IF(
                    amount_text IS NOT NULL AND typed_amount IS NULL,
                    'amount_unparseable',
                    NULL
                ),
                IF(typed_amount <= 0, 'amount_not_positive', NULL),
                IF(item_category_text IS NULL, 'item_category_missing', NULL),
                IF(
                    signup_date_text IS NOT NULL AND typed_signup_date IS NULL,
                    'signup_date_unparseable',
                    NULL
                ),
                IF(
                    is_returned_text IS NOT NULL
                    AND typed_is_returned IS NULL,
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
FROM typed;

CREATE TEMP TABLE cleaned_output AS
SELECT
    transaction_id_text AS transaction_id,
    customer_id_text AS customer_id,
    COALESCE(typed_signup_date, typed_purchase_date) AS signup_date,
    typed_purchase_date AS purchase_date,
    typed_amount AS amount,
    item_category_text AS item_category,
    COALESCE(typed_is_returned, FALSE) AS is_returned,
    DATE_DIFF(
        typed_purchase_date,
        COALESCE(typed_signup_date, typed_purchase_date),
        DAY
    ) AS days_to_first_purchase,
    signup_date_was_missing,
    is_returned_was_missing
FROM validated_transactions
WHERE ARRAY_LENGTH(rejection_reasons) = 0;

CREATE TEMP TABLE rejected_output AS
SELECT
    raw_transaction_id AS transaction_id,
    raw_customer_id AS customer_id,
    raw_signup_date AS signup_date,
    raw_purchase_date AS purchase_date,
    raw_amount AS amount,
    raw_item_category AS item_category,
    raw_is_returned AS is_returned,
    signup_date_was_missing,
    is_returned_was_missing,
    rejection_reasons
FROM validated_transactions
WHERE ARRAY_LENGTH(rejection_reasons) > 0;

-- Validate the complete split before replacing either persistent output.
ASSERT (
    SELECT COUNT(*)
    FROM validated_transactions
) = (
    SELECT COUNT(*)
    FROM retail_bronze.raw_transactions
) AS 'Silver validation must retain every Bronze row';

ASSERT (
    (SELECT COUNT(*) FROM cleaned_output)
    + (SELECT COUNT(*) FROM rejected_output)
) = (
    SELECT COUNT(*)
    FROM validated_transactions
) AS 'Every validated row must route to exactly one Silver output';

ASSERT NOT EXISTS (
    SELECT 1
    FROM cleaned_output
    WHERE
        transaction_id IS NULL
        OR customer_id IS NULL
        OR signup_date IS NULL
        OR purchase_date IS NULL
        OR amount IS NULL
        OR item_category IS NULL
        OR is_returned IS NULL
        OR days_to_first_purchase IS NULL
) AS 'Clean output must satisfy its required-field contract';

ASSERT NOT EXISTS (
    SELECT 1
    FROM cleaned_output
    WHERE
        amount <= 0
        OR signup_date > purchase_date
        OR days_to_first_purchase != DATE_DIFF(purchase_date, signup_date, DAY)
) AS 'Clean output must satisfy amount and date business rules';

-- Publish rejects first so the mandatory clean table is replaced only after
-- its companion output has succeeded.
CREATE OR REPLACE TABLE retail_silver.rejected_transactions (
    transaction_id STRING OPTIONS (
        description = 'Original Bronze transaction identifier.'
    ),
    customer_id STRING OPTIONS (
        description = 'Original Bronze customer identifier.'
    ),
    signup_date STRING OPTIONS (
        description = 'Original Bronze signup date text.'
    ),
    purchase_date STRING OPTIONS (
        description = 'Original Bronze purchase date text.'
    ),
    amount STRING OPTIONS (
        description = 'Original Bronze amount text.'
    ),
    item_category STRING OPTIONS (
        description = 'Original Bronze item category.'
    ),
    is_returned STRING OPTIONS (
        description = 'Original Bronze return flag text.'
    ),
    signup_date_was_missing BOOL OPTIONS (
        description = 'Whether signup_date used the documented missing representation.'
    ),
    is_returned_was_missing BOOL OPTIONS (
        description = 'Whether is_returned used the documented missing representation.'
    ),
    rejection_reasons ARRAY<STRING> OPTIONS (
        description = 'All validation rules that rejected the transaction.'
    )
)
OPTIONS (
    description = 'Bronze transactions excluded from the clean Silver table, with raw lineage.'
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
    signup_date_was_missing,
    is_returned_was_missing,
    rejection_reasons
FROM rejected_output;

CREATE OR REPLACE TABLE retail_silver.cleaned_transactions (
    transaction_id STRING OPTIONS (
        description = 'Unique transaction identifier at transaction grain.'
    ),
    customer_id STRING OPTIONS (
        description = 'Customer identifier; customers can have multiple transactions.'
    ),
    signup_date DATE OPTIONS (
        description = 'Signup date, defaulted to purchase_date when missing in Bronze.'
    ),
    purchase_date DATE OPTIONS (
        description = 'Transaction purchase date.'
    ),
    amount NUMERIC OPTIONS (
        description = 'Positive transaction amount stored as exact decimal currency.'
    ),
    item_category STRING OPTIONS (
        description = 'Trimmed source item category.'
    ),
    is_returned BOOL OPTIONS (
        description = 'Return flag, defaulted to FALSE when missing in Bronze.'
    ),
    days_to_first_purchase INT64 OPTIONS (
        description = 'Calendar days from the row signup date to its purchase date.'
    ),
    signup_date_was_missing BOOL OPTIONS (
        description = 'Whether signup_date was defaulted from purchase_date.'
    ),
    is_returned_was_missing BOOL OPTIONS (
        description = 'Whether is_returned was defaulted to FALSE.'
    )
)
OPTIONS (
    description = 'Validated retail transactions at one row per transaction.'
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
    is_returned_was_missing
FROM cleaned_output;

DROP TABLE validated_transactions;
DROP TABLE cleaned_output;
DROP TABLE rejected_output;
