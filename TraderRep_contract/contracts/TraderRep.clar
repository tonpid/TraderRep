;; title: TraderRep
;; version: 1.0.0
;; summary: Trading behavior analytics with volume tracking, win rates, and time-decay scoring
;; description: A reputation system for active traders on the Stacks blockchain. Tracks cumulative
;;              trading volume, win/loss outcomes, consecutive win streaks, and applies a
;;              time-decay factor so that scores reflect recent activity rather than historical peaks.

;; ============================================================
;; constants
;; ============================================================

;; --- Error codes ---
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-TRADER-NOT-FOUND (err u101))
(define-constant ERR-INVALID-VOLUME (err u102))
(define-constant ERR-ALREADY-REGISTERED (err u103))
(define-constant ERR-TRADER-INACTIVE (err u104))

;; --- Score weights (must sum to MAX-SCORE = 10000) ---
(define-constant MAX-SCORE u10000)
(define-constant MAX-VOLUME-POINTS u4000)    ;; 40% from volume
(define-constant MAX-WIN-RATE-POINTS u4000)  ;; 40% from win rate
(define-constant MAX-STREAK-POINTS u2000)    ;; 20% from streak

;; --- Volume scoring ---
;; Volume is tracked in micro-STX (1 STX = 1,000,000 uSTX)
;; Each VOLUME-UNIT uSTX contributes 1 volume scoring unit
(define-constant VOLUME-UNIT u1000000)       ;; 1 STX = 1 volume unit
(define-constant MAX-VOLUME-UNITS u40)       ;; Caps at 40 volume units (40 STX worth)

;; --- Win-rate scoring ---
;; Require at least this many trades before win-rate contributes to score
(define-constant MIN-TRADES-FOR-RATE u5)

;; --- Streak scoring ---
(define-constant MAX-STREAK u10)             ;; Streak bonus caps at 10 consecutive wins

;; --- Time-decay configuration ---
;; Score is multiplied by a decay factor based on inactivity.
;; decay-factor is expressed in basis points (10000 = 100%, no decay).
;; Every DECAY-PERIOD-BLOCKS of inactivity reduces the factor by DECAY-RATE-PER-PERIOD-BPS.
;; After MAX-DECAY-PERIODS of inactivity the score reaches zero.
(define-constant DECAY-PERIOD-BLOCKS u144)        ;; ~1 day on Stacks
(define-constant MAX-DECAY-PERIODS u30)           ;; Full decay after ~30 days
(define-constant DECAY-RATE-PER-PERIOD-BPS u334)  ;; ~3.34% decay per day (10000/30 rounded)

;; ============================================================
;; data vars
;; ============================================================

(define-data-var total-registered-traders uint u0)
(define-data-var total-recorded-trades uint u0)
(define-data-var contract-owner principal tx-sender)

;; ============================================================
;; data maps
;; ============================================================

;; Primary trader profile
(define-map trader-stats
  { trader: principal }
  {
    total-volume: uint,        ;; Lifetime trading volume in micro-STX
    wins: uint,                ;; Winning trades
    losses: uint,              ;; Losing trades
    total-trades: uint,        ;; wins + losses
    current-streak: uint,      ;; Consecutive wins (resets on loss)
    best-streak: uint,         ;; All-time best streak
    rep-score: uint,           ;; Latest stored base score (pre-decay)
    last-trade-block: uint,    ;; stacks-block-height of last recorded trade
    registered-block: uint,    ;; stacks-block-height when account was created
    is-active: bool            ;; Active flag; inactive traders cannot record trades
  }
)

;; Per-trade history
(define-map trade-records
  { trader: principal, trade-id: uint }
  {
    volume: uint,              ;; Trade size in micro-STX
    outcome: bool,             ;; true = win, false = loss
    block-recorded: uint,      ;; stacks-block-height at record time
    score-delta: int           ;; Signed change in base score caused by this trade
  }
)

;; Sequential trade-ID counter per trader
(define-map trader-trade-counter
  { trader: principal }
  { next-id: uint }
)

;; ============================================================
;; private functions
;; ============================================================

;; Returns the next trade-ID for a trader without mutating state.
(define-private (peek-next-trade-id (trader principal))
  (let ((counter (default-to { next-id: u1 }
                   (map-get? trader-trade-counter { trader: trader }))))
    (get next-id counter)
  )
)

;; Volume score component: scales linearly up to MAX-VOLUME-POINTS.
(define-private (calc-volume-score (total-volume uint))
  (let (
    (units (/ total-volume VOLUME-UNIT))
    (capped (if (> units MAX-VOLUME-UNITS) MAX-VOLUME-UNITS units))
  )
    (/ (* capped MAX-VOLUME-POINTS) MAX-VOLUME-UNITS)
  )
)

;; Win-rate score component.
;; Returns 0 until the trader has MIN-TRADES-FOR-RATE trades to avoid noise on small samples.
(define-private (calc-win-rate-score (wins uint) (total-trades uint))
  (if (< total-trades MIN-TRADES-FOR-RATE)
    u0
    (/ (* wins MAX-WIN-RATE-POINTS) total-trades)
  )
)

