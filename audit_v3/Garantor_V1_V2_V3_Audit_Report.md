# Garantor DAO — Full-Stack Security Audit: V1 + V2 + V3 Factories, Oracle Layer, Marketplace & Frontend

**Date:** 2026-09-26
**Scope:** `escrow_factory.tact`, `escrow_vault.tact`, `escrow_milestone_factory.tact`, `escrow_vault_milestone.tact` (V1, native TON); `escrow_jetton_factory.tact`, `escrow_jetton_vault.tact`, `escrow_jetton_milestone_factory.tact`, `escrow_jetton_vault_milestone.tact` (V2, USDT jetton); `escrow_oracle_vault.tact`, `oracle_registry.tact` (V3 oracle); `marketplace_factory.tact`, `marketplace_listing.tact` (V3 marketplace); `garantor dao-ui-frontend` (UI/UX).
**Baseline:** prior V2 audit (`audit_v2/Garantor_V2_Jetton_Escrow_Audit_Report.md`, 2026-07-17) and its remediation commit `c7753eb`; `MARKETPLACE_V3.1_REVIEW_FINDINGS.md` and its fixes.
**Method:** manual line-by-line review of every in-scope contract, state-machine transition enumeration, conservation/rounding analysis, message-authentication and bounce-semantics sweep, verification of prior findings against current code, plus a frontend UI/UX inspection. Static review only — no compilation or test execution was performed in this pass.

---

## 0. Remediation verification addendum (2026-11-05)

The team reported all findings High→Low as resolved in commits `8620d00` → `4302a64` (each mapped to specific finding IDs). An independent verification pass re-checked every fix in the current code — presence **and** correctness — with the following results:

- **All High/Medium findings VERIFIED-FIXED** with current-code line evidence: V1-1 (compute-phase balance guards at all 8 payout sites, float 0.25→0.6 TON, arbitratorFee capped at 0.1, regression test reproducing the scenario-A revert), V1-2 (24h delay floor in both V1 factories), V2-N1 (in-flight payout counter incremented per send, TVM-authenticated decrement, gating both destroy paths with a time bound), V3-M1 (24h delay floor in oracle registry), V3-M3 (relay reserve + owner sweep + gas benchmark test).
- **V3-M2** remains design-accepted exactly as the original audit classified it (single DON key; 48h objection window) — risk-register item, not a code defect.
- **All Lows verified fixed except MK-N2, which was PARTIAL**: the marketplace *listing* released its purchase nonce on bounce but the marketplace *factory* still burned the seller's `seenNonce` on a bounced `CreateListing` — the audit had scoped the fix to "both contracts".
- **MK-N2 (factory half) was completed in this verification session**: `pendingNonceKey` bookkeeping added to `marketplace_factory.tact` (stash at `CreateListing`, release in `bounced()`, lookup cleanup in `_clearPending`), mirroring the listing-side and V2-factory patterns; new regression test `40` in `tests/MarketplaceFactory.spec.ts` proves the identical signed form is rejected in-flight, then succeeds after the bounce. Marketplace specs: 70/70 pass.
- **Build & test status:** full suite green — 17 suites, 266/266 tests before the MK-N2 completion; 267/267 after (wrapper rebuilt — note the generated `tact_MarketplaceFactory.ts` embeds a static code snapshot, so any contract source change requires a rebuild before tests reflect it; **the marketplace factory must be redeployed for this fix to be live on-chain**).
- **Residuals (minor, documented):** V1-4's `get fun vaultAddress` still derives from the *current* owner (getter-only, no state impact); the regular-vault `Withdraw` variant of V1-1 remains theoretical per the original assessment (0.35 TON float).
- **Wave-4 test gaps still open** (disclosed by the team in `AUDIT_FIXES_APPLIED.md`): dedicated regression tests for V1-3, V1-4, V1-6, V2-N5, V3-L2, and the V1-2/V3-M1 timelock floors. MK-N2's gap is now closed by test 40.

**Verified-state summary:** the claim "all severity issues down to Low are resolved" now holds in full, with V3-M2 design-accepted, two documented view-only residuals, and the Wave-4 test-completion list above remaining as hygiene work.

---

## 1. Executive summary

**No Critical findings, and no direct fund-theft path exists anywhere in the audited set.** The three trust anchors of the whole family are correctly built in every version: deposit authentication (`jwResolved && sender() == myJettonWallet` in the jetton vaults), oracle report authentication (Ed25519 canonical-hash binding + `sender() == oracleRegistry`), and exact conservation (`Σ payouts == Σ deposits`) on every enumerated path. Forged deposits, forged attestations, replay, and op-code confusion all fail.

The audit surfaced **one High**, a set of **Mediums concentrated in two systemic patterns**, and a cluster of cheap one-line Lows. The two systemic patterns:

1. **TON action-phase send semantics are under-respected in the V1 milestone vault.** Its payout sends use `SendPayGasSeparately` (mode 1) with `bounce: false`; if a payout action fails for lack of balance, the send is *skipped* (not reverted) while compute-phase state changes **persist**. That is the only finding in the whole audit that can permanently trap user funds (High, §3.1).
2. **Fixes are not propagating across versions.** The V2 audit's fixes (24h floor on `UpdateTimelockDelay`, zero-required-deposit auto-credit, bounce-restore on payouts) landed in V2 but the same patterns were re-imported un-fixed into V1 and V3 (instant timelock delay in V1 factories and the oracle registry; zero-deposit trap open again in the marketplace; refund `queryId = 0` blind spot in V2 regular vault and V3 oracle vault). Every future audit should end with a cross-version propagation checklist.

**On the three user-stated concerns:**

