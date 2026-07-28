-- Required model-quality evidence. Lower values indicate tighter, more
-- separated clusters, but do not by themselves establish business usefulness.
-- SQLFluff parses BigQuery ML table functions as identifiers.
-- noqa: disable=CP02
SELECT
    davies_bouldin_index,
    mean_squared_distance
FROM
    ML.EVALUATE (
        MODEL retail_gold.customer_segmentation_model
    );

-- Prove that training used exactly the two features required by the brief.
SELECT
    input,
    min,
    max,
    mean,
    median,
    stddev,
    category_count,
    null_count
FROM
    ML.FEATURE_INFO (
        MODEL retail_gold.customer_segmentation_model
    )
ORDER BY input;

-- Return centroids in the original feature scale for interpretation.
SELECT
    centroid_id,
    feature,
    numerical_value,
    categorical_value
FROM
    ML.CENTROIDS(
        MODEL retail_gold.customer_segmentation_model,
        STRUCT(FALSE AS standardize)
    )
ORDER BY centroid_id, feature;
