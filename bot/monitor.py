#!/usr/bin/env python3
"""Free, scheduled SOL / Polymarket market monitor. Paper signals only; no trading."""
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

GAMMA = "https://gamma-api.polymarket.com/events"
COINBASE = "https://api.exchange.coinbase.com/products/SOL-USD/candles"

def get_json(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "sol-paper-monitor/1.0",
        "Accept": "application/json"
    })
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))

def pct(a, b):
    return ((b - a) / a) * 100 if a else 0.0

def main():
    now_dt = datetime.now(timezone.utc)
    now = now_dt.isoformat()
    summary = ["# SOL 5-minute paper monitor", "", f"- Checked at (UTC): {now}",
               "- Mode: paper signals only; no wallet, private keys, or real orders.", ""]

    try:
        # Coinbase candles are [time, low, high, open, close, volume]; sort oldest to newest.
        candles = get_json(COINBASE + "?" + urllib.parse.urlencode({"granularity": 60}))
        candles = sorted(candles, key=lambda row: int(row[0]))
        candles = [row for row in candles if len(row) >= 6][-5:]
        if len(candles) < 2:
            raise ValueError("Not enough candle data returned")
        closes = [float(row[4]) for row in candles]
        latest = closes[-1]
        move = pct(closes[0], latest)
        summary += ["## SOL price", f"- Latest SOL/USD 1-minute close: **{latest:.4f}**",
                    f"- Change across returned candles: **{move:+.3f}%**"]
        signal = "UP" if move >= 0.10 else "DOWN" if move <= -0.10 else "NO TRADE"
        summary += [f"- Simple momentum signal: **{signal}** (threshold: ±0.10%)", ""]
    except Exception as exc:
        summary += ["## SOL price", f"- ERROR fetching Coinbase public candles: `{type(exc).__name__}: {exc}`", ""]
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
            end_raw = event.get("endDate") or event.get("end_date")
            try:
                end_dt = datetime.fromisoformat(str(end_raw).replace("Z", "+00:00"))
                if end_dt.tzinfo is None:
                    end_dt = end_dt.replace(tzinfo=timezone.utc)
            except (TypeError, ValueError):
                continue
            is_solana = "solana" in text or slug.lower().startswith("sol-updown-")
            looks_updown = ("up or down" in text or "updown" in text or
                            "up-down" in text or "5 minute" in text or "5m" in slug.lower())
            if is_solana and looks_updown and end_dt > now_dt:
                candidates.append((end_dt, event, title or slug or "(untitled event)"))
        candidates.sort(key=lambda item: item[0])
        summary += ["## Polymarket market discovery"]
        if candidates:
            end_dt, event, title = candidates[0]
            summary += [f"- Next candidate event: **{title}**",
                        f"- Slug: `{event.get('slug', 'not provided')}`",
                        f"- Event end: `{end_dt.isoformat()}`",
                        "- Discovery is best-effort; verify the exact 5-minute contract and its current order book before using its data."]
        else:
            summary += ["- No future matching active Solana Up/Down event found in the first metadata page.",
                        "- Discovery may need pagination or a more specific market query; no expired event is reported as current."]
        summary.append("")
    except Exception as exc:
        summary += ["## Polymarket market discovery",
                    f"- ERROR querying public Gamma metadata: `{type(exc).__name__}: {exc}`", ""]

    summary += ["## Limitations",
                "- This first version is a scheduled monitor, not a continuously running process.",
                "- The momentum signal uses Coinbase SOL/USD candles as a proxy; it does not read Polymarket prices or settle contracts.",
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
