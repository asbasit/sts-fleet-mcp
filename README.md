# sts-fleet-mcp

A read-only [Model Context Protocol](https://modelcontextprotocol.io) server that gives Claude a live
risk view across a fleet of MetaTrader 4/5 trading accounts spread over several Windows machines.

Ask Claude "anything wrong with the fleet?" or "which prop account is closest to breaching?" and it
answers from heartbeat data written every minute by every terminal. Nothing in this server can place,
modify or close a trade.

Built for Swift Trading Services, a small prop-trading operation running challenge, funded, live and
EA-test accounts across multiple VPSes and home PCs. Designed and deployed by [asbasit](https://github.com/asbasit); code written
with [Claude Code](https://claude.com/claude-code).

## How it works

```
MT4/MT5 terminal --STS_Heartbeat EA--> Common\Files\sts_fleet --(junction)--> Dropbox\ClaudeHub\fleet
watchdogs / scripts --tools\fleet_event.py------------------------------------^          |
                                                         Dropbox syncs to every machine  v
                                                      server.py (MCP, stdio) <-- Claude Code
```

- **Heartbeat EA** (`mql5/STS_Heartbeat.mq5`, `.mq4`): attached to one chart per terminal. Every 60s it
  writes account health (balance, equity, day-start balance, peak equity, open positions, terminal
  state) and recent deals as JSON. It never trades.
- **Dropbox as the data bus**: one writer per file, atomic writes, conflicted copies ignored. No
  database, no open ports.
- **MCP server** (`server.py`, Python, `mcp` SDK 1.x or 2.x): reads the files and exposes tools.

## Risk model

Every account is a **test** account by default: measured (day P&L, growth, drawdown from peak) and
checked for operational problems (stale heartbeat, disconnected, Algo Trading off), but never judged
against prop rules.

Accounts tagged in `firm_rules.json` get risk checks:

| Type | Checked against |
|---|---|
| `challenge` / `funded` | the prop firm's daily and max-loss limits **and** an internal buffer (default 4% daily / 9% overall) |
| `live` | the internal buffer only, with per-account overrides (e.g. a recovery account at 10% / 40%) |

Levels: `OK`, `WARN` (within 1 point of the buffer), `BUFFER_HIT`, `BREACH` (firm limit passed).
Cent accounts (USC) also report dollar figures; recovery accounts report progress back to the original deposit.

## Tools

| Tool | Answers |
|---|---|
| `fleet_status` | What's running where, what's stale, what needs attention, split into risk-checked and test accounts |
| `account_health` | One account in full: limits and headroom, or performance for test accounts |
| `breach_risk` | Risk-checked accounts ranked by headroom to their nearest limit |
| `compare_test_accounts` | EA trials side by side by growth, today's P&L or drawdown |
| `recent_trades` | Closed trades, win rate, net P&L after commission and swap |
| `watchdog_events` | Restarts, disconnects and errors logged by watchdogs |

Resources: `fleet://rules`, `fleet://schema`. All tools carry `readOnlyHint`.

## Setup (Windows)

1. Put this folder at `Dropbox\ClaudeHub\sts-fleet` and copy `firm_rules.example.json` to
   `firm_rules.json` (git-ignored; this is where real account tags live).
2. Double-click `setup.bat` on each machine. It works out what the machine has and:
   - finds every MT4/MT5 terminal (including portable installs), installs and compiles the heartbeat EA
   - links MT5's `Common\Files\sts_fleet` into Dropbox
   - finds or installs Python (winget, or a direct download when winget is missing) and the MCP SDK
   - registers the server with Claude Code and Claude Desktop, then runs a self-test
3. Attach `STS_Heartbeat` to one chart per terminal. No inputs needed.
4. Tag prop and live accounts: `python tools\tag_account.py <login> challenge FTMO 100000`.

## Test without MetaTrader

```
python tests/make_sample_fleet.py sample_fleet
set STS_FLEET_DIR=sample_fleet
python tests/smoke_test.py
```

The smoke test starts the server over stdio as a real MCP client would and checks every tool against
a fake fleet covering breaches, buffer warnings, stale heartbeats, cent and live accounts, a corrupt
file and Dropbox conflicted copies.

## Deliberately out of scope

Write tools (closing positions, restarting terminals, toggling EAs). A monitoring tool that can flatten
a funded account is one misread prompt away from an expensive mistake.
