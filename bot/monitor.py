#!/usr/bin/env python3
"""Free, scheduled SOL / Polymarket market monitor. Paper signals only; no trading."""
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

GAMMA = "https://gamma-api.polymarket.com/events"
BINANCE = "https://api.binance.com/api/v3/klines"

def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "sol-paper-monitor/1.0"})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))

def pct(a, b):
    return ((b - a) / a) * 100 if a else 0.0

def main():
    now = datetime.now(timezone.utc).isoformat()
    summary = ["# SOL 5-minute paper monitor", "", f"- Checked at (UTC): {now}",
               "- Mode: paper signals only; no wallet, private keys, or real orders.", ""]

    try:
        candles = get_json(BINANCE + "?" + urllib.parse.urlencode({
            "symbol": "SOLUSDT", "interval": "1m", "limit": 5
        }))
        closes = [float(row[4]) for row in candles]
        latest = closes[-1]
        move = pct(closes[0], latest)
        summary += ["## SOL price", f"- Latest SOL/USDT 1-minute close: **{latest:.4f}**",
                    f"- Change across returned candles: **{move:+.3f}%**"]
        signal = "UP" if move >= 0.10 else "DOWN" if move <= -0.10 else "NO TRADE"
        summary += [f"- Simple momentum signal: **{signal}** (threshold: ±0.10%)", ""]
    except Exception as exc:
        summary += ["## SOL price", f"- ERROR fetching Binance public candles: `{type(exc).__name__}: {exc}`", ""]
        signal = "UNAVAILABLE"

    try:
        events = get_json(GAMMA + "?" + urllib.parse.urlencode({
            "active": "true", "closed": "false", "limit": 200,
            "order": "endDate", "ascending": "true"
        }))
        candidates = []
        for event in events if isinstance(events, list) else []:
            title = str(event.get("title") or event.get("question") or "")
            slug = str(event.get("slug") or "")
            text = (title + " " + slug).lower()
            is_solana = "solana" in text or "sol" in slug.lower()
            looks_updown = ("up or down" in text or "updown" in text or
                            "up-down" in text or "5 minute" in text or "5m" in slug)
            if is_solana and looks_updown:
                candidates.append((event, title or slug or "(untitled event)"))
        summary += ["## Polymarket market discovery"]
        if candidates:
            event, title = candidates[0]
            summary += [f"- Candidate event: **{title}**",
                        f"- Slug: `{event.get('slug', 'not provided')}`",
                        f"- Event end: `{event.get('endDate', 'not provided')}`",
                        "- Discovery is best-effort; verify the exact 5-minute contract before using its data."]
        else:
            summary += ["- No matching active Solana Up/Down event found in this metadata page.",
                        "- This does not prove no such market exists; discovery filters/API coverage may need tuning."]
        summary.append("")
    except Exception as exc:
        summary += ["## Polymarket market discovery",
                    f"- ERROR querying public Gamma metadata: `{type(exc).__name__}: {exc}`", ""]

    summary += ["## Limitations",
                "- This first version is a scheduled monitor, not a continuously running process.",
                "- The momentum signal uses Binance SOL/USDT candles as a proxy; it does not read Polymarket prices or settle contracts.",
                "- No profitability claim is made. Do not use this as a live-trading signal."]
    report = "\n".join(summary) + "\n"
    print(report)
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as f:
            f.write(report)
    if signal == "UNAVAILABLE":
        sys.exit(1)

if __name__ == "__main__":
    main()
