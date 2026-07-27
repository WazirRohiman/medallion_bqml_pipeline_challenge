# Schemas

This directory contains committed BigQuery schema definitions.

`raw_transactions.json` defines the seven nullable `STRING` columns used to preserve the supplied
CSV representation in Bronze. Missing markers remain the literal text `NULL`; type conversion and
imputation belong to Silver.