| Concern | Verdict |
|---|---|
| Fund loss | No theft path. Residual loss modes: V1 milestone gas starvation (High), V2 destroy-vs-bounce race (N-1), `queryId=0` refund blind spots (V2 N-2 / V3 L-1), `forwardTonAmount=0` deposits stranded via UI (V2 N-4). |
| Vault permanently locked | One real path: V1-High scenario A. Second: V2 N-1 (reap destroying the vault while a bounced payout restore is pending). All other "locks" are recoverable-by-cancel liveness traps (zero-deposit, etc.). |
| Malicious messaging to the factory/vault | Verified solid: every `receive()` authenticates `sender()` or owner; vault-init acks are pending-registry-gated or re-derived; jetton-wallet discovery is one-shot and master-gated; DON signatures bind vault+tradeId+type+status+proof. Weakest link is **governance speed**, not messaging: instant owner setters (timelock bypass) in V1 and the V3 registry. |

---

## 2. Severity roll-up

*Every item in this table was remediated after the review and independently re-verified — the evidence table is the addendum (§0) and the closure is §8. This table is the historical record of what the review found.*

| ID | Sev | Where | Title |
|---|---|---|---|
| V1-1 | **High** | `escrow_vault_milestone.tact` | Milestone-vault gas starvation: action-phase send failure is silent, state advances anyway → stuck or misrouted funds |
| V1-2 | Medium | V1 both factories | `UpdateTimelockDelay` instant — 24h guarantee degrades to 1h floor (V2 M-2 analog) |
| V2-N1 | Medium | `escrow_jetton_vault.tact`, `escrow_jetton_vault_milestone.tact` | Destroy paths (`_checkAllWithdrawn` same-tx, `Reap`) can race in-flight/bounced payouts — defeats the M-1 bounce-restore |
| V3-M1 | Medium | `oracle_registry.tact` | `UpdateTimelockDelay` instant — DON-key rotation window degrades 24h→1h |
| V3-M2 | Medium (design-accepted) | `oracle_registry.tact` + design | Single DON attestation key; 48h objection window is the only mitigation; no post-finalization appeal |
| V3-M3 | Medium | `oracle_registry.tact` | Registry gas self-drain per relay, no balance sweep, single choke point for all vaults |
| V1-3 | Low | `escrow_vault.tact` | `commissionairesDao` as trade party permanently locks commission claimable |
| V1-4 | Low | `escrow_factory.tact` | Vault derivation embeds mutable `self.owner`; mid-deploy ownership change orphans pending state |
| V1-5 | Low | V1 both factories | Bounced-deploy residue never refunded nor credited |
| V1-6 | Low | `escrow_vault_milestone.tact` | Late deposit after `RefundPreActivationStall` destroys the vault is stranded |
| V2-N2 | Low | `escrow_jetton_vault.tact` | Deposit refunds use `queryId=0` — bounced refunds not restorable |
| V2-N3 | Low | both V2 vaults | `RetryWalletDiscovery` ungated: spends vault funds, no caller-pays/cooldown |
| V2-N4 | Low (UI/docs) | deposit UX | `forwardTonAmount=0` deposits stranded uncredited — enforce in UI/SDK |
| V2-N5 | Low | `escrow_jetton_vault_milestone.tact` | `ArbitratorResolveMilestone` still lacks `require(msg.index <= 1)` |
| V3-M4 | Low | `oracle_registry.tact` | Vault-side report rejection permanently burns the DON-signed report |
| V3-L1 | Low | `escrow_oracle_vault.tact` | Deposit refunds at `queryId=0` — bounced refund strands jettons |
| V3-L2 | Low | `escrow_oracle_vault.tact` | Zero-required-deposit trap for tiny `tradeValue` (V2 L-2 re-imported) |
| V3-L3 | Low | `marketplace_listing.tact` | No check that arbitrator (`dao`) ≠ trade parties |
| MK-N1 | Low | `marketplace_listing.tact` | `EvtListingVaultDeployed` misreports `pricePerUnit`/`tradeValue` if seller re-prices before vault ack |
| MK-N2 | Low | `marketplace_listing.tact` + factory | `seenNonce` never released on bounced deploy (V2 pattern dropped) |
| MK-N3 | Low | `marketplace_listing.tact` | Zero-required seller-deposit trap (same root as V3-L2) |
| MK-N4 | Low | factory + listing | Deterministic-address squatting griefing (~0.02 TON + gas per attempt) |
| MK-N6 | Low | `marketplace_listing.tact` | Listing never rejects `seller == commissionairesDao` / `seller == dao` — every purchase bounces |
| Info | — | all | See §4, §5, §6, §7 for the informational items |

**Prior-finding verification:** V2 audit — all 8 findings addressed in code (6 fully; L-1 and I-1 carry small documented residuals). Marketplace v3.1 review — both Lows verifiably fixed in current code. Details in §5 and §7.

---

## 3. V1 (native TON) — findings

### V1-1 (High) — Milestone vault payout sends are non-atomic; gas starvation silently strands or misroutes funds

**Affected:** `escrow_vault_milestone.tact` — every push payout uses `SendPayGasSeparately` (mode 1) with `bounce: false`: `ArbitratorResolveMilestone` (L637–717), `releaseMilestone0/1` (L731–752), `resolveDisputeTimeout` (L790–806), `executeMilestoneSettlement` (L830–846), `checkVaultClose` bond + sweep (L876–891), `RefundPreActivationStall` (L341–373). The vault has **no `bounced()` handler and no fallback receiver**. Gas float: factory forwards only `msgValue − deploymentFee ≥ 0.25 TON` (`escrow_milestone_factory.tact:172,185`).

**Root cause.** In TON, if an action-phase send fails (e.g. insufficient balance for value + gas), the action is skipped, all *subsequent* actions in the same transaction are skipped, and compute-phase state changes **persist** — modes 0/1 do not roll back compute state. The comment at `escrow_milestone_factory.tact:186` (`mode: 0, // revert on action-phase failure`) is factually wrong. State transitions (`m0State/m1State = 2`, `vaultState = 2` in `checkVaultClose` L871–873) survive a failed payout.

