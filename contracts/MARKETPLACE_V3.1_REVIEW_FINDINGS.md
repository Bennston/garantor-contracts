# Marketplace V3.1 — Scoped Review Findings

**Reviewer:** Kimi
**Scope:** `marketplace_listing.tact`, `marketplace_factory.tact`, window-seeding in `escrow_oracle_vault.tact`
**Branch reviewed:** `feat/v2-usdt-jetton-escrow` (post-Phase 2, pre-Phase 3 gate)
**Date:** 2026-09-05
**Guide used:** `MARKETPLACE_V3.1_REVIEW_GUIDE.md`

---

## Executive Summary

**Recommendation: GO with fixes** — safe for mainnet redeploy once two Low
findings are addressed (both are one-liners). No Critical, High, or Medium
issues found. The quantity math, supply accounting, auth boundaries, and
"future-purchases-only" invariants all hold up under adversarial reading.

> **Status: both findings fixed and merged** — see the addendum at the bottom
> of this file. This document is kept as the review record; the addendum is
> what actually shipped.

---

## Findings

### Low

#### L1 — `UpdateListingParams` stores raw window values; factory `config()` can mislead off-chain readers

**File:** `marketplace_factory.tact` · **Line:** `receive(msg: UpdateListingParams)`

The factory's `UpdateListingParams` writes window fields directly without clamping:
```tact
if (msg.deadlineWindow != 0) { self.deadlineWindow = msg.deadlineWindow; }
```
The `[300, 31_536_000]` clamp only happens later inside `ConfigureListing`
(`resolveWindow`) and `InitVault` (`_windowOr`). This means:
1. `factory.config()` can return out-of-range values, misleading indexers/UIs.
2. A factory owner can accidentally set `objectionWindow = 10`, which will
   cause **every subsequent `CreateListing` to bounce** at the listing level
   until the owner fixes it.

**Fix:** Clamp in `UpdateListingParams` using the same `resolveWindow`-equivalent
logic, or at minimum reject values outside `[300, 31536000]` so the owner gets
immediate feedback instead of discovering it via bounced listing deployments.

---

#### L2 — `RestockListing` lacks an explicit overflow guard for `uint64` fields

**File:** `marketplace_listing.tact` · **Line:** `receive(msg: RestockListing)`

```tact
self.initialSupply = self.initialSupply + msg.addSupply;
self.remainingSupply = self.remainingSupply + msg.addSupply;
```
Both fields are `Int as uint64`. Tact will throw at serialization time if the
value exceeds `uint64` max rather than wrapping, so funds are safe. However,
the error is a low-level serialization failure, not a descriptive message. A
seller restocking near the uint64 ceiling gets an opaque revert.

**Fix:** Add an explicit guard before the addition:
```tact
require(self.initialSupply + msg.addSupply <= 18446744073709551615, "Restock overflow");
```
(or use a named constant for `2^64-1`).

---

### Informational

#### I1 — 5-minute floor on `objectionWindow` may be too short for real-world use

**File:** `marketplace_listing.tact` / `escrow_oracle_vault.tact` · **Lines:** `resolveWindow` / `_windowOr`

The clamp floor is `300` seconds (5 minutes). While this prevents immediate
self-destruct or zero-length disputes, a 5-minute objection window after an
oracle "Delivered" report gives buyers essentially no practical time to react
and dispute. This is a **business-judgment call**, not a code bug — the
default is 48h and the DAO is unlikely to set it this low. Consider
documenting a recommended minimum (e.g., 3600s / 1 hour) in the DAO ops
runbook, or raising the hard floor.

**Disposition: open, deferred to DAO ops judgment** — not a code change. Flagged
in the rollout doc for whoever operates `UpdateListingParams` going forward.

#### I2 — Factory `CreateListing` does not pre-validate `pricePerUnit <= MaxTradeValue` or `minOrderQty <= initialSupply`

**File:** `marketplace_factory.tact` · **Line:** `receive(msg: CreateListing)`

These checks are deferred to the listing's `ConfigureListing`, so invalid
values cause a bounce and refund rather than a bad deployment. This is safe
but wastes ~0.1 TON of gas per mistake. Not worth a code change unless UX
feedback demands it.

**Disposition: no change** — accepted tradeoff.

#### I3 — `UpdateListingParams`'s `guaranteePercent` bound vs. the `255` sentinel

**File:** `marketplace_factory.tact` · **Line:** `receive(msg: UpdateListingParams)`

The `guaranteePercent` field is `Int as uint8`. The condition
`if (msg.guaranteePercent != 0)` enters the update block, then
`require(msg.guaranteePercent <= 20)` rejects 255. This is correct and safe —
255 is not a valid guarantee percent. No change needed.

**Disposition: no change** — confirmed correct as-is.

#### I4 — `PurchaseListing` idempotency deliberately excludes `quantity` from the nonce key

**File:** `marketplace_listing.tact` · **Line:** `PurchaseListing` nonce calculation

