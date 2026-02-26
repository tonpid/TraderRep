# TraderRep

**Version:** 1.0.0  
**Language:** Clarity (Stacks blockchain)

A reputation system for active traders on the Stacks blockchain. Tracks cumulative trading volume, win/loss outcomes, and consecutive win streaks, then combines them into a single score with a time-decay factor so that reputation reflects recent activity rather than historical peaks.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Scoring Model](#scoring-model)
- [Time-Decay](#time-decay)
- [Public Functions](#public-functions)
- [Read-Only Functions](#read-only-functions)
- [Error Codes](#error-codes)
- [Constants Reference](#constants-reference)

---

## Overview

TraderRep is built around three core ideas:

1. **Multi-factor scoring.** A trader's reputation is a weighted combination of three components — volume, win rate, and streak — each capped independently to prevent any single dimension from dominating.
2. **Time-decay.** The stored base score decays linearly the longer a trader is inactive, incentivising consistent participation. A trader who stops trading for ~30 days reaches a score of zero.
3. **Per-trade history.** Every trade is stored individually with its volume, outcome, and signed score delta, giving a complete auditable record of how a trader's reputation evolved over time.

---

## How It Works

```
Trader calls register-trader()
         ↓
Trader calls record-trade(volume, is-win) after each trade
  └─ volume, wins/losses, streak updated
  └─ base score recalculated from all three components
  └─ trade record stored with signed score delta
         ↓
Anyone queries get-rep-score(trader)
  └─ base score retrieved from storage
  └─ time-decay factor applied at the current block
  └─ returns both base score and live decayed score
```

---

## Scoring Model

The maximum possible score is **10,000**. It is composed of three independent components:

| Component | Max Points | Weight | Source |
|-----------|-----------|--------|--------|
| Volume | 4,000 | 40% | Cumulative trading volume in STX |
| Win Rate | 4,000 | 40% | Proportion of winning trades |
| Streak | 2,000 | 20% | Current consecutive win streak |

### Volume Score (0–4,000)

Volume is measured in units of 1 STX (1,000,000 microSTX). The score scales linearly up to a cap of 40 volume units (40 STX lifetime):

```
volume-units = total-volume-uSTX / 1,000,000   (capped at 40)
volume-score = (volume-units / 40) × 4,000
```

### Win-Rate Score (0–4,000)

Win rate only contributes once the trader has at least **5 trades**, preventing noise from small sample sizes:

```
win-rate-score = (wins / total-trades) × 4,000   [if total-trades ≥ 5]
win-rate-score = 0                                 [if total-trades < 5]
```

### Streak Score (0–2,000)

The current consecutive win streak contributes linearly, capped at 10:

```
streak-score = (min(streak, 10) / 10) × 2,000
```

A single loss resets the current streak to zero (but `best-streak` is preserved).

### Base Score

```
base-score = volume-score + win-rate-score + streak-score
```

The base score is stored on-chain after every trade. To get the live reputation at any moment, the decay factor is applied at read time.

---

## Time-Decay

Scores decay linearly based on inactivity, measured from the trader's `last-trade-block`.

```
elapsed-periods = (current-block - last-trade-block) / 144   (144 blocks ≈ 1 day)
decay-factor    = 10,000 - (elapsed-periods × 334)           (in basis points)
decayed-score   = (base-score × decay-factor) / 10,000
```

| Inactivity | Decay Factor | Score Retained |
|------------|-------------|----------------|
| 0 days | 10,000 bps | 100% |
| ~5 days | 8,330 bps | ~83% |
| ~15 days | 5,010 bps | ~50% |
| ~30 days | 0 bps | 0% |

After ~30 days of inactivity (`MAX-DECAY-PERIODS`), the decayed score reaches zero regardless of the stored base score. The base score itself is not modified — recording a new trade immediately restores the full base score.

`get-rep-score` and `get-score-breakdown` both return the live decayed score along with the raw decay factor in basis points. The base score is also always included so consumers can see both values.

---

## Public Functions

### Trader Lifecycle

#### `register-trader`
Registers the calling principal as a trader and initialises their profile with zeroed counters. Must be called once before any trades can be recorded. Fails if the caller is already registered. Permissionless — any principal may register themselves.

#### `deactivate-trader`
Marks the caller's account as inactive. Inactive traders cannot record new trades but retain all historical data and scores. Self-service — no admin required.

#### `reactivate-trader`
Re-enables a previously deactivated account. Self-service.

---

### Trade Recording

#### `record-trade (volume uint) (is-win bool)`
Records a completed trade for the calling trader. Updates cumulative volume, win/loss counters, current and best streak, and recalculates the base score. Stores a per-trade record with the signed score delta. Returns `{ trade-id, base-score }` on success.

- `volume` — Trade size in microSTX; must be greater than zero.
- `is-win` — `true` if the trade was profitable; `false` for a loss. A loss resets `current-streak` to zero.

Only active, registered traders may call this.

---

## Read-Only Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `get-trader-stats (trader principal)` | `(optional stats)` | Full raw profile including all counters and the stored base score (no decay) |
| `get-rep-score (trader principal)` | `(response tuple err)` | Base score, decayed score, decay factor in bps, last trade block, and blocks since last trade |
| `get-win-rate (trader principal)` | `(response tuple err)` | Win rate in basis points, win/loss counts, total trades, and whether minimum trade threshold is met |
| `get-volume-analytics (trader principal)` | `(response tuple err)` | Total volume, trade count, average volume per trade, volume score, and volume units |
| `get-streak-info (trader principal)` | `(response tuple err)` | Current streak, best streak, and current streak's score contribution |
| `get-score-breakdown (trader principal)` | `(response tuple err)` | Full component breakdown: volume score, win-rate score, streak score, base score, decay factor, final score, and max possible score |
| `get-trade-record (trader principal) (trade-id uint)` | `(optional record)` | Single trade entry: volume, outcome, block recorded, and score delta |
| `get-trader-trade-count (trader principal)` | `(response uint err)` | Total number of trades recorded by the trader |
| `get-decay-factor (trader principal)` | `(response uint err)` | Current time-decay factor in basis points (10,000 = no decay) |
| `is-registered (trader principal)` | `bool` | Whether a principal has a registered trader profile |
| `get-platform-stats` | `(response tuple err)` | Platform-wide totals: registered traders and recorded trades |

`get-score-breakdown` is the most informative single call — it returns every component score, the decay factor, and the final live score in one response, making it ideal for dashboards and leaderboards.

---

## Error Codes

| Code | Constant | When it's thrown |
|------|----------|-----------------|
| `u100` | `ERR-NOT-AUTHORIZED` | Reserved for future admin-gated functions |
| `u101` | `ERR-TRADER-NOT-FOUND` | Principal has not registered a trader profile |
| `u102` | `ERR-INVALID-VOLUME` | Trade volume is zero |
| `u103` | `ERR-ALREADY-REGISTERED` | Caller already has a registered profile |
| `u104` | `ERR-TRADER-INACTIVE` | Account is deactivated; cannot record trades |

---

## Constants Reference

```clarity
;; Score Weights (sum = MAX-SCORE = 10,000)
MAX-SCORE             u10000
MAX-VOLUME-POINTS     u4000   ;; 40% from volume
MAX-WIN-RATE-POINTS   u4000   ;; 40% from win rate
MAX-STREAK-POINTS     u2000   ;; 20% from streak

;; Volume Scoring
VOLUME-UNIT           u1000000  ;; 1 STX = 1 volume unit
MAX-VOLUME-UNITS      u40       ;; Score caps at 40 STX lifetime volume

;; Win-Rate Scoring
MIN-TRADES-FOR-RATE   u5        ;; Minimum trades before win rate contributes

;; Streak Scoring
MAX-STREAK            u10       ;; Streak bonus caps at 10 consecutive wins

;; Time-Decay
DECAY-PERIOD-BLOCKS         u144   ;; ~1 day on Stacks
MAX-DECAY-PERIODS           u30    ;; Full decay after ~30 days of inactivity
DECAY-RATE-PER-PERIOD-BPS   u334   ;; ~3.34% decay per day
```