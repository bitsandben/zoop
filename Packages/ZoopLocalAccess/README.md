# ZoopLocalAccess

`zoop-local-access` exposes bounded, read-only NOOP health data locally. It has no network or
write/control path.

Use MCP over stdio with `zoop-local-access mcp`, or query one tool directly as JSON:

```sh
zoop-local-access query health_snapshot --days 14
zoop-local-access query metric_series --key hrv --days 90
zoop-local-access query data_freshness
zoop-local-access query sleep_summary --days 30
zoop-local-access query workout_summary --days 90
```

Set `NOOP_DB_PATH` to select a database, or pass `--db-path PATH`. Query results are written to
stdout; diagnostics are written to stderr. Query usage errors exit 64 and runtime/database errors
exit 1.

Arguments reuse the MCP defaults and bounds:

- `health_snapshot`: optional `--days` (default 14, clamped to 1...120).
- `metric_series`: required `--key`; optional `--source` (default `my-whoop`), `--days` (default 90,
  clamped to 1...4000), `--from-day`, `--to-day`, and `--limit` (default 500, clamped to 1...2000).
- `data_freshness`: no tool arguments.
- `sleep_summary`: optional `--days` (default 30, clamped to 1...4000).
- `workout_summary`: optional `--days` (default 90, clamped to 1...4000).

Dates use the existing `YYYY-MM-DD` tool contract. The CLI does not add a separate validation or
interpretation layer; it passes accepted arguments to the same bounded read-only dispatcher as MCP.