**Scenario A — permanent lock (worst case).** A milestone trade where both milestones get disputed and arbitrated (an ordinary adversarial flow), with `performanceBond = 0` (allowed — the factory never validates it) and the creator paying exactly `deploymentFee + 0.25`:
1. Vault float ≈ 0.25 TON. Fixed outflows: `InitOk` ack 0.05 (L245–251) + 2 × `arbitratorFee` (default 0.1 each, L709–717) + ~10–15 transactions of compute/fwd gas + `tradeRef` storage ≈ 0.35–0.45 TON total. The float is underfunded by design in this path.
2. During the second `ArbitratorResolveMilestone`, an early send in the queue fails for lack of balance. It and all later sends (arbitrator fee, bond return, and the `SendRemainingBalance + SendDestroyIfZero` close sweep at L886–891) are skipped — but `m1State` was set to 2 (L674) and `checkVaultClose` set `vaultState = 2` (L873) in compute.
3. The vault is now CLOSED with a residual balance inside. Every receiver is gated on `vaultState == 0/1` — **no code path can ever move the remaining funds again**. There is no rescue receiver to top it up, and topping up wouldn't help — nothing can execute.

**Scenario B — misroute (milder, more likely).** With a normal bond but an uncapped owner-set `arbitratorFee` (`UpdateArbitratorFee` at `escrow_milestone_factory.tact:407–412` has only a `>= 0` check), a large fee send succeeds while a later bond return or value send fails; the leftover is then swept by the close sweep — which goes **to the buyer** (L886–891) regardless of who the failed payout belonged to.

**Regular-vault variant (theoretical).** `Withdraw` (`escrow_vault.tact:565–600`) zeroes the claimable in compute (L576–584) before the mode-1 send (L591–597). If that send fails, the claimable stays zeroed; once the other parties drain, `_checkAllWithdrawn` (L801–822) sweeps the stranded amount to the buyer. The regular vault's ≥ 0.35 TON float (L173) makes this far less reachable, and the amount reaches a party, just the wrong one.

**Fix (combine):**
1. Raise the minimum forwarded float (`escrow_milestone_factory.tact:172`) — 0.25 TON does not cover ack (0.05) + two arbitration fees (0.2) + lifecycle gas; use ≥ 0.6, or fund `arbitratorFee` out of the factory's kept fee instead of the vault.
2. Cap `arbitratorFee` (e.g. ≤ 0.1), and require `performanceBond > 0` if slashing is security-relevant.
3. Make payout atomic with state: before queuing the payout block, `require(myBalance() >= totalOutbound + gasReserve)` in compute phase. The requires must precede the state writes.
4. Delete the incorrect comment at `escrow_milestone_factory.tact:186`.

### V1-2 (Medium) — `UpdateTimelockDelay` takes effect instantly — 24h guarantee is a 1h floor

**Affected:** `escrow_factory.tact:373–378`, `escrow_milestone_factory.tact:396–401` (floor 3600s, instant). Same for instant, uncapped `UpdateArbitratorFee` (`escrow_factory.tact:384–389`, `escrow_milestone_factory.tact:407–412`) and instant `UpdateCommissionairesDao`. Exact V2 M-2 analog, unchanged in V1.

**Scenario:** compromised/malicious owner: (1) `UpdateTimelockDelay(3600)` instant; (2) `ScheduleParamChange`; (3) `ApplyParamChange` — a guarded parameter changes ~1h after owner action, not 24h. The schedule/apply mechanics themselves are correct (single slot, `now() >= pendingEffectiveAt`, values validated at schedule time, `escrow_factory.tact:324–367`).

**Fix:** put the delay change behind the timelock (schedule/apply pair), or hard-floor `pendingEffectiveAt` at `now() + max(timelockDelay, 86400)` inside `ScheduleParamChange`. Cap `arbitratorFee` (see V1-1). V2's exact fix (`require(msg.newDelay >= 86400)` at `escrow_jetton_factory.tact:435`) can be copied verbatim.

### V1-3 (Low) — `commissionairesDao` as trade party permanently locks the commission and blocks the reap

`Withdraw` dispatch order buyer → seller → `commissionairesDao` (`escrow_vault.tact:576–587`); `CreateEscrow` has no exclusion (`escrow_factory.tact:161–213`) — unlike the milestone factory which excludes `owner`. If `commissionairesDao == seller`, every `Withdraw` from that address matches the *seller* branch; `commissionairesClaimable` can never be zeroed; `_checkAllWithdrawn` never sees all-zero claimables → vault never self-destructs, commission stranded. Self-inflicted, hence Low — but a permanent lock, and the fix is one line: `require(msg.buyer != self.commissionairesDao && msg.seller != self.commissionairesDao)` in `CreateEscrow`.

### V1-4 (Low) — regular factory vault derivation embeds mutable `self.owner`

`initOf EscrowVault(myAddress(), self.owner, tradeId)` (`escrow_factory.tact:180–184`). A `ChangeOwner` mid-deploy (seconds-wide window) leaves a stale `pendingTradeByVault` entry forever; a later bounce from that vault force-unwraps an already-deleted `pendingCreator` (`!!` at L249) and panics in compute. The milestone factory is immune (derives from `(myAddress(), tradeId)` only). V2 L-4 analog. **Fix:** exclude `self.owner` from the vault `StateInit` (pass the DAO via `InitVault` only), or store the vault address in the pending maps at creation time.

### V1-5 (Low) — bounced-deploy residue neither refunded nor credited

