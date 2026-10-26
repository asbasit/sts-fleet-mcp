# sts-fleet data contract (schema 1)

Everything lives under one Dropbox folder, `FLEET_DIR` (default `Dropbox\ClaudeHub\fleet`).

```
fleet/
  status/<login>.json     one per MT5 account, rewritten every heartbeat by STS_Heartbeat.mq5
  deals/<login>.json      last N days of deals, rewritten when history changes (or hourly)
  events/<machine>.jsonl  append-only log from watchdogs and scripts, one file per machine
  firm_rules.json         firm limits, STS buffer, and the account tags (challenge / funded); untagged = test
  setup/                  per-machine setup logs and pre-filled tag commands
```

One writer per file. Accounts are unique across the fleet and each machine owns its own
events file, so Dropbox never has two machines fighting over the same file.

## status/<login>.json

| field | meaning |
|---|---|
| `schema` | always 1 for this version |
| `state` | `running`, or `stopped_*` written by OnDeinit (`stopped_terminal_closed`, `stopped_removed`, ...) |
| `heartbeat_utc` | ISO UTC time of this write. The server marks the account STALE when it's older than `stale_after_sec` |
| `machine` | from the EA input, e.g. `VPS8` |
| `firm` | broker hint detected from the server name (FTMO, BlueGuardian...). Not used to decide prop status: that comes only from tags in firm_rules.json |
| `terminal.connected` | broker connection up |
| `terminal.algo_trading_enabled` | the Algo Trading button |
| `terminal.account_allows_experts` | broker permits EAs on this account |
| `account.balance / equity / margin` | account currency |
| `account.trade_mode` | `demo`, `contest` or `real` as the broker reports it (prop challenges usually show `demo`) |
| `day.start_balance / start_equity` | captured at the first heartbeat of the broker-server day |
| `day.captured_utc` | when that capture happened. If it's well after server midnight, the EA was attached mid-day and the daily figure is approximate |
| `initial_balance` | challenge starting balance (EA input, or first balance seen) |
| `peak_equity` | highest equity seen, for trailing-drawdown firms |
| `positions.count / floating_pl / items[]` | open positions (items capped at 50) |

## deals/<login>.json

`{schema, login, generated_utc, server_offset_sec, deals: [...]}` with each deal carrying
`ticket, position_id, time_utc, symbol, type, entry (in/out/inout/out_by), volume, price,
profit, commission, swap, magic, comment`. Balance operations are excluded. Capped at 500 deals.

## events/<machine>.jsonl

One JSON object per line:

```json
{"ts": "2026-10-23T20:15:02Z", "machine": "VPS8", "level": "error", "source": "watchdog",
 "message": "terminal for 500777 not responding, restarted", "account_id": 500777}
```

`level` is `info`, `warn` or `error`. `account_id` is optional. Write these with
`tools/fleet_event.py` (CLI or import) so the format stays consistent.