A rebroadcast with the same nonce but a different quantity is rejected
outright. This is the **correct tradeoff**: a retry should mean the exact same
intent; changing quantity is a new order and requires a new nonce. The
frontend already generates fresh nonces per form submission.

**Disposition: no change** — confirmed correct design.

#### I5 — Gas headroom on new/modified receivers appears adequate

**File:** `marketplace_listing.tact`, `marketplace_factory.tact`

No additional gas bumps appear necessary beyond the one the test suite already
found (`ListingConfigured` ack, 0.01→0.03 TON). Tier-3 mutators and
`UpdateListingParams` perform no external sends, so their gas cost is minimal.
Recommendation: monitor `exit -14` on testnet under real load.

**Disposition: no change** — monitoring note only.

---

## Tier-by-Tier Checklist (reviewer self-certification)

| Property | Status | Notes |
|---|---|---|
| P1 — No underflow in `remainingSupply -= qty` | ✅ | Guarded immediately before by `require(qty <= remainingSupply)`; TVM sequential execution rules out TOCTOU. |
| P2 — No overflow in `pricePerUnit * quantity` | ✅ | Worst case ~1.8e36 << 257-bit ceiling (~7.7e76); `require(tradeValue <= MaxTradeValue)` is belt-and-braces. |
| P3 — Bounce restores exact qty, capped at `initialSupply` | ✅ | `bounced()` reads `pendingQty`, adds back, clamps with `min(.., initialSupply)`. |
| P4 — MOQ/cap boundaries inclusive | ✅ | `qty >= minOrderQty`, `qty <= maxOrderQty` (or uncapped if 0); `minOrderQty` 0 normalizes to 1. |
| P5 — Window clamping applied everywhere | ✅ (factory `UpdateListingParams` was the gap — **now fixed, see L1**) | `resolveWindow`/`_windowOr` both enforce `[300, 31_536_000]`. |
| P6 — Percent bounds stay in sync | ✅ | Factory `UpdateListingParams` mirrors `ConfigureListing`'s bounds exactly. |
| P7 — `commissionPercent: 255` sentinel unambiguous | ✅ | Real values capped at 10; 255 safely out of range. |
| P8 — Tier-3 auth checks are first and correct | ✅ | Seller-gated messages check `sender()==seller` first; `UpdateProtocolAddrs` checks `requireOwner()` first. |
| P9 — "Future purchases only" invariant holds | ✅ | Vaults copy all mutable params at `InitVault` time, never re-read the listing. |
| P10 — `RestockListing` cannot desync or silently overflow | ✅ (overflow message was opaque — **now fixed, see L2**) | No desync path; overflow now reverts with a clear message pre-write. |
| P11 — Gas headroom on modified/new receivers | ✅ | No deficits found beyond the one the tests already caught. |
| P12 — Idempotency tradeoff (quantity excluded from nonce) | ✅ | Confirmed correct design. |

---

## Adversarial Scenarios Tried (mental / static)

| Scenario | Expected | Verdict |
|---|---|---|
| Buy `quantity = 0` | Reject | ✅ |
| Buy `qty = uint64_max` with small stock | Reject | ✅ |
| `RestockListing` from non-seller | Reject | ✅ |
| `UpdateProtocolAddrs` from seller | Reject (owner-only) | ✅ |
| Force bounce on vault deploy | Supply restored, buyer refunded | ✅ |
| `minOrderQty = 0` | Normalizes to 1 | ✅ |
| `maxOrderQty = 0` | Uncapped | ✅ |
| `maxOrderQty = remainingSupply` | Exact-edge buy allowed | ✅ |

---

## Final Recommendation

**GO with fixes** — address L1 and L2 before the mainnet redeploy. Both are
single-line changes with no architectural impact. No Critical, High, or
Medium findings.

---

## Addendum — fixes applied (2026-09-05)

Both Low findings fixed on `feat/v2-usdt-jetton-escrow`, with new regression
tests covering exactly the scenario each finding described:

- **L1** — `UpdateListingParams` now calls the same `resolveWindow()` used by
  `ConfigureListing`/`InitVault` on every window field unconditionally (its
  "0 ⇒ keep current value" behavior makes this equivalent to the old
  if-guarded assignment when no change is requested, and it now reverts
  immediately — visible in the same transaction the DAO signs — instead of
  surfacing later as a stream of bounced `CreateListing`s).
  Tests: `MarketplaceFactory.spec.ts` #38 (rejects out-of-range, state
  unchanged, a subsequent `CreateListing` is unaffected), #39 (accepts
  in-range, flows into a new listing).
- **L2** — `RestockListing` now has an explicit
  `require(initialSupply + addSupply <= MaxUint64, "Restock overflow")`
  before the addition. Test: `MarketplaceListing.spec.ts` #21b (rejects an
  overflowing restock, `initialSupply` unchanged; accepts one landing exactly
  on the `uint64` ceiling).

`npm run build:v3` clean; `npm test` → **15 suites / 255 pass** (was 252).

The five Informational items were reviewed and dispositioned individually
above — none required a code change.