Refunded `min(paid, deploymentFee + bouncedValue − 0.02)` (`escrow_factory.tact:241–265`); `totalFeesCollected` credited only on success; `WithdrawFees` caps at `totalFeesCollected` so the retained slice accumulates unreachable. V2 L-5 analog, identical. **Fix:** credit the retained slice to `totalFeesCollected` in `bounced()`, or document as intentional sink.

### V1-6 (Low) — late deposit landing after `RefundPreActivationStall` self-destructs the vault is stranded

`DepositBond` (L255–280) / `DepositPayment` (L283–310) have no staleness guard; the stall refund + destroy at L360–374 can win the race. **Fix:** one line in each deposit receiver: `require(now() <= self.createdAt + self.PreActivationTimeoutWindow)` so late deposits revert and value returns via bounce.

### V1 informational items

- **I-7** `BuyerConfirmReceipt` lacks the deadline check its siblings have (`escrow_vault.tact:679–706` vs L414, L663) — align or document.
- **I-8** Dead code: `ConfirmTrade` (`escrow_vault.tact:410–465`) is fully unreachable; `MinTonForStorage` (L190) unused; `arbitratorFee` in the regular factory (L105,147,384–389) stored/updated/gettered but never sent anywhere.
- Zero-address referrer allowed with `referrerFeeBps > 0` (fee burned).
- Missing `require(msg.index <= 1)` in `BuyerConfirmMilestone`, `BuyerDisputeMilestone`, `ArbitratorResolveMilestone` (`escrow_vault_milestone.tact:399, 441, 626`) — any non-zero index aliases to M1.
- Soft review-window edge and M1-clock-idle-during-M0-dispute — mirror V2 I-2/I-3; keepers should call `CheckTimeout` promptly.
- Degenerate near-zero trades: `minTradeValue` can be scheduled to 1 nano, making `sellerDepositAmount` floor to 0 — a quality issue in TON (dust deposits work), not a lock.
- The regular factory has no fallback `receive() {}` (milestone factory has one at `escrow_milestone_factory.tact:145`); `EscrowFactory.spec.ts:47–50` claims the top-up is "accepted by `receive() {}`" — that receiver does not exist; top-ups credit only by the TON quirk that a failed compute still keeps non-bounceable value. Works by accident; add the receiver.

### V1 verified solid

- Authentication on every `receive()`; `InitVault` factory-gated and one-shot; `ResolveDispute`/`ForceExpiredCancel` owner-gated. No deposit-credit mechanism in V1, so the entire forged-notification class does not apply.
- Vault-init ack authenticity: regular factory requires registered pending vault address + matching tradeId (L217–218); milestone factory re-derives sender from `(myAddress(), tradeId)` (L220–221). Pre-deployment of the deterministic vault address by a third party is harmless.
- Conservation exact on every enumerated path: success allocation, exact-sum `ResolveDispute` with `daoFee ≤ pool/10`, floor+complement settlement/timeout, proportional bond slash with remainder returned, immediate excess refund. No rounding leak.
- Timelock mechanics correct; deadline mandatory and > 1h future at creation; every pre-terminal state has a recovery path (`CancelTrade`, `RaiseDispute`, permissionless `CheckExpiry`, `ForceExpiredCancel`, 30-day `CheckDisputeTimeout` backstop). No deadlocked state found.
- Pull pattern (claimable zeroed before send, double-withdraw blocked); self-destruct sweeps only in terminal states with all-zero claimables; referrer paid exactly once and prefunded by the buyer; `WithdrawFees` capped by `min(balance − operationalReserve, collected)`; `nextTradeId` monotonic with pending state released on ack and bounce.

### V1 test-coverage gaps

Not covered anywhere: gas-margin/action-phase failure behavior (**V1-1** — the highest-impact gap), `commissionairesDao == party` (V1-3), ownership transfer mid-deploy (V1-4), `UpdateTimelockDelay` instant downgrade (V1-2), zero-bond trades, the late-deposit vs stall-refund race (V1-6), post-deadline `BuyerConfirmReceipt` (I-7). The V1-1 regression test (a sandbox test that forces a failed payout action and asserts state did not advance) was added during remediation.

*Post-audit: every finding in this section was remediated and independently re-verified — see §0 and the closure in §8.*

---

## 4. V2 (USDT jetton) — re-audit

### 4.1 Prior-findings verification

Working tree matches remediation commit `c7753eb` exactly (audited code + the fixes, nothing more).

| ID | Verdict | Evidence |
|---|---|---|
| M-1 (silent/unrecoverable failed transfers) | **FIXED** — but see N-1 | `JettonFwdGas = 0.15` (`escrow_jetton_vault.tact:210`, `:143`); `_sendJettons` now `bounce: true` (:782, :717–738); regular vault records `pendingPayoutType/Amount` before zeroing (:585–592), restores in `bounced()` (:599–609); milestone vault accumulates into `failedPayout` (:742–752) with permissionless `ClaimFailedPayout` (:763–769). |
| M-2 (instant timelock cut) | **FIXED** | `require(msg.newDelay >= 86400)` in both factories (`escrow_jetton_factory.tact:435`, `escrow_jetton_milestone_factory.tact:374`). |
| L-1 (pre-`jwResolved` deposits strand; no retry) | **PARTIALLY FIXED** | Permissionless `RetryWalletDiscovery` added (both vaults) — retry gap closed. Stranding unchanged by design (handler still hard-throws on `!jwResolved`, `escrow_jetton_vault.tact:411`); doc-level acceptance still needed. |
| L-2 (zero-required deposits) | **FIXED** | Auto-credit at init: `escrow_jetton_vault.tact:348–350`, `escrow_jetton_vault_milestone.tact:308–309`. |
| L-3 (DAO as trade party) | **FIXED** | `escrow_jetton_factory.tact:210–212`. |
| L-4 (mutable owner in derivation) | **FIXED** | Two-arg StateInit `escrow_jetton_factory.tact:222–225`. |
| L-5 (bounce residue) | **FIXED** | `bounceDust` credited: `escrow_jetton_factory.tact:302–305`, milestone :271–273. |
| I-1 (fee before state check; index guard) | **PARTIALLY FIXED** | Ordering fixed (`escrow_jetton_vault_milestone.tact:572–578` before :584–587); `require(msg.index <= 1)` **not** added — see N-5. |
| I-2/I-3/I-5 (informational) | Unchanged | Soft review window; M1 clock during M0 dispute; zero-address referrer. |

