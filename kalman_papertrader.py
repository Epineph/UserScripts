#!/usr/bin/env python3
"""
kalman_papertrader.py

Bayesian state-space (Kalman) filter for time-varying drift on log-returns,
with a simple paper-trading simulator.

This is educational code. It is not financial advice.

Modes
-----
1) backtest: read candles from CSV (timestamp, open, high, low, close, volume).
2) live:     poll Binance spot klines for closed candles.

Core model (local-level)
------------------------
  mu_t = mu_{t-1} + eta_t,     eta_t ~ N(0, q)
  r_t  = mu_t     + eps_t,     eps_t ~ N(0, R_t)

Kalman recursion (scalar)
-------------------------
Predict:
  m_pred = m
  P_pred = P + q

Update:
  K   = P_pred / (P_pred + R)
  m   = m_pred + K * (r - m_pred)
  P   = (1 - K) * P_pred

Trading
-------
Compute predictive distribution:
  r_next ~ N(m, P + R)

Enter/hold long if:
  P(r_next > cost) > 1 - alpha

Position size:
  w = clip( m / (risk_aversion * (P + R)), 0, w_max)

Paper execution:
- Rebalance at the candle close price.
- Apply commission to trades (simple proportional cost).
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Deque, Dict, Iterable, List, Optional, Tuple

try:
    import requests
except ImportError:
    requests = None

from collections import deque


# -----------------------------------------------------------------------------
# Math helpers
# -----------------------------------------------------------------------------
def norm_cdf(x: float) -> float:
    """Standard normal CDF using erf."""
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def safe_log(x: float) -> float:
    if x <= 0.0:
        raise ValueError(f"log input must be > 0, got {x}")
    return math.log(x)


# -----------------------------------------------------------------------------
# Kalman filter (local-level)
# -----------------------------------------------------------------------------
@dataclass
class Kalman1D:
    """
    Scalar Kalman filter for:
      mu_t = mu_{t-1} + N(0, q)
      r_t  = mu_t     + N(0, R)
    """
    m: float = 0.0
    P: float = 1e-6
    q: float = 1e-8

    def step(self, r: float, R: float) -> Tuple[float, float, float]:
        """
        One filter update with observation r and measurement variance R.

        Returns: (m, P, K)
        """
        # Predict
        m_pred = self.m
        P_pred = self.P + self.q

        # Update
        denom = P_pred + R
        if denom <= 0.0:
            raise ValueError(f"Invalid variance sum: P_pred + R = {denom}")

        K = P_pred / denom
        self.m = m_pred + K * (r - m_pred)
        self.P = (1.0 - K) * P_pred

        return self.m, self.P, K


# -----------------------------------------------------------------------------
# Rolling variance estimator for R_t (optional, pragmatic)
# -----------------------------------------------------------------------------
class RollingVar:
    """Rolling variance over last N samples (Welford over a window)."""

    def __init__(self, window: int, floor: float = 1e-10) -> None:
        self.window = int(window)
        self.floor = float(floor)
        self._buf: Deque[float] = deque(maxlen=self.window)

    def push(self, x: float) -> None:
        self._buf.append(float(x))

    def var(self) -> float:
        n = len(self._buf)
        if n < 2:
            return self.floor
        mean = sum(self._buf) / n
        v = sum((xi - mean) ** 2 for xi in self._buf) / (n - 1)
        return max(v, self.floor)


# -----------------------------------------------------------------------------
# Paper portfolio
# -----------------------------------------------------------------------------
@dataclass
class Portfolio:
    cash: float
    units: float = 0.0
    commission: float = 0.001  # proportional, per trade
    equity: float = 0.0

    def mark_to_market(self, price: float) -> float:
        self.equity = self.cash + self.units * price
        return self.equity

    def rebalance_to_weight(self, target_w: float, price: float) -> Dict[str, float]:
        """
        Rebalance to target weight in the asset (long-only):
          target_w in [0, 1].

        Uses close price for fills. Applies commission on notional traded.
        """
        target_w = max(0.0, min(1.0, target_w))
        eq = self.mark_to_market(price)

        target_value = target_w * eq
        current_value = self.units * price
        delta_value = target_value - current_value

        trade = {
            "trade_notional": 0.0,
            "commission_paid": 0.0,
            "delta_units": 0.0,
        }

        if abs(delta_value) < 1e-12:
            return trade

        # Buy
        if delta_value > 0.0:
            notional = delta_value
            fee = self.commission * notional
            total_cost = notional + fee
            if total_cost > self.cash:
                # Cap by available cash
                notional = self.cash / (1.0 + self.commission)
                fee = self.commission * notional
                total_cost = notional + fee

            delta_units = notional / price
            self.cash -= total_cost
            self.units += delta_units

            trade["trade_notional"] = notional
            trade["commission_paid"] = fee
            trade["delta_units"] = delta_units
            return trade

        # Sell
        notional = -delta_value
        delta_units = notional / price
        delta_units = min(delta_units, self.units)  # cannot sell more than owned
        notional = delta_units * price
        fee = self.commission * notional
        proceeds = notional - fee

        self.cash += proceeds
        self.units -= delta_units

        trade["trade_notional"] = -notional
        trade["commission_paid"] = fee
        trade["delta_units"] = -delta_units
        return trade


# -----------------------------------------------------------------------------
# Data: CSV backtest
# -----------------------------------------------------------------------------
def read_csv_candles(path: str) -> Iterable[Tuple[int, float]]:
    """
    Yield (timestamp_ms, close) from a CSV containing at least:
      timestamp, close
    or
      datetime, close
    """
    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if "close" not in row:
                raise ValueError("CSV must contain a 'close' column.")
            close = float(row["close"])

            if "timestamp" in row:
                ts_ms = int(float(row["timestamp"]))
            elif "timestamp_ms" in row:
                ts_ms = int(float(row["timestamp_ms"]))
            elif "datetime" in row:
                # Parse ISO-ish, assume UTC if no tz.
                dt = datetime.fromisoformat(row["datetime"])
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                ts_ms = int(dt.timestamp() * 1000.0)
            else:
                raise ValueError(
                    "CSV must contain 'timestamp'/'timestamp_ms' or 'datetime'."
                )

            yield ts_ms, close


# -----------------------------------------------------------------------------
# Data: Binance klines polling (live)
# -----------------------------------------------------------------------------
def binance_get_latest_closed_kline(symbol: str, interval: str) -> Tuple[int, float]:
    """
    Poll Binance spot klines and return the most recent CLOSED candle:
      (close_time_ms, close_price)

    Note:
    - This relies on a public REST endpoint which may change.
    - If you want true streaming, use websockets or ccxt.pro.
    """
    if requests is None:
        raise RuntimeError("requests not installed; cannot use --mode live.")

    url = "https://api.binance.com/api/v3/klines"
    params = {"symbol": symbol.upper(), "interval": interval, "limit": 2}

    r = requests.get(url, params=params, timeout=10)
    r.raise_for_status()
    data = r.json()

    # Each kline:
    # [ open_time, open, high, low, close, volume, close_time, ... ]
    if not isinstance(data, list) or len(data) < 2:
        raise RuntimeError("Unexpected Binance response shape for klines.")

    # The last entry may be still forming. We take the *second last* as closed.
    k = data[-2]
    close_time_ms = int(k[6])
    close_price = float(k[4])
    return close_time_ms, close_price


# -----------------------------------------------------------------------------
# Trading logic
# -----------------------------------------------------------------------------
@dataclass
class TraderConfig:
    q: float
    alpha: float
    risk_aversion: float
    w_max: float
    cost_bps: float  # cost threshold in basis points (per decision step)
    R_mode: str      # "fixed" or "rolling"
    R_fixed: float
    R_window: int


def prob_return_exceeds_cost(m: float, V: float, cost: float) -> float:
    """
    r_next ~ N(m, V). Return P(r_next > cost).
    """
    if V <= 0.0:
        return 0.0
    z = (cost - m) / math.sqrt(V)
    return 1.0 - norm_cdf(z)


def decide_weight(m: float, V: float, p: float, cfg: TraderConfig) -> float:
    """
    Decide long-only target weight given:
      m: predicted mean return
      V: predicted variance
      p: P(r_next > cost)

    Uses a probability gate and mean-variance sizing.
    """
    if p <= 1.0 - cfg.alpha:
        return 0.0

    if V <= 0.0:
        return 0.0

    w = m / (cfg.risk_aversion * V)
    w = max(0.0, min(cfg.w_max, w))
    return w


# -----------------------------------------------------------------------------
# Main loops
# -----------------------------------------------------------------------------
def run_on_stream(
    stream: Iterable[Tuple[int, float]],
    out_csv: str,
    cash: float,
    commission: float,
    cfg: TraderConfig,
) -> None:
    kf = Kalman1D(m=0.0, P=1e-6, q=cfg.q)
    rv = RollingVar(cfg.R_window) if cfg.R_mode == "rolling" else None

    port = Portfolio(cash=cash, units=0.0, commission=commission)
    last_close: Optional[float] = None

    cost = cfg.cost_bps / 10_000.0  # bps -> decimal return

    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "timestamp_ms",
            "close",
            "logret",
            "R",
            "kalman_m",
            "kalman_P",
            "kalman_K",
            "pred_var",
            "p_exceed_cost",
            "target_w",
            "trade_notional",
            "commission_paid",
            "delta_units",
            "cash",
            "units",
            "equity",
        ])

        for ts_ms, close in stream:
            if last_close is None:
                last_close = close
                port.mark_to_market(close)
                continue

            r = safe_log(close / last_close)
            last_close = close

            if rv is not None:
                rv.push(r)
                R = rv.var()
            else:
                R = cfg.R_fixed

            m, P, K = kf.step(r=r, R=R)
            pred_var = P + R

            p_exc = prob_return_exceeds_cost(m=m, V=pred_var, cost=cost)
            target_w = decide_weight(m=m, V=pred_var, p=p_exc, cfg=cfg)

            trade = port.rebalance_to_weight(target_w=target_w, price=close)
            eq = port.mark_to_market(close)

            w.writerow([
                ts_ms,
                close,
                r,
                R,
                m,
                P,
                K,
                pred_var,
                p_exc,
                target_w,
                trade["trade_notional"],
                trade["commission_paid"],
                trade["delta_units"],
                port.cash,
                port.units,
                eq,
            ])


def live_stream_binance(symbol: str, interval: str, poll_s: float) -> Iterable[Tuple[int, float]]:
    """
    Yield closed candles (close_time_ms, close_price) as they appear.
    """
    last_ts: Optional[int] = None
    while True:
        try:
            ts_ms, close = binance_get_latest_closed_kline(symbol, interval)
            if last_ts is None or ts_ms > last_ts:
                last_ts = ts_ms
                yield ts_ms, close
        except Exception as e:
            print(f"[live] error: {e}", file=sys.stderr)
        time.sleep(poll_s)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Kalman state-space paper trader (educational)."
    )

    p.add_argument("--mode", choices=["backtest", "live"], required=True)

    # Data selection
    p.add_argument("--csv", help="CSV file for --mode backtest.")
    p.add_argument("--symbol", default="BTCUSDT", help="Binance symbol for live.")
    p.add_argument("--interval", default="1h", help="Binance kline interval.")
    p.add_argument("--poll-seconds", type=float, default=10.0, help="Live poll period.")

    # Portfolio
    p.add_argument("--cash", type=float, default=10_000.0, help="Initial cash.")
    p.add_argument("--commission", type=float, default=0.001, help="Commission rate.")

    # Filter / decision
    p.add_argument("--q", type=float, default=1e-8,
                   help="Process variance q (drift random walk).")
    p.add_argument("--alpha", type=float, default=0.05,
                   help="Probability tail for entry gate.")
    p.add_argument("--risk-aversion", type=float, default=10.0,
                   help="Mean-variance risk aversion lambda.")
    p.add_argument("--w-max", type=float, default=1.0,
                   help="Max portfolio weight in the asset.")
    p.add_argument("--cost-bps", type=float, default=10.0,
                   help="Cost threshold in bps per step (commission+slippage+spread).")

    # Observation variance R
    p.add_argument("--R-mode", choices=["fixed", "rolling"], default="rolling")
    p.add_argument("--R-fixed", type=float, default=1e-4,
                   help="Fixed R if --R-mode fixed.")
    p.add_argument("--R-window", type=int, default=200,
                   help="Rolling window for R if --R-mode rolling.")

    p.add_argument("--out", default="paper_log.csv", help="Output CSV path.")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    cfg = TraderConfig(
        q=args.q,
        alpha=args.alpha,
        risk_aversion=args.risk_aversion,
        w_max=args.w_max,
        cost_bps=args.cost_bps,
        R_mode=args.R_mode,
        R_fixed=args.R_fixed,
        R_window=args.R_window,
    )

    if args.mode == "backtest":
        if not args.csv:
            raise SystemExit("--csv is required for --mode backtest.")
        stream = read_csv_candles(args.csv)
        run_on_stream(
            stream=stream,
            out_csv=args.out,
            cash=args.cash,
            commission=args.commission,
            cfg=cfg,
        )
        return

    # live
    if requests is None:
        raise SystemExit("requests is required for --mode live (pip install requests).")
    stream = live_stream_binance(
        symbol=args.symbol,
        interval=args.interval,
        poll_s=args.poll_seconds,
    )
    run_on_stream(
        stream=stream,
        out_csv=args.out,
        cash=args.cash,
        commission=args.commission,
        cfg=cfg,
    )


if __name__ == "__main__":
    main()
