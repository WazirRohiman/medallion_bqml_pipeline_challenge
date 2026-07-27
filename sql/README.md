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
The current pipeline phase adds only Bronze assertions and snapshot profiling; transformations
remain scoped to later Silver and Gold phases.