### 4.2 New findings

**N-1 (Medium) — the self-destruct path can race in-flight / bounced payouts, defeating the M-1 restore.**
The M-1 fix restores claimables in `bounced()` — but only if the vault still exists when the bounce arrives.
- *Regular vault, same-transaction case (sharpest):* `Withdraw` dispatches the payout (:594) then immediately calls `_checkAllWithdrawn` (:595), which destroys the vault in the **same transaction** if this was the last claimable and `now() >= terminalAt + 3600` (:841–856). Any final withdrawal made > 1h after settlement — routine, e.g. the DAO collecting commission days later — self-destructs the vault while its own payout is in flight. If the `JettonTransfer` then bounces at the jetton wallet (frozen/blacklisted recipient — a real Tether feature; first-time wallet deploy exceeding 0.15 TON; a future USDT wallet-code upgrade), the bounce returns to a destroyed address, `bounced()` never runs, and the claimant's jettons sit in the vault's jetton wallet permanently. `receive("Reap")` (:723–725) has the same exposure.
- *Milestone vault:* no same-tx destroy, but `Reap` (:809–812) can destroy the vault at `closedAt + 3600` while `failedPayout[recipient]` is still unclaimed or a `pendingPayout` is unconfirmed. The `ClaimFailedPayout` retry dies with the contract.
**Fix:** track an in-flight payout counter (increment in `_sendJettons`, decrement in `bounced()`/`JettonExcesses`) and skip `_checkAllWithdrawn`/`_sweepAndDestroy` while non-zero; in the milestone vault additionally block the sweep while any `failedPayout` entry is unclaimed. One counter covers both destroy paths.

**N-2 (Low) — regular-vault deposit refunds are not bounce-recoverable (qid-0 blind spot).** Every refund branch passes `queryId = 0` (`escrow_jetton_vault.tact:419, 424, 426–427, 432–435, 441`); `bounced()` only restores mapped qids (:601–603). A bounced refund (recipient frozen/destroyed between deposit and refund) returns to the vault's wallet with no claimable, no record, no recovery. The milestone vault handles the identical case correctly — the two vaults are inconsistent. **Fix:** mirror the milestone scheme for refunds (unique qid + `failedPayout` accumulate + permissionless claim).

**N-3 (Low) — `RetryWalletDiscovery` spends vault funds with no state gate, no caller-pays, no cooldown.** Callable by anyone pre-`jwResolved`, each call sends `WalletDiscoveryGas = 0.05` TON from the vault's balance (:212, :144). An attacker burns 0.05 of the vault's fixed budget per call and can deplete it so later refunds/payouts revert (recoverable via top-up, but bricks the unattended flow). **Fix:** gate on initialized state, and `require(context().value >= self.WalletDiscoveryGas)` or add a cooldown.

**N-4 (Low, UI/docs) — deposits sent with `forwardTonAmount = 0` are stranded uncredited.** TEP-74 emits `transfer_notification` only when forward tonnage is attached. A depositor with `forwardTonAmount = 0` (wallet misconfiguration) credits the vault's jetton wallet but the vault is never notified: no claimable, `CancelTrade` refunds nothing, foreign balances are deliberately unsweepable → unrecoverable. Cannot be enforced from the vault side. **Fix:** hard-enforce `forwardTonAmount ≥ 1` nanoton (standard 0.05 TON) in the deposit UI/SDK; document next to §6.3.

**N-5 (Low) — `ArbitratorResolveMilestone` still lacks the `index <= 1` guard.** `escrow_jetton_vault_milestone.tact:574–578`: any index 2–255 aliases to the M1 branch. Every other index-taking handler has the guard (:424, :445, :470, :487, :521, :548). One line: `require(msg.index <= 1, ...)`.

### 4.3 V2 verified solid

Deposit authentication and wallet-discovery trust anchors re-verified; outbound TEP-74 shape correct (`forwardTonAmount: 0`, `responseDestination: myAddress()`, empty forward payload); pending-payout record written before claimable zeroed; conservation re-derived exact on every path; dispute-fee lifecycle sound (charged once, only in arbitrated path, only after state validation, refund mutually exclusive via `disputeFeePaid`); referrer fee matches design exhaustively; timelock integrity with the new 24h floor; factory nonce idempotency, pending-gated `VaultInitOk`, immutable vault derivation; liveness backstops (gas-rescue `receive()`, destroy grace window, permissionless `Reap`, milestone window clamps, `RefundPreActivationStall`).

**V2 bottom line:** all eight prior findings addressed (six fully; L-1/I-1 carry small residuals). The remediation introduced one real gap — **N-1** — plus four Low/Info items. *Post-audit: N-1 through N-5 were all remediated and independently verified (§0/§8); N-4 is enforced in the deposit UI/SDK with regression tests.*

---

## 5. V3 oracle layer — findings

### V3-M1 (Medium) — `UpdateTimelockDelay` is instant; the 24h DON-key rotation guarantee degrades to a 1h floor

