# Free SOL / Polymarket Paper Monitor

This repository runs a scheduled paper monitor through GitHub Actions. It checks public SOL/USDT candles and searches public Polymarket Gamma metadata for a possible Solana Up/Down event.

## What it does
- Runs on a GitHub Actions schedule every five minutes, plus manual runs.
- Uses public APIs; no API key, wallet, private key, or paid service is required.
- Writes a readable report into each Actions run's summary.
- Never places orders or connects to a wallet.

## How to view it from an iPhone
1. Open the Actions tab in this repository.
2. Select **SOL paper monitor**.
3. Open the newest run and read **Summary** for the latest signal and data status.
4. To test it immediately, open **Run workflow** and start a manual run.

Repository: https://github.com/keruskiens-ux/claude-test/actions

## Important limits
- GitHub scheduled workflows are not a 24/7 process. Scheduled runs can be delayed or skipped, and this setup does not guarantee an exact five-minute cadence.
- The first version is a monitor, not a complete paper-trading ledger. It does not calculate cumulative paper P&L or settle Polymarket contracts.
- The momentum signal is based on Binance SOL/USDT candles, not Polymarket contract prices. It is a research proxy only.
- Public Polymarket market metadata may not expose the intended market in every region or at every time. A discovered event must be checked manually.
- No live trading is implemented.

## Files
- `bot/monitor.py`: public-data scanner and report.
- `.github/workflows/sol-paper-monitor.yml`: scheduled workflow.
