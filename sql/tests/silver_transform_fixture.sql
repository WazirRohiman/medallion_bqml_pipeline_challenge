-- This isolated contract fixture mirrors Silver validation to exercise branches
-- absent from the supplied snapshot. It creates no persistent resources.
CREATE TEMP TABLE fixture (
    transaction_id STRING,
    customer_id STRING,
    signup_date STRING,
    purchase_date STRING,
    amount STRING,
    item_category STRING,
    is_returned STRING
);

INSERT INTO fixture
VALUES
('TXN_HAPPY', 'CUST1', '2026-01-01', '2026-01-05', '10.00', 'Home', 'TRUE'),
('TXN_SIGNUP_MISSING', 'CUST2', 'NULL', '2026-01-05', '20.00', 'Home', 'FALSE'),
('TXN_RETURN_MISSING', 'CUST3', '2026-01-01', '2026-01-05', '30.00', 'Home', 'NULL'),
('TXN_SAME_DAY', 'CUST4', '2026-01-05', '2026-01-05', '40.00', 'Home', 'FALSE'),
('TXN_BAD_AMOUNT', 'CUST5', '2026-01-01', '2026-01-05', 'many', 'Home', 'FALSE'),
('TXN_ZERO', 'CUST6', '2026-01-01', '2026-01-05', '0.00', 'Home', 'FALSE'),
('TXN_NEGATIVE', 'CUST7', '2026-01-01', '2026-01-05', '-1.00', 'Home', 'FALSE'),
('TXN_MULTI', 'CUST8', '2026-01-01', 'bad-date', '0.00', 'Home', 'FALSE'),
('TXN_DATE_ORDER', 'CUST9', '2026-01-06', '2026-01-05', '50.00', 'Home', 'FALSE'),
('TXN_BAD_BOOL', 'CUST10', '2026-01-01', '2026-01-05', '60.00', 'Home', 'maybe'),
('TXN_NO_CATEGORY', 'CUST11', '2026-01-01', '2026-01-05', '70.00', 'NULL', 'FALSE'),
(NULL, 'CUST12', '2026-01-01', '2026-01-05', '80.00', 'Home', 'FALSE'),
('TXN_NO_CUSTOMER', '  ', '2026-01-01', '2026-01-05', '90.00', 'Home', 'FALSE'),
('TXN_NO_PURCHASE', 'CUST14', '2026-01-01', '  ', '100.00', 'Home', 'FALSE'),
('TXN_NO_AMOUNT', 'CUST15', '2026-01-01', '2026-01-05', '', 'Home', 'FALSE'),
('TXN_BAD_SIGNUP', 'CUST16', 'bad-date', '2026-01-05', '110.00', 'Home', 'FALSE'),
('TXN_PADDED_NULLS', 'CUST17', ' NULL ', '2026-01-05', '120.00', 'Home', ' NULL '),
('TXN_MIXED_BOOL', 'CUST18', '2026-01-01', '2026-01-05', '130.00', 'Home', 'False'),
('TXN_EMPTY_SIGNUP', 'CUST19', ' ', '2026-01-05', '140.00', 'Home', 'FALSE'),
('TXN_EMPTY_BOOL', 'CUST20', '2026-01-01', '2026-01-05', '150.00', 'Home', '');

CREATE TEMP TABLE fixture_results AS
WITH normalized AS (
    SELECT
        transaction_id,
        NULLIF(NULLIF(TRIM(transaction_id), ''), 'NULL') AS transaction_id_text,
        NULLIF(NULLIF(TRIM(customer_id), ''), 'NULL') AS customer_id_text,
        NULLIF(TRIM(signup_date), 'NULL') AS signup_date_text,
        NULLIF(NULLIF(TRIM(purchase_date), ''), 'NULL') AS purchase_date_text,
        NULLIF(NULLIF(TRIM(amount), ''), 'NULL') AS amount_text,
        NULLIF(NULLIF(TRIM(item_category), ''), 'NULL') AS item_category_text,
        NULLIF(TRIM(is_returned), 'NULL') AS is_returned_text
    FROM fixture
),