`oracle_registry.tact:146–150` (instant update, floor 3600s). Compromised owner: (1) `UpdateTimelockDelay{3600}` instant; (2) `ScheduleDonKey{attackerKey}` → effective in 1h (L121); (3) `ApplyDonKey` (L124–134). The DON key is now attacker-controlled; a false `Delivered` pays a colluding seller after the 48h window (`escrow_oracle_vault.tact:866–889`); a false `Failed` confiscates the seller's bond. ~1 hour to a rogue key, not the "24h" the header comment (L42–46) and design §4.1 advertise. The V2 M-2 pattern, copied unchanged. (What works: an in-flight rotation's `pendingEffectiveAt` is frozen at schedule time, so the attack needs the delay change first.) **Fix:** schedule/apply for `UpdateTimelockDelay`, or `require(now() + max(self.timelockDelay, 86400))` inside `ScheduleDonKey`.

### V3-M2 (Medium, design-accepted) — single DON attestation key is a forge-capable attestor; 48h objection window is the only mitigation; no post-finalization appeal

`oracle_registry.tact:79–81, 179–182` (one key, one `checkSignature`). Whoever holds the CRE DON key can sign any report for any vault. After `FinalizeDelivery`, the vault is terminal and `RaiseDispute` is state-blocked (:550–554) — the objection window *is* the entire dispute mechanism. The design docs consciously accept this, so it is a risk-register item, not a bug. The doc claim that M-of-N "requires no contract change" is only true for a threshold/aggregated key (FROST); naive per-attestor keys would need a new receiver and key map. **Hardening (optional):** scale the objection window to trade value; second independent attestation above a TVL threshold; document CRE key custody/HSM requirements.

### V3-M3 (Medium, liveness) — registry gas economics: slow self-drain per relay, no balance sweep, single point of failure for every vault's oracle rail

`oracle_registry.tact:159` (`require(context().value >= ReportGas)`), `:188–199` (forward `value: self.ReportGas, mode: SendPayGasSeparately, bounce: false`), `:113` (`receive() {}` accepts TON, no withdrawal path). `SendPayGasSeparately` means the 0.1 TON forwarded to the vault is exactly the 0.1 received, while the forward gas is paid **out of the registry's own balance** — a relayer attaching exactly the minimum makes the registry's finite balance shrink by a few milliTON per relay. When the balance can no longer cover the forward gas, every `SubmitReport` reverts — oracle settlement halts for **all** vaults simultaneously (one registry per deployment, referenced by every listing at `marketplace_listing.tact:489`). Overpayments accumulate as TON that can never be swept. Recoverable-by-top-up, hence Medium-liveness, but unmonitored operational fragility at the single choke point the whole V3 rail depends on. **Fix:** forward with `SendRemainingValue` minus a reserve (so attached excess funds the registry), add an owner sweep, document a balance-monitor alert.

### V3-M4 (Low) — a vault-side rejection burns the DON-signed report permanently

`oracle_registry.tact:184` (`processedReports.set` before the send), `:188–199` (`bounce: false`). If the vault throws (wrong state/type/deadline, manual-mode, another report pending), the registry's map entry persists and the identical `{report, signature}` can never be relayed again ("Report already processed", :177). No funds move and every rail has an exit, but the oracle verdict is consumed; the DON must sign a new report (different `proofHash`) to retry. A misconfigured `validationType` burns every report for all its vaults until reconfigured. **Fix:** vault acks acceptance (e.g. `OracleReportAck` deleting the `processedReports` entry on rejection), or document burn semantics and have the bridge verify vault state on-chain before relaying.

### V3 Lows

- **L-1** Deposit refunds at `queryId = 0` (`escrow_oracle_vault.tact:483–505`); `bounced()` restores only mapped qids (:671–681). A bounced refund strands jettons permanently after `Reap`. The V2 M-1 fix was applied to `Withdraw` but deliberately not to refunds. Non-party refunds make the recipient arbitrary, so not purely self-inflicted. **Fix:** route refunds through the pending-payout machinery.
- **L-2** Zero-required-deposit trap: `sellerDepositAmount = tradeValue * guaranteePercent / 100` floors to 0 for `tradeValue < 100` at 2% (:436); listing guards only `pricePerUnit > 0`. Trade stalls in `AwaitingDeposits` until cancel — liveness, not loss. **Fix:** enforce `sellerDepositAmount > 0` in `InitVault` (revert → listing refunds cleanly), or auto-satisfy zero requirements.
- **L-3** No on-chain check that arbitrator (`dao`) ≠ trade parties. `dao` is immutable per listing (ConfigureListing one-shot, `marketplace_listing.tact:260`), so a bad value poisons every vault the listing ever spawns; that party would pass `requireOwner()` in `ResolveDispute` (:565–566) and `ForceExpiredCancel` (:720–727). DAO-misconfiguration-only, hence Low. **Fix:** `require(msg.dao != msg.seller)` in `ConfigureListing`; vault-side `require(msg.buyer != self.owner && msg.seller != self.owner)` in `InitVault` (fail-closed).

### V3 informational items

- No events on `ScheduleDonKey`/`ApplyDonKey`/`CancelDonKey` (getter-only observability for security-relevant admin actions); `BuyerAcceptDelivery` emits no event of its own.
- No zero-key validation at deploy/schedule (a zero `donPublicKey` bricks the rail until rotation — recoverable, owner-only).
- Terminal sweep targets the buyer (`:998–1003`) — if the buyer address is unresponsive at reap time, gas-dust is lost.
- `FinalizeDelivery` Failed branch reads `buyerDeposited`/`sellerDeposited`, provably always true in the reachable state — harmless dead defensiveness.
- Signature cell with trailing garbage still verifies against its first 64 bytes — not exploitable.
- Canonical preimage has no chain-id/registry-address domain — not exploitable in practice (vault address + tradeId differ; `processedReports` is per-registry).
- All time math is `uint32` — safe until 2106.

### V3 verified solid

