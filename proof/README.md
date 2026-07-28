# Proof of Execution

The same metrics, feature contract, and centroids can be reproduced with:

```bash
./scripts/run_sql.sh sql/gold/gold_model_evaluation.sql
```

[`model_evaluation.csv`](model_evaluation.csv) records the final executed metrics as supporting
evidence. Refresh it after any later model replacement. The required primary evidence remains the
console screenshot because retraining can produce different centroids and evaluation values.

Screenshots must not expose account email addresses, billing information, project numbers, or
unrelated cloud resources.
