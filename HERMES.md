# mosdns maintenance notes

- For disabled candidate sync, do not create empty `.sync-candidates-disabled-*` marker files.
- If logging disabled candidate-sync state, deduplicate entries via the daily `sync-candidates-YYYY-MM-DD.log` instead.
