-- The command wrapper supplies the project and job location. BigQuery creates
-- each dataset in that location, keeping all pipeline layers colocated.
CREATE SCHEMA IF NOT EXISTS retail_bronze;

CREATE SCHEMA IF NOT EXISTS retail_silver;

CREATE SCHEMA IF NOT EXISTS retail_gold;
