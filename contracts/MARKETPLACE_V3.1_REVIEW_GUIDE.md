# Marketplace V3.1 — reviewer's guide

For whoever does the Phase 3 scoped review (`MARKETPLACE_V3.1_ROLLOUT.md`).
This is the *how to review it* — a sequence to work through, not a restatement
of the upgrade doc. Expect **half a day to a day** for a thorough pass.

## 0. Scope — read this before anything else

**In scope:** the V3.1 diff only — `marketplace_listing.tact`,
`marketplace_factory.tact`, the window-seeding parts of `escrow_oracle_vault.tact`.

**Out of scope — don't spend time re-deriving these:**
- The core V1 state machine (deposit → settle/dispute → withdraw) — externally
  audited August 2026, **unchanged** by this diff except for reading seeded
  windows instead of consts (that plumbing IS in scope; the state machine logic
  around it is not).
- The oracle/DON signature verification path (`OracleRegistry`) — unchanged.
- Frontend code and the backend API's `ton_proof` auth — a separate, already-
  shipped hardening (`garantor-backend@ebd92ab`), unrelated to this contract
  diff. FYI only.
- Deploy tooling (`deployGuard.ts` etc.) — not a contract-correctness concern.

**What's at stake:** this gates a mainnet factory redeploy for a live,
funds-holding escrow marketplace. Your sign-off is the last check before that
happens.

**Deliverable expected back** (see §5) — a written findings list by severity,
plus an explicit **go / go-with-fixes / no-go** recommendation for the mainnet
redeploy.

---

## 1. Setup

```bash
git clone https://github.com/Bennston/garantor-dao-escrow.git
cd garantor-dao-escrow
git checkout feat/v2-usdt-jetton-escrow    # PR #1 is already merged into this
npm install
npm run build:v3                            # OracleRegistry, EscrowOracleVault, MarketplaceListing, MarketplaceFactory
npm test                                    # expect: 15 suites / 252 pass
```

If `npm test` doesn't come back 15/252, stop and flag that before reviewing
anything else — the baseline you're reviewing against has to be the one that's
actually green.

## 2. Reading order

1. `MARKETPLACE_V3.1_UPGRADE.md` — full rationale + schema diff. Don't skim;
   the "why" behind each field matters for judging whether the guard around it
   is sufficient.
2. The isolated diff, read once top-to-bottom with no note-taking, just to get
   oriented:
   ```bash
   git diff cf9ebef..31daf73 -- 'contracts/*.tact'
   ```
   (`cf9ebef` = last commit before the V3.1 work started; `31daf73` includes
   the gas-bump fix the test suite forced — see P11 below.)
3. Then the three tiers below, **reading the full file for each contract**, not
   just the diff hunks — the new code interacts with the whole state machine
   (e.g. a seeded window is read in four different places in the vault).

---

## 3. Tier-by-tier checklist

For each property: where to look, how you'd try to break it, and which
existing test (if any) covers it — so you can judge whether that coverage is
actually sufficient or you should write your own adversarial case.

### Tier 1 — quantity math & supply accounting

- [ ] **P1 — no underflow.** `remainingSupply -= qty` in `PurchaseListing` is
  guarded by `require(qty <= self.remainingSupply)` immediately before it.
  Confirm there's no path (multi-message, bounce ordering) where two purchases
  could both pass the check against a stale read before either commits — TVM
  processes a contract's messages strictly sequentially, so this shouldn't be
  a real TOCTOU window, but confirm that assumption explicitly rather than
  taking it on faith. *Covered by:* test #6 (insufficient supply), #8/#9 (bounce restore).
- [ ] **P2 — no overflow in `tradeValue = pricePerUnit * quantity`.**
  `pricePerUnit` is capped at `MaxTradeValue` (1e17) both at `ConfigureListing`
  and `UpdatePrice`; `quantity` is bounded by `remainingSupply` (uint64, max
  ~1.8e19). Work out the worst-case product yourself (~1.8e36) against the
  257-bit `Int` ceiling (~7.7e76) — confirm the multiplication itself can't
  silently truncate *before* `require(tradeValue <= MaxTradeValue)` catches it.
  *Covered by:* test #7 (rejects over-`MaxTradeValue`).
- [ ] **P3 — bounce restores exactly `qty`, capped at `initialSupply`.**
  Read `bounced(msg: Slice)` end to end — `pendingQty` lookup, the
  `min(remaining + qty, initialSupply)` cap, cleanup of all three pending maps.
  *Covered by:* test #8, #9.
- [ ] **P4 — MOQ/cap boundary operators.** Is `qty >= minOrderQty` and
  `qty <= maxOrderQty` (inclusive both ends) actually what's in the code, not
  an off-by-one? *Covered by:* test #5 (exact-boundary purchase).

### Tier 2 — parameterized protocol values