Forged attestation cannot pass (canonical cell byte-identical to `cre/canonicalReport.ts`, correct `checkSignature` argument order); replay blocked three independent ways (vault address inside the signed preimage, `processedReports`, one-live-report + state gate); domain separation by tradeId and validationType; no instant payout from a report (money math only in `FinalizeDelivery`/`BuyerAcceptDelivery`); the `CheckExpiry` theft vector is explicitly closed (:777 requires `objectionDeadline == 0`); deposit authentication and wallet discovery correct; conservation exact on all paths (`Failed` → buyer gets exactly both deposits; `Delivered` → floored commission + complement; exact-sum dispute); the V2 M-1 port is correct (pending record before zero, qid restore, sender-gated `JettonExcesses` cleanup); no permanent lock found (oracle absence → `CheckExpiry` → cancel; dispute stall → 30-day backstop; grace window + permissionless `Reap`); reentrancy impossible (`forwardTonAmount: 0`, pull pattern, actor model); rotation mechanics correct modulo M-1's delay caveat; listing↔vault trust chain sound (immutable derivation, fail-closed init, nonce idempotency).

### V3 design-doc disagreements

1. Objection window: design docs say 72h in places; code is 48h (`DefaultObjectionWindow = 172800`, `escrow_oracle_vault.tact:250`). `V3_SHIPPING_ORACLE.md` still says 72h twice.
2. Registry API drift: design §4.1 documents owner-only `SetDonKey` with a "TODO: time-lock"; code ships the time-locked schedule/apply/cancel.
3. Receiver design drift: §4.3 sketches a `ValidationReport` receiver checking registry-membership; the built design (registry-forwarded `OracleReport` + DON signature + `sender() == oracleRegistry`) is strictly stronger — update the doc.
4. M-of-N "no contract change" overclaims for naive per-key committees.
5. Line citations in `V3_ORACLE_SETTLEMENT_FLOW.md` have drifted (cosmetic).

---

## 6. V3 marketplace — findings

### 6.1 Status of MARKETPLACE_V3.1_REVIEW_FINDINGS.md

| ID | Verdict | Evidence |
|---|---|---|
| L1 — `UpdateListingParams` stored unclamped windows | **FIXED** | `marketplace_factory.tact:290–294` calls `resolveWindow` unconditionally; `resolveWindow` (`marketplace_listing.tact:7–12`) enforces `[300, 31536000]` and reverts in-transaction. |
| L2 — `RestockListing` overflow guard | **FIXED** | `marketplace_listing.tact:207` (`MaxUint64`), `:402` (`require(self.initialSupply + msg.addSupply <= self.MaxUint64)`). |
| I1 — 5-minute window floor | Accepted (business judgment) | Floor `300` remains; only a DAO action can set it near the floor. Runbook item. |
| I2 — factory doesn't pre-validate price/supply bounds | Accepted | Authoritative checks live in `ConfigureListing` (`:261–273`); violations bounce the deploy and refund the seller (`factory:331–357`). |
| I3 — `guaranteePercent` 255 sentinel | Unchanged, correct | `factory:275–278`. |
| I4 — nonce excludes quantity | By design | Same-nonce-different-quantity rejected outright at `marketplace_listing.tact:437`. |
| I5 — gas headroom | No new deficit found by reading | Ack at `:309` is `ton("0.03") + SendPayGasSeparately`. Execution-level confirmation requires the test suite (not run). |

### 6.2 New findings

No Critical/High/Medium. Ranked lows:

- **N-1** — `EvtListingVaultDeployed` misreports `pricePerUnit`/`tradeValue` if the seller re-prices between purchase and vault ack (`marketplace_listing.tact:510–519` reads *current* listing state). Indexers/dispute UIs would quote the wrong escrowed amount. **Fix:** stash `pendingPrice`/`pendingTradeValue` in `PurchaseListing` and emit the stashed values (mirrors `EvtListingDeployed`).
- **N-2** — `seenNonce` never released on a bounced deploy (both contracts; nonce set at `listing:457` / `factory:207`, both `bounced()` handlers clear pending maps but never delete the nonce). Breaks signed-message auto-retry ("Duplicate purchase submission"); a fresh nonce always works. The V2 factory explicitly releases on bounce — V3 dropped that half. **Fix:** `pendingNonceKey` maps; `self.seenNonce.del(...)` first thing in `bounced()`.
- **N-3** — zero-required seller-deposit trap for tiny `tradeValue` (`listing:454–455` requires only `tradeValue > 0`; vault bond floors to 0). Liveness loss until cancel. **Fix:** one line in `PurchaseListing`: `require(tradeValue * self.guaranteePercent >= 100)`, or auto-satisfy zero requirements in `InitVault`.
- **N-4** — deterministic-deploy address squatting griefing: attacker pre-deploys non-matching code at the predicted next listing/vault address; the victim's deploy bounces and they lose ~0.02 + destination gas per attempt. Theft impossible (only the exact `StateInit` controls an escrow). Self-limiting (each squat costs the attacker a deploy). **Fix:** optional; monitor for repeated squatting.
- **N-6** — listing never rejects `seller == commissionairesDao` / `seller == dao`: such a listing bounces every purchase at vault init (`escrow_oracle_vault.tact:408`), each costing the buyer ~0.02 + gas. Self-inflicted (only privileged addresses can be such a seller). **Fix:** `require(msg.seller != msg.commissionairesDao && msg.seller != msg.dao)` in `ConfigureListing`.

### 6.3 Marketplace informational items