;; Streak score component: scales linearly up to MAX-STREAK-POINTS.
(define-private (calc-streak-score (streak uint))
  (let ((capped (if (> streak MAX-STREAK) MAX-STREAK streak)))
    (/ (* capped MAX-STREAK-POINTS) MAX-STREAK)
  )
)

;; Aggregates all three score components into a base score (no decay applied).
(define-private (calc-base-score
    (total-volume uint)
    (wins uint)
    (total-trades uint)
    (streak uint))
  (+
    (calc-volume-score total-volume)
    (calc-win-rate-score wins total-trades)
    (calc-streak-score streak)
  )
)

;; Returns the time-decay factor in basis points (0-10000).
;; Factor decreases linearly with each elapsed DECAY-PERIOD-BLOCKS of inactivity.
;; Returns 10000 (no decay) if last-block >= current-block.
(define-private (calc-decay-factor (last-block uint) (current-block uint))
  (if (>= last-block current-block)
    u10000
    (let (
      (elapsed (- current-block last-block))
      (periods (/ elapsed DECAY-PERIOD-BLOCKS))
      (decay (* periods DECAY-RATE-PER-PERIOD-BPS))
    )
      (if (>= decay u10000)
        u0
        (- u10000 decay)
      )
    )
  )
)

;; Applies the decay factor to a base score.
(define-private (apply-decay (base-score uint) (last-block uint) (current-block uint))
  (let ((factor (calc-decay-factor last-block current-block)))
    (/ (* base-score factor) u10000)
  )
)

;; ============================================================
;; public functions
;; ============================================================

;; Register the caller as a trader.
;; Must be called once before any trades can be recorded.
(define-public (register-trader)
  (let (
    (trader tx-sender)
    (current-block stacks-block-height)
  )
    (asserts! (is-none (map-get? trader-stats { trader: trader })) ERR-ALREADY-REGISTERED)
    (map-set trader-stats { trader: trader }
      {
        total-volume: u0,
        wins: u0,
        losses: u0,
        total-trades: u0,
        current-streak: u0,
        best-streak: u0,
        rep-score: u0,
        last-trade-block: current-block,
        registered-block: current-block,
        is-active: true
      }
    )
    (map-set trader-trade-counter { trader: trader } { next-id: u1 })
    (var-set total-registered-traders (+ (var-get total-registered-traders) u1))
    (ok true)
  )
)

;; Record a completed trade for the calling trader.
;;   volume  - trade size in micro-STX (must be > 0)
;;   is-win  - true if the trade was profitable
;;
;; Returns the assigned trade-id and the updated base rep score.
(define-public (record-trade (volume uint) (is-win bool))
  (let (
    (trader tx-sender)
    (current-block stacks-block-height)
    (stats (unwrap! (map-get? trader-stats { trader: trader }) ERR-TRADER-NOT-FOUND))
  )
    (asserts! (get is-active stats) ERR-TRADER-INACTIVE)
    (asserts! (> volume u0) ERR-INVALID-VOLUME)

    (let (
      (prev-volume  (get total-volume stats))
      (prev-wins    (get wins stats))
      (prev-losses  (get losses stats))
      (prev-trades  (get total-trades stats))
      (prev-streak  (get current-streak stats))
      (prev-best    (get best-streak stats))
      (prev-score   (get rep-score stats))

      (new-volume   (+ prev-volume volume))
      (new-wins     (if is-win (+ prev-wins u1) prev-wins))
      (new-losses   (if is-win prev-losses (+ prev-losses u1)))
      (new-trades   (+ prev-trades u1))
      (new-streak   (if is-win (+ prev-streak u1) u0))
      (new-best     (if (and is-win (> (+ prev-streak u1) prev-best))
                      (+ prev-streak u1)
                      prev-best))

      (new-score    (calc-base-score new-volume new-wins new-trades new-streak))
      (delta        (- (to-int new-score) (to-int prev-score)))
      (trade-id     (peek-next-trade-id trader))
    )
      (map-set trade-records { trader: trader, trade-id: trade-id }
        {
          volume: volume,
          outcome: is-win,
          block-recorded: current-block,
          score-delta: delta
        }
      )
      (map-set trader-trade-counter { trader: trader } { next-id: (+ trade-id u1) })
      (map-set trader-stats { trader: trader }
        (merge stats {
          total-volume: new-volume,
          wins: new-wins,
          losses: new-losses,
          total-trades: new-trades,
          current-streak: new-streak,
          best-streak: new-best,
          rep-score: new-score,
          last-trade-block: current-block
        })
      )
      (var-set total-recorded-trades (+ (var-get total-recorded-trades) u1))
      (ok { trade-id: trade-id, base-score: new-score })
    )
  )
)