- [ ] **P5 — window clamping.** `resolveWindow` (listing) and `_windowOr`
  (vault) both enforce `[300, 31_536_000]` seconds. Two separate questions:
  (a) is the clamp itself correctly applied everywhere a window is seeded —
  grep every `ConfigureListing`/`InitVault` field assignment; (b) is a
  **5-minute floor actually a safe business minimum** for a real dispute/
  objection window, or should it be higher? That second one is a judgment
  call, not a code bug — flag it as a discussion point either way.
- [ ] **P6 — percent bounds stay in sync.** `guaranteePercent` (1–20) and
  `commissionPercent` (0–10) are checked in `ConfigureListing`; confirm
  `UpdateListingParams` on the factory enforces the *identical* bounds, so a
  future factory param update can't drift a new listing out of range.
- [ ] **P7 — the `commissionPercent: 255` sentinel.** Since the real field is
  bounded ≤10, 255 is unambiguous as "leave unchanged" — confirm no code path
  could ever legitimately try to *set* commissionPercent to 255 expecting it
  to take effect (there isn't one; just verify).

### Tier 3 — listing mutability

- [ ] **P8 — every Tier-3 receiver's auth check is first, and correct.**
  `UpdatePrice` / `RestockListing` / `UpdateAgreementCID` → `sender() ==
  self.seller` (not `self.dao`, not the factory). `UpdateProtocolAddrs` →
  `self.requireOwner()`. Confirm the auth `require` is the *first* statement
  in each receiver — no state read/write happens before it.
- [ ] **P9 — "future purchases only" actually holds.** `InitVault` copies
  `pricePerUnit`/`agreementCID`/windows into the *vault's own* state at spawn
  time. Confirm there's no path where a vault re-reads these from the listing
  later (there isn't — the vault never messages the listing after `InitVault`
  except `VaultInitOk`/bounce). *Covered by:* test #17 (price), #23 (agreementCID).
- [ ] **P10 — `RestockListing` can't desync `remainingSupply`/`initialSupply`
  or overflow `uint64`.** Try (mentally or as a test) an `addSupply` near
  `uint64` max, applied repeatedly — does Tact's `Int as uint64` serialization
  fail loudly on overflow, or wrap silently? If you're not certain, write a
  test that pushes it and see. *Covered (normal case) by:* test #20.

### Cross-cutting

- [ ] **P11 — gas headroom on every modified/new receiver**, not just the one
  the test suite already found (`ListingConfigured` ack bumped 0.01→0.03 TON
  after hitting exit `-14`). Check `PurchaseListing`, `RestockListing`,
  `UpdatePrice`, `UpdateAgreementCID`, `UpdateProtocolAddrs`,
  `UpdateListingParams` all carry generous margin over their actual compute +
  onward sends. The bump that was needed is a signal to look harder here, not
  evidence the rest is fine.
- [ ] **P12 — idempotency tradeoff.** The purchase nonce dedup deliberately
  excludes `quantity` — a retried nonce with a *different* quantity is
  rejected outright (`require(!seenNonce.exists(...))`), never silently
  reused with the old quantity. Confirm that's actually true in the code and
  that you agree it's the right tradeoff (vs., say, allowing the retry to
  update the quantity).

---

## 4. Things to actually try, not just read

Fill these in as new Jest cases against the sandbox (`tests/MarketplaceListing.spec.ts`
already has the fixtures — `configure()`, `purchase()`, `openVault()`) or drive
them by hand:

- [ ] Buy with `quantity = 0`.
- [ ] Buy with `quantity` near `uint64` max while `remainingSupply` is small.
- [ ] `RestockListing` from a non-seller wallet.
- [ ] `UpdateProtocolAddrs` from the seller (must fail — owner-only).
- [ ] Force the bounce path deliberately (starve the forwarded gas so
  `InitVault` itself reverts) and confirm `remainingSupply`/`pendingCount`
  fully recover.
- [ ] MOQ boundary: `minOrderQty = 0` (should normalize to 1) vs `= 1` explicit.
- [ ] Cap boundary: `maxOrderQty = 0` (uncapped) vs `maxOrderQty ==
  remainingSupply` (exact edge, should still allow buying it all).

If any of these turns up something the existing 43 V3.1 tests don't already
cover, that's worth a finding on its own (coverage gap), even if the behavior
turns out correct.

---

## 5. What to send back

- **Findings list**, each tagged **Critical / High / Medium / Low /
  Informational**, with a file:line reference.
- For every Critical/High: a **concrete scenario** — specific inputs and the
  bad outcome they produce, not just "this looks risky."
- An explicit **recommendation**: safe to redeploy as-is / safe once findings
  X, Y are fixed / not safe, needs rework.
- Anything from §3's judgment calls (P5's window floor, P12's idempotency
  tradeoff) you want a second opinion on — flag those as discussion items
  even if you don't consider them bugs.

Findings get fixed as new commits on `feat/v2-usdt-jetton-escrow`, then
`npm test` re-run before the mainnet redeploy proceeds (Phase 4).
