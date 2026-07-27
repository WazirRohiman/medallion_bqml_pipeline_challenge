# SQL

BigQuery GoogleSQL will be organised by pipeline responsibility:

```text
setup/
bronze/
silver/
gold/
tests/
```

`setup/create_datasets.sql` creates the three required empty datasets in the wrapper-owned location.
Bronze contains source-contract assertions and snapshot profiling. Silver contains the mandatory
typed transformation, rejected-row lineage, reusable assertions, an edge-case fixture, and snapshot
profiling. Gold remains scoped to its later implementation phase.