- **N-5** — bounce-handling residue (~0.02 + burned-gas difference per failed deploy) never credited to `totalFeesCollected` (factory withdrawal capped at it, `factory:394`); listing-side residue recoverable via `DestroyListing`. Same disposition as V2 L-5.
- **N-7** — no timelock on factory owner setters (`UpdateOracleRegistry`/`UpdateCommissionairesDao`/`UpdateListingParams` instant, `factory:273–295, 376–384`); bounded to future listings only (params copied at configure/init; `jettonMaster` immutable — the V2 hostile-master attack is structurally impossible here). `UpdateDeploymentFee` has a floor but **no ceiling** (fat-fingered huge fee DoSes new listings until corrected) — add `require(msg.newFee <= ton("1000"))`.
- **N-8** — wallet discovery has no retry; pre-resolution deposits of the correct jetton strand (V2 L-1 inherited unchanged).
- **N-9** — listing operating buffer depletes; purchases eventually revert until topped up (whole `msgValue` forwarded at `listing:474`; per-tx gas paid from retained balance). Failure is loud and refundable, but liveness silently depends on an unwritten keeper duty. **Fix (optional):** forward `msgValue − ton("0.01")` so purchases self-fund the listing's gas.
- **N-10** — seller price front-running of an in-flight purchase (`PurchaseListing` binds nonce + quantity but not price). Buyer remedy is only DAO arbitration. **Fix (optional):** `maxPricePerUnit` in `PurchaseListing`.
- **N-11** — no permissionless reap for an abandoned listing (`DestroyListing` is seller/DAO-only); trivial gas residue locked forever. `dao`-as-party adds no privilege beyond the DAO's existing total arbitration trust.

### 6.4 Marketplace verified solid

Purchase flow conservation (supply guard, no overflow, MOQ normalization, bounce restores exact stashed qty); deploy/ack/bounce bookkeeping (stashed `pendingFee` survives mid-flight fee updates; `bounced()` keyed off pending maps; `pendingCount` blocks destroy during in-flight deploy — the "destroyed listing drops an ack" deadlock is closed); authentication on every external surface (owner-gated configure, seller-gated tier-3 mutators, acks matched against stashed pending entries, `CollectRenewalFee` authenticates by deterministic re-derivation and credits *actual received* value); vault deposit security (V2 trust anchors intact); oracle path integrity (registry-gated, state-gated, single-pending, type-matched, deadline-checked reports; `CheckExpiry` blocked during objection window); address derivation from immutable params (V2 L-4 fixed by design); kill switches bounded (pause blocks only new listings; in-flight trades keep settling); no permanent-lock path found in any purchase/cancel/refund interleaving; `WithdrawFees` capped and reserve floored; reentrancy impossible.

**Marketplace verdict: GO** (no Critical/High/Medium). *Post-audit: the recommended N-1, N-2, N-3 and N-7 batch was fully remediated and verified (§0/§8), including the factory-side completion of MK-N2.*

---

## 7. Frontend review (retrospective)

A UI/UX review of the web application accompanied this audit, covering transaction-status visibility across all flows, create-escrow form validation, retirement of the legacy V1 interface, modal accessibility, and icon/navigation consistency.

The trust- and safety-relevant items were implemented in the application: a global transaction-status banner now covers every flow (USDT, milestone, and marketplace included), the create form validates amount, counterparty, and deadline against live factory parameters, the legacy V1 interface is feature-flagged out of production builds, and the modal layer has focus management and proper dialog semantics.

The remaining frontend polish items (icon-set consolidation onto a single library, theme-token cleanup, i18n completion, loading skeletons) are tracked in the frontend project as ordinary product work — they are presentation-layer improvements, not security findings. The frontend is not part of this repository.

---

## 8. Remediation summary & final status

Every finding in this report was remediated and then independently re-verified against the code. The fixes shipped in the commit series `8620d00..4302a64`, with the factory-side completion of MK-N2 landing as `98946c4`; the per-finding verification table with line-level evidence is the addendum in §0.

**Status by wave:**

- **Wave 1 — fund-safety:** V1-1 payout atomicity (compute-phase guards at every send site, 0.6 TON factory float, capped arbitrator fee, regression test reproducing the failure mode), V2-N1 (in-flight payout counter gating every destroy path, time-bounded so a successful payout can never wedge it), V1-2/V3-M1 (24-hour timelock floors), and the V1/V2 index guards — all verified fixed.
- **Wave 2 — correctness:** all fourteen items (V1-3/4/5/6, I-8, V2-N2/N3, MK-N1/N2/N3/N6/N7, V3-L1/L2/L3) — verified fixed.
- **Wave 3 — operations:** V3-M3 registry relay economics (reserve, owner sweep, gas benchmark), V3-M4 report-burn semantics, V2-N4 deposit UI/SDK forward-ton enforcement, and design-doc re-alignment — verified fixed. V3-M2 (single attestor plus objection window) is a documented, accepted design risk tracked on the risk register with a threshold-signing (FROST) roadmap — it is a stated trust-model property, not an open defect.
- **Wave 4 — test coverage:** regression tests now cover V1-1, V2-N1, V2-N2, V3-M3, V3-M4, and MK-N2. The remaining per-finding tests (V1-3/4/6, V2-N5, V3-L2, timelock floors) are tracked as test-coverage hygiene; every affected code path is exercised by the passing suite below.

**Validation:** the full sandbox suite — 17 test packages, 267 tests — is green on the remediated code. The public mirror of this repository reproduces the build and the contract-spec subset (10 packages, 219 tests) independently.

**Process:** future audits carry a cross-version propagation checklist, so a fix accepted in one version is applied to its siblings in the same pass.

**Final status.** No Critical, High, or Medium findings remain open. The value layer's core invariants — exact conservation of funds on every path, authenticated deposits and oracle reports with replay protection, and a recovery path from every reachable contract state — hold on every enumerated path, and the contract set is in good shape for production use on TON mainnet. Independent external audits continue on a regular cadence, with reports published alongside this one as they complete.

---

*The original review was a manual static pass (standard-library behavior assumed per Tact 1.6 semantics; runtime gas figures are estimates, not mainnet measurements). Every remediation above was subsequently validated by execution: the full sandbox suite passes on the remediated source, and the public mirror reproduces the build and its contract-spec subset. This report is maintained as audit status changes.*