;; Deactivate the caller's trader account.
;; Inactive accounts cannot record new trades but retain all history.
(define-public (deactivate-trader)
  (let (
    (trader tx-sender)
    (stats (unwrap! (map-get? trader-stats { trader: trader }) ERR-TRADER-NOT-FOUND))
  )
    (map-set trader-stats { trader: trader } (merge stats { is-active: false }))
    (ok true)
  )
)

;; Reactivate a previously deactivated trader account.
(define-public (reactivate-trader)
  (let (
    (trader tx-sender)
    (stats (unwrap! (map-get? trader-stats { trader: trader }) ERR-TRADER-NOT-FOUND))
  )
    (map-set trader-stats { trader: trader } (merge stats { is-active: true }))
    (ok true)
  )
)

;; ============================================================
;; read only functions
;; ============================================================

;; Full raw profile for a trader (no decay applied).
(define-read-only (get-trader-stats (trader principal))
  (map-get? trader-stats { trader: trader })
)

;; Reputation score with time-decay applied at the current block.
;; Returns both the stored base score and the live decayed score.
(define-read-only (get-rep-score (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats
    (let (
      (base    (get rep-score stats))
      (last    (get last-trade-block stats))
      (cur     stacks-block-height)
      (decayed (apply-decay base last cur))
    )
      (ok {
        base-score:              base,
        decayed-score:           decayed,
        decay-factor-bps:        (calc-decay-factor last cur),
        last-trade-block:        last,
        blocks-since-last-trade: (if (>= cur last) (- cur last) u0)
      })
    )
    ERR-TRADER-NOT-FOUND
  )
)

;; Win-rate expressed in basis points (10000 = 100%).
(define-read-only (get-win-rate (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats
    (let (
      (t (get total-trades stats))
      (w (get wins stats))
    )
      (ok {
        win-rate-bps:        (if (is-eq t u0) u0 (/ (* w u10000) t)),
        wins:                w,
        losses:              (get losses stats),
        total-trades:        t,
        has-sufficient-data: (>= t MIN-TRADES-FOR-RATE)
      })
    )
    ERR-TRADER-NOT-FOUND
  )
)

;; Volume analytics: totals, per-trade average, and score contribution.
(define-read-only (get-volume-analytics (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats
    (let (
      (vol (get total-volume stats))
      (t   (get total-trades stats))
    )
      (ok {
        total-volume-ustx: vol,
        total-trades:      t,
        avg-volume-ustx:   (if (is-eq t u0) u0 (/ vol t)),
        volume-score:      (calc-volume-score vol),
        volume-units:      (/ vol VOLUME-UNIT)
      })
    )
    ERR-TRADER-NOT-FOUND
  )
)

;; Streak information and its score contribution.
(define-read-only (get-streak-info (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats
    (ok {
      current-streak: (get current-streak stats),
      best-streak:    (get best-streak stats),
      streak-score:   (calc-streak-score (get current-streak stats))
    })
    ERR-TRADER-NOT-FOUND
  )
)

;; Detailed score breakdown at the current block.
(define-read-only (get-score-breakdown (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats
    (let (
      (vol-score   (calc-volume-score (get total-volume stats)))
      (wr-score    (calc-win-rate-score (get wins stats) (get total-trades stats)))
      (str-score   (calc-streak-score (get current-streak stats)))
      (base-score  (+ vol-score wr-score str-score))
      (last        (get last-trade-block stats))
      (cur         stacks-block-height)
      (factor      (calc-decay-factor last cur))
      (final-score (/ (* base-score factor) u10000))
    )
      (ok {
        volume-score:       vol-score,
        win-rate-score:     wr-score,
        streak-score:       str-score,
        base-score:         base-score,
        decay-factor-bps:   factor,
        final-score:        final-score,
        max-possible-score: MAX-SCORE
      })
    )
    ERR-TRADER-NOT-FOUND
  )
)

;; Fetch a single trade record.
(define-read-only (get-trade-record (trader principal) (trade-id uint))
  (map-get? trade-records { trader: trader, trade-id: trade-id })
)

;; Total number of trades recorded by a trader.
(define-read-only (get-trader-trade-count (trader principal))
  (match (map-get? trader-trade-counter { trader: trader })
    counter (ok (- (get next-id counter) u1))
    (ok u0)
  )
)

;; Current time-decay factor for a trader (in basis points).
(define-read-only (get-decay-factor (trader principal))
  (match (map-get? trader-stats { trader: trader })
    stats (ok (calc-decay-factor (get last-trade-block stats) stacks-block-height))
    ERR-TRADER-NOT-FOUND
  )
)

;; Whether a principal has a registered trader profile.
(define-read-only (is-registered (trader principal))
  (is-some (map-get? trader-stats { trader: trader }))
)

;; Platform-level aggregate statistics.
(define-read-only (get-platform-stats)
  (ok {
    total-registered-traders: (var-get total-registered-traders),
    total-recorded-trades:    (var-get total-recorded-trades)
  })
)
