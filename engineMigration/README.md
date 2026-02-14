# Engine Migration Naming

Use Flyway-style versioned directories:

- `engineMigration/VYYYYMMDDHHMMSS__short_description/`

Inside each migration directory, store ordered artifacts:

- `001_engine_patch.diff`
- `002_model_report.json`
- `003_training_report.json`

Notes:

- Timestamp should be UTC and represent when the migration bundle was generated.
- Keep numbering stable so diffs/reviews are predictable.
- Add new migration bundles; do not overwrite older ones.