typed AS (
    SELECT
        transaction_id,
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
    transaction_id,
    COALESCE(typed_signup_date, typed_purchase_date) AS clean_signup_date,
    typed_purchase_date,
    COALESCE(typed_is_returned, FALSE) AS clean_is_returned,
    DATE_DIFF(
        typed_purchase_date,
        COALESCE(typed_signup_date, typed_purchase_date),
        DAY
    ) AS days_to_first_purchase,
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

ASSERT (
    SELECT COUNTIF(ARRAY_LENGTH(rejection_reasons) = 0)
    FROM fixture_results
) = 6 AS 'Fixture must route six valid rows to the clean path';

ASSERT (
    SELECT AS STRUCT
        clean_signup_date,
        days_to_first_purchase,
        signup_date_was_missing
    FROM fixture_results
    WHERE transaction_id = 'TXN_SIGNUP_MISSING'
) = STRUCT(DATE '2026-01-05', 0, TRUE)
AS 'Missing signup must default to purchase date and retain lineage';

ASSERT (
    SELECT AS STRUCT
        clean_is_returned,
        is_returned_was_missing
    FROM fixture_results
    WHERE transaction_id = 'TXN_RETURN_MISSING'
) = STRUCT(FALSE, TRUE)
AS 'Missing return flag must default to FALSE and retain lineage';

ASSERT (
    SELECT AS STRUCT
        days_to_first_purchase,
        signup_date_was_missing
    FROM fixture_results
    WHERE transaction_id = 'TXN_SAME_DAY'
) = STRUCT(0, FALSE)
AS 'Observed same-day activity must not be marked as imputed';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_BAD_AMOUNT'
) = 'amount_unparseable' AS 'Malformed amount must be rejected explicitly';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_ZERO'
) = 'amount_not_positive' AS 'Zero amount must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_NEGATIVE'
) = 'amount_not_positive' AS 'Negative amount must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_MULTI'
) = 'purchase_date_unparseable,amount_not_positive'
AS 'One rejected row must retain all applicable reasons';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_DATE_ORDER'
) = 'signup_date_after_purchase' AS 'Signup after purchase must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_BAD_BOOL'
) = 'is_returned_unparseable' AS 'Unexpected return text must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_NO_CATEGORY'
) = 'item_category_missing' AS 'Missing item category must be rejected';

ASSERT (
    SELECT
        COUNTIF(
            transaction_id IS NULL
            AND ARRAY_TO_STRING(rejection_reasons, ',') = 'transaction_id_missing'
        )
    FROM fixture_results
) = 1 AS 'Missing transaction identifier must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_NO_CUSTOMER'
) = 'customer_id_missing' AS 'Blank customer identifier must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_NO_PURCHASE'
) = 'purchase_date_missing' AS 'Blank purchase date must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_NO_AMOUNT'
) = 'amount_missing' AS 'Blank amount must be rejected';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_BAD_SIGNUP'
) = 'signup_date_unparseable' AS 'Malformed signup date must be rejected';

ASSERT (
    SELECT AS STRUCT
        clean_signup_date,
        clean_is_returned,
        signup_date_was_missing,
        is_returned_was_missing
    FROM fixture_results
    WHERE transaction_id = 'TXN_PADDED_NULLS'
) = STRUCT(DATE '2026-01-05', FALSE, TRUE, TRUE)
AS 'Padded documented NULL markers must be trimmed before imputation';

ASSERT (
    SELECT AS STRUCT
        clean_is_returned,
        ARRAY_LENGTH(rejection_reasons) AS rejection_reason_count
    FROM fixture_results
    WHERE transaction_id = 'TXN_MIXED_BOOL'
) = STRUCT(FALSE, 0)
AS 'Any Boolean text accepted by SAFE_CAST must remain valid';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_EMPTY_SIGNUP'
) = 'signup_date_unparseable'
AS 'Blank signup date is not the documented missing marker';

ASSERT (
    SELECT ARRAY_TO_STRING(rejection_reasons, ',')
    FROM fixture_results
    WHERE transaction_id = 'TXN_EMPTY_BOOL'
) = 'is_returned_unparseable'
AS 'Blank return flag is not the documented missing marker';

DROP TABLE fixture;
DROP TABLE fixture_results;
