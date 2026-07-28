-- Isolated edge-case checks for the simple Gold model-input predicates.
-- The fixture creates no persistent resources and does not train a model.
CREATE TEMP TABLE fixture (
    amount NUMERIC,
    item_category STRING
);

INSERT INTO fixture
VALUES
(10, 'Home'),
(10, 'Home'),
(10, 'Home'),
(10, 'Home');

ASSERT (
    SELECT COUNT(*)
    FROM fixture
) >= 4 AS 'Fixture must demonstrate that row count alone can pass';

ASSERT (
    SELECT COUNT(*)
    FROM (
        SELECT DISTINCT
            amount,
            item_category
        FROM fixture
    ) AS distinct_feature_vectors
) < 4 AS 'Duplicate rows must not satisfy the distinct-feature-vector guard';

TRUNCATE TABLE fixture;

INSERT INTO fixture
VALUES
(10, 'Home'),
(20, 'Home'),
(10, 'Beauty'),
(20, 'Beauty');

ASSERT (
    SELECT COUNT(*)
    FROM (
        SELECT DISTINCT
            amount,
            item_category
        FROM fixture
    ) AS distinct_feature_vectors
) = 4 AS 'Four distinct model inputs must satisfy the structural guard';

INSERT INTO fixture
VALUES
(NULL, 'Home'),
(0, 'Home'),
(-1, 'Home'),
(10, NULL);

ASSERT (
    SELECT
        COUNTIF(
            amount IS NULL
            OR amount <= 0
            OR item_category IS NULL
        )
    FROM fixture
) = 4 AS 'Every invalid model-input branch must be detected';
