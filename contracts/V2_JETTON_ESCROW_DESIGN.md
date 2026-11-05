# Garantor V2 — Jetton Escrow Design (exTON / USDT / USDe)

Status: **DRAFT for review/audit** · Supersedes nothing (V1 stays live). Author: engineering · Date: 2026-06-22

This document locks the architecture for a jetton-bearing escrow before any
fund-moving Tact is written. V1 (native-TON, immutable, already deployed) is
untouched. V2 is a **new, separately-deployed** contract set.

---

## 1. Decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Asset model | **Jetton-only, single asset (USDT) for phase 1.** Each vault holds exactly ONE jetton. Native TON is used ONLY for gas, never as the trade asset. The `jettonMaster` is a vault config field (defaulted to USDT in the factory) so phase 2 can re-introduce a multi-jetton whitelist WITHOUT touching the audited value layer. |
| 2 | Whitelisted assets | **Phase 1: USDT only** (mainnet master `EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs`). **Phase 2 (post-audit): add USDe** (the other stablecoin jetton) via the whitelist. NOTE: **exTON / "GRAM" is native TON, NOT a jetton** — those trades stay on V1's native path and never touch V2. V2 is stablecoin-jettons only. |
| 3 | Jetton-wallet trust | **DAO-whitelisted masters + `ProvideWalletAddress` discovery.** The vault learns its own jetton-wallet address from the master (TIP-3 standard), not from user input. |
| 4 | Rollout | **V2 alongside V1.** Frontend routes jetton trades to V2; existing TON escrows remain on V1. |
| 5 | Audit | **Required before mainnet.** No mainnet deploy of V2 until an external audit signs off. |

---

## 2. Why the value layer changes completely

V1 assumes `value == deposit`:
- **Deposit (in):** party sends TON; `context().value` *is* the deposit.
- **Payout (out):** `send(SendParameters{ value: claimable })`.

Jettons invert both:
- **Deposit (in):** party sends a jetton `transfer` (op `0x0f8a7ea5`) to *their own*
  jetton wallet → that wallet sends `transfer_notification` (op `0x7362d09c`) to
  the vault. The vault credits the deposit **only if the notification's `sender()`
  is the vault's own jetton wallet** for the expected master.
- **Payout (out):** vault sends a jetton `transfer` (op `0x0f8a7ea5`) to its *own*
  jetton wallet, instructing it to move jettons to the recipient, attaching TON
  for forward fees + a notification.

Consequences that ripple through the whole contract:
- The vault needs a **TON gas budget** separate from its jetton balance (every
  payout is a jetton transfer that costs TON forward fees).
- **Excess-refund** logic (V1 refunds TON overpayment on deposit) is replaced by
  jetton over-deposit handling.
- **Self-destruct sweep** (V1 returns leftover TON to buyer) must first ensure the
  jetton wallet is empty, then sweep residual TON.
- Accounting amounts (`tradeValue`, guarantee, commission, claimables) are now in
  **jetton minimal units** (USDT/USDe = 6 dp; exTON = TBD, confirm on whitelist).

---

## 3. Components

### 3.1 `EscrowJettonFactory` (V2)
A new factory; same registry/timelock/admin shape as V1, plus:

- **Jetton whitelist** `map<Address, JettonInfo>` keyed by jetton master:
  ```
  struct JettonInfo {
      enabled:   Bool;
      decimals:  Int as uint8;   // for off-chain display only
      minTrade:  Int as coins;   // min trade value in jetton minimal units
  }
  ```
  Managed by DAO via timelocked `AddJetton` / `SetJettonEnabled` messages.
- `CreateJettonEscrow` carries the chosen `jettonMaster` (must be whitelisted) in
  addition to buyer/seller/tradeValue/deadline.
- Deploys `EscrowJettonVault(factory, dao, tradeId)` and `InitVault`s it with the
  selected `jettonMaster`. Vault address stays deterministic from `tradeId`.

### 3.2 `EscrowJettonVault` (V2)
V1's state machine and dispute/settlement/timeout/doc-hash logic are **preserved
verbatim** (states 0–7, two-phase confirm, ProposeSettlement, CheckDisputeTimeout,
ForceExpiredCancel, etc.). Only the value plumbing changes.

New/changed state fields:
```
jettonMaster:      Address;   // the asset this vault escrows (from whitelist)
myJettonWallet:    Address;   // discovered via ProvideWalletAddress; 0 until known
jwResolved:        Bool;      // true once TakeWalletAddress received
```

---

## 4. Lifecycle (jetton-specific)

### 4.1 Init + jetton-wallet discovery
1. Factory deploys vault, sends `InitVault{ ..., jettonMaster }`.
2. Vault stores `jettonMaster`, sets `state = AWAITING_DEPOSITS`, and immediately
   sends `ProvideWalletAddress{ owner_address: myAddress(), include_address: true }`
   (op `0x2c76b973`) to `jettonMaster`, attaching ~0.05 TON.
3. Master replies `TakeWalletAddress` (op `0xd1735400`); vault stores
   `myJettonWallet`, sets `jwResolved = true`.
4. **Deposits before `jwResolved` are rejected** (handler requires it), so the
   vault can never mis-attribute a deposit. Frontend waits for `jwResolved`.
   "Rejected" here means *not credited* — it does **not** mean refunded. The
   depositor's jettons have already been credited to the vault's own jetton wallet
   by the time the notification arrives, and the throw cannot send them back; the
   notification is never replayed once `jwResolved` flips, so an early deposit of
   the *configured* jetton strands exactly as a foreign jetton does (§6.3). This is
   self-inflicted only — an attacker can strand nothing but their own funds — and
   the UI gates the deposit button on `jwResolved` to prevent it. If the single
   `TakeWalletAddress` reply is ever lost, the permissionless
   `RetryWalletDiscovery` receiver re-requests it.

> Security: `myJettonWallet` is sourced from the whitelisted master only — never
> from the user or the creator. A spoofed wallet cannot be injected.

### 4.2 Deposit (buyer or seller)
Handler `receive(msg: JettonTransferNotification)`:
```
require(jwResolved, "Wallet not resolved yet");
require(sender() == myJettonWallet, "Not from our jetton wallet");   // CRITICAL
let from = msg.sender;        // original depositor (buyer or seller)
let amt  = msg.amount;        // jetton minimal units actually received
```
- Route by `from == buyer` / `from == seller`, mirror V1's deposit rules
  (state == AWAITING_DEPOSITS, not-already-deposited, `amt >= required`).
- **Over-deposit:** refund `(amt - required)` back to `from` via a jetton transfer
  from `myJettonWallet` (mirrors V1's TON excess refund).
- **Wrong sender / wrong state / unknown `from`:** refund the full `amt` to `from`
  (never trap a user's jettons). This is the jetton analogue of bouncing.
- On both deposited → `AWAITING_CONFIRMATION` (unchanged).

### 4.3 Payout (success / resolve / settle / timeout / cancel)
V1 computes claimables identically. The **Withdraw** (pull) path changes:
```
// instead of send(value: claimable):
send jetton transfer from myJettonWallet → recipient, amount = claimable,
     forward_ton_amount = small, attaching enough TON for fees.
```
- Each payout costs TON. The vault must retain a gas reserve covering up to 3
  outbound jetton transfers (seller, commission, buyer) + final sweep.
- After all claimables are zero, sweep residual TON to the creator and
  self-destruct (V1's terminal logic). Note this is gated on **claimables** being
  zero, not on a literal jetton-wallet balance of zero: a contract cannot
  synchronously read its jetton wallet's balance, so claimables-zero plus the
  destroy grace window is the closest available approximation. The two diverge only
  where jettons were never credited in the first place (an early or foreign deposit,
  §4.2 / §6.3).

### 4.4 Gas model
- Factory forwards a **fixed TON gas budget** to each vault at deploy
  (`VaultGasBudget = 0.5 TON` regular / `1.0 TON` milestone), independent of trade
  size, sized for: wallet discovery + up to 2 deposit refunds + up to 3 payouts +
  sweep. Whatever the vault doesn't spend is **refunded** — swept to the creator on
  self-destruct (see §4.6), not retained as platform revenue. That's deliberate: the budget
  is a prepayment for operating costs, not a fee, and it's sized for the *worst*
  case (disputes, 30d rent) while most trades are the best case. Keeping the
  remainder would make the platform profit from oversizing the buffer, which
  would corrupt the safety-only basis on which it's set (0.6 → 1.0 was a pure
  safety call). If more revenue is needed, raise `deploymentFee` — it's explicit,
  disclosed, timelocked, and already accrues to the DAO/stakers.
- **Creation cost is coupled:** the factory requires
  `msgValue >= deploymentFee + VaultGasBudget`. Regular = 1.5 + 0.5 → the
  frontend's `JETTON_CREATE_TON` must stay ≥ 2.0 (currently 2.1). Changing
  `deploymentFee` without changing that makes every create fail.
- `deploymentFee` is **1.5 TON** on the regular jetton factory (vs V1's 0.5 — a
  jetton vault costs more to run: wallet discovery, and every payout is a jetton
  transfer) and **1.77 TON** on the milestone factory.

### 4.5 Referrer fee semantics (milestone)

The referrer fee is owed **once per trade**, not once per milestone. `payReferrer()`
is idempotent (guards on `!referrerPaid`) and fires on **any** outcome that pays
the seller, on **either** milestone:

| Outcome | Referrer paid? |
|---|---|
| `releaseMilestone0/1` — confirm, or review-window timeout auto-release | yes |
| Arbitrator resolves `releaseToSeller: true` | yes |
| Dispute-timeout 50/50 backstop | yes (the seller always receives ≥ half) |
| Mutual settlement | only if `sellerShare > 0` |
| Seller receives nothing on either milestone | **no** — fee refunds to the buyer at close |

So the fee **carries forward**: if M0 is disputed and resolved for the buyer, the
referrer isn't paid there; when M1 later pays the seller, they're paid then. And a
referral that produced a trade the seller never got paid on earns nothing — the
buyer's prepaid fee comes back rather than being kept.

### 4.6 Gas-residual recipient

Both vaults sweep unspent TON to the **creator** (whoever sent the create message
and therefore funded `VaultGasBudget`), not the buyer. They're usually the same
party, but not always — `CreateJettonEscrow` records `sender()`, which the UI does
not force to be the buyer. Refunding a prepayment to someone other than the payer
was simply a bug.

### 4.7 Dispute economics

| Product | Who compensates arbitration | Amount |
|---|---|---|
| Regular vault | the disputing parties' pool, at resolution | `daoFee`, chosen by the DAO per resolution, **capped at 10% of pool** |
| Milestone vault | the **buyer, prefunded in USDT** at funding | `disputeFee` = `disputeFeeBps` × totalValue (default **100 bps = 1%**, capped at 10%) |

The milestone `disputeFee` is **charged once per vault**, on the first arbitrated
dispute, and **refunded to the buyer at close** if no dispute was ever arbitrated.
It prices *"this trade needed the council"*, not each ruling — so a two-dispute
trade can never cost the buyer more than they prefunded.

Why prefunded rather than deducted at resolution: a milestone payout is released
incrementally, so by the time a late dispute is arbitrated there may be nothing
left to deduct from. Why proportional rather than flat: a flat fee is regressive
on small trades (same reason the commission is a percentage).

`disputeFeeBps` is snapshotted into the vault at creation, so a later timelocked
change can never re-price a trade the parties have already funded — the same rule
`referrerFeeBps` follows. Adjustable via `ScheduleParamChange param=3`.

> **History:** V1 paid a per-dispute `arbitratorFee` out of the vault's spare TON.
> That has no jetton equivalent, so the first port dropped it — silently leaving
> milestone arbitration (the most labour-intensive product the council handles)
> uncompensated. This is the replacement the vault header always pointed at.
> Separately, the regular factory's `arbitratorFee` field was **dead state**:
> settable via an admin message, never passed to the vault, absent from the config
> getter. An operator could pass a multisig order to set it and change nothing.
> Removed; op `0x2007` is left unused rather than recycled so a stale client fails
> loudly instead of hitting an unrelated handler.
- Deposit jetton transfers must include `forward_ton_amount` large enough for the
  notification to carry (frontend-enforced; vault rejects under-funded notifies).
- All constants validated against testnet emulation before audit.

---

## 5. Message schema (new / changed)

```
// Factory
message CreateJettonEscrow { buyer; seller; jettonMaster; tradeValue; tradeId; deadline; }
message AddJetton          { master; decimals; minTrade; }          // DAO, timelocked
message SetJettonEnabled   { master; enabled; }                      // DAO, timelocked

// Vault — standard TIP-3 interop
message(0x7362d09c) JettonTransferNotification { queryId; amount; sender; forwardPayload; }
message(0x2c76b973) ProvideWalletAddress       { queryId; ownerAddress; includeAddress; }
message(0xd1735400) TakeWalletAddress          { queryId; walletAddress; ownerAddress?; }
message(0x0f8a7ea5) JettonTransfer             { queryId; amount; destination; responseDestination; customPayload?; forwardTonAmount; forwardPayload; }
```
All existing V1 vault messages (BuyerDeposit/SellerDeposit op-based deposits are
**removed**; deposits now arrive via notification) — Confirm/Dispute/Settle/
Withdraw/Cancel/doc-hash receivers are unchanged.

---

## 6. Security checklist (auditor focus)

> **Internal review 2026-07-16 (pre-audit).** A full manual pass over the four V2
> contracts against this checklist produced four findings; all are resolved or
> consciously accepted below, and the notes are carried here for the auditor.
>
> - **§6.7 was violated and is now fixed.** `jettonMaster` was instantly settable
>   by the owner while every lesser numeric param sat behind the 24h timelock.
>   Now `ScheduleJettonMaster` → 24h → `ApplyJettonMaster` (+ `CancelJettonMaster`),
>   with the pending change exposed via `factoryConfig` so a scheduled asset
>   switch is visible on-chain during the window rather than only when it lands.
> - **§6.6 needed a grace window.** Vaults self-destructed the moment they settled
>   with nothing claimable — most easily a no-deposit `CancelTrade` seconds after
>   creation. Because a jetton deposit takes several hops, one can be in flight;
>   it then lands in the vault's jetton wallet, a *separate* contract that
>   outlives the vault and takes orders from nobody else, and is stranded
>   permanently. **V1 is immune** (its deposits are bounceable TON messages that a
>   dead vault bounces back) — this is V2-specific. Vaults now wait
>   `DestroyGraceWindow` (1h) after settling before destroying, refunding any late
>   deposit via the wrong-phase branch; a permissionless `Reap` completes the
>   deferred destroy. Nothing is withheld by waiting — only the gas sweep defers.
> - **§6.3 holds only for the configured jetton — accepted limitation.** A genuine
>   transfer of a *different* jetton is hard-rejected and stranded in the vault's
>   wallet for that jetton (`_sendJettons` only ever addresses `myJettonWallet`).
>   The hard reject is kept deliberately: refunding would let cheap forged
>   notifications drain the vault's fixed TON budget and block real payouts. The
>   alternative — an owner-only sweep of foreign wallets — would hand the DAO
>   jetton-moving power over vault funds behind an address comparison that is
>   itself unsafe before `jwResolved`. A vault that can only ever move its one
>   escrowed asset is worth more than recovering mis-sent tokens; the UI only ever
>   builds transfers of the configured jetton.
> - **Idempotency nonce released on a bounced deploy.** A form that never produced
>   a vault used to be permanently unusable. `bounced()` now clears
>   `seenTradeNonce`; the success path still keeps it.

> **External audit round 2026-07-17 (M-1) — bounce recovery is an ACCEPTED RESIDUAL
> RISK.** M-1 made every payout bounceable and added the recovery half: a
> `withdrawNonce` keyed `pendingPayoutAddr`/`pendingPayoutAmount` record,
> `bounced<JettonTransfer>` to restore the claimable (regular vault) or record a
> `failedPayout` claimable via `ClaimFailedPayout` (milestone vault), and
> `JettonExcesses` to clear the record on success. **The send half is exercised;
> the recovery half has never executed on any network.**
>
> *Why it is not tested, rather than merely untested.* `bounced()` only fires on a
> **wallet-side** failure — the transfer is delivered and the recipient's jetton
> wallet itself fails. The obvious lever does not reach it: starving the vault of
> TON makes `send()` throw *inside* the vault, reverting the whole transaction with
> state intact (the safe, self-healing mode). Forcing the real path needs a
> purpose-built hostile jetton wallet that throws on receive — which exercises
> Tact's bounce plumbing more than our logic, and cannot be staged on testnet
> against a well-behaved master at all.
>
> *Why the risk is accepted.* The failure it guards against is a payout whose
> attached `JettonFwdGas` does not cover the recipient's wallet deploy. Measured on
> testnet 2026-07-17 (V2.5, vault `EQC4Gztj…`): a referrer payout to an address with
> **no** jetton wallet deployed it successfully and consumed **~0.0014 TON** of the
> attached **0.15** — a ~100x margin. So the recovery path is a backstop for a
> condition two orders of magnitude away from the observed cost.
>
> *Confirmed against REAL Tether USDT (2026-07-17) — the mock is representative.*
> The testnet figure above came from the mock master, so it was re-measured against
> Tether's live mainnet USDT (`EQCxE6mU…`) by reading the **deploy transaction of
> real USDT jetton wallets** on mainnet (each wallet's oldest tx, `nonexist→active`).
> No funds were spent and nothing was signed — this is public history, and it samples
> real-world cases rather than one contrived transfer.
>
> | | fees to deploy |
> |---|---|
> | avg (n=6) | **0.000735 TON** |
> | worst observed | **0.001833 TON** |
> | mock master, for comparison | ~0.0014 TON |
> | `JettonFwdGas` attached | **0.15 TON** → **~82x** the worst observed |
>
> Two conclusions. The mock did **not** understate Tether — real USDT deploys cost
> 0.0007–0.0018 vs the mock's ~0.0014 — so the earlier testnet result stands rather
> than being a soft proxy. And real senders succeed on far less: an observed
> mainnet deploy completed with only **0.0247 TON** arriving at the new wallet. The
> audit's premise that 0.08 might be too thin is not borne out; 0.15 is ample.
>
> *What is still NOT proven.* These are standard TEP-74 transfers, not a payout from
> **our** vault on mainnet — that cannot exist until a mainnet factory does. The path
> is the same, so the residual unknown is small, but it is not zero.
>
> *What would invalidate this.* Tether controls the USDT wallet code and it is
> **upgradeable** (see M-1's own note: an upgrade can change gas economics for every
> live vault). These numbers are true as of 2026-07-17, not guaranteed. **Re-run the
> measurement after any Tether wallet upgrade**, and once a mainnet vault exists,
> confirm a real first-time-recipient payout through it. If the margin ever narrows,
> this acceptance lapses and `bounced()` must be exercised for real — most practically
> in sandbox against a throwing mock wallet.
>
> *How to re-run it (no funds, no signing).* Pull recent transfers from
> `/api/v3/jetton/transfers?jetton_master=<USDT>`, derive each recipient's jetton
> wallet via `get_wallet_address` on the master, then fetch that wallet's oldest tx
> (`/api/v3/transactions?account=<jw>&limit=1&sort=asc`) and read `total_fees`. Filter
> on `orig_status != 'active' && end_status == 'active'` — a jetton wallet deploys
> `nonexist→active` because the `internal_transfer` carries the state_init, so
> filtering on `orig_status == 'uninit'` silently matches nothing.
>
> *Reachable test recipe (for whoever revisits this).* To exercise a first-time
> recipient, set the **referrer** to a virgin address: it is a pure recipient that
> never signs and needs no TON, and — unlike a fresh seller — never posts a bond,
> which would deploy its jetton wallet and void the test. Confirm virginity first via
> `get_wallet_address` on the master, then `getContractState` on the result.

1. Deposit notification accepted **iff** `sender() == myJettonWallet` AND `jwResolved`.
2. `myJettonWallet` only ever set from a `TakeWalletAddress` sent by the stored
   `jettonMaster` (verify `sender() == jettonMaster`).
3. Unrecognised / wrong-state / wrong-amount deposits are **refunded**, never trapped.
   **Caveat (V2-N4, audit 2026-09-26):** this holds only if the deposit's TEP-74
   transfer carries `forwardTonAmount > 0` in the first place — with `0`, no
   `transfer_notification` is ever sent, so the vault never learns the deposit
   happened at all. The jettons still land in its jetton wallet, but nothing
   in this checklist item runs, and (per §6.3 above) the contracts deliberately
   never sweep an uncredited balance — so this is unrecoverable from the
   contract side. There is no on-chain fix: a `forwardTonAmount` of 0 is a
   syntactically valid TEP-74 transfer the vault's wallet is required to
   accept. The fix lives in the deposit UI/SDK instead — both
   `buildJettonTransferPayload` builders (`jettonEscrowClient.js` and its
   marketplace-vault duplicate in `marketplaceClient.js`) now hard-reject a
   `forwardTonNano` below 0.01 TON, so a misconfigured
   `VITE_JETTON_DEPOSIT_FORWARD_TON` / `VITE_MARKETPLACE_DEPOSIT_FORWARD_TON`
   env var can't silently produce one of these transfers.
4. Payout jetton transfers always target `myJettonWallet` with bounded TON.
5. No payout can exceed the vault's actual jetton balance (conservation:
   Σ claimables == Σ deposits, enforced as in V1).
6. Self-destruct only after all claimables are zero and the grace window has passed
   — the implementable approximation of "jetton balance == 0", which a contract
   cannot read synchronously (§4.3). It holds for every jetton the vault ever
   credited; uncredited jettons (early deposit §4.2, foreign jetton §6.3) are the
   two known divergences.
7. Whitelist changes are DAO-only + timelocked (reuse V1 timelock pattern).
8. Reentrancy: keep V1's pull pattern; set claimable=0 before sending.
9. Decimals: tradeValue/guarantee/commission math is integer; verify rounding
   never lets `sellerPayout + commission > pool`.

---

## 7. Test matrix (Blueprint + @ton/sandbox)

Add a jetton harness (mintable master + wallets) and prove, **per asset
(exTON, USDT-like, USDe-like)**:
- happy path: create → both deposit → seller confirm (doc hash) → buyer confirm →
  withdraw seller + commission → vault destroyed, jetton balances correct.
- over-deposit refund; under-deposit reject.
- deposit from non-party / before jwResolved / wrong jetton wallet → refunded.
- dispute → DAO resolve; mutual settle; dispute timeout 50/50.
- expiry → cancel → both refunded.
- gas-exhaustion edge: ensure payouts never strand jettons.

**Known coverage gap — `bounced<JettonTransfer>` / `ClaimFailedPayout` is NOT covered
by any test and has never executed on any network.** It is an accepted residual risk,
not an oversight; see the 2026-07-17 note in §6 for why it is impractical to stage
(starving the vault reverts *inside* the vault instead, never reaching `bounced()`)
and for the margin that justifies accepting it: **~82x against REAL Tether USDT**
(worst observed mainnet wallet deploy 0.0018 TON vs the 0.15 attached), measured
from mainnet deploy history rather than the mock. The acceptance is conditional —
Tether's wallet is upgradeable, so re-run that measurement after any USDT upgrade.
Covering the path for real needs a hostile mock jetton wallet that throws on
receive; that is the sandbox test to write if the margin ever narrows.

---

## 8. Frontend + backend follow-ons (after contracts pass)

- Creation form: asset selector (exTON/USDT/USDe); amounts in jetton decimals.
- Deposit UX: build jetton `transfer` to the user's jetton wallet (not a TON send),
  with correct `forward_ton_amount`; wait for `jwResolved` before enabling deposit.
- **TVL cap revisited:** with jetton vaults, `/api/tvl` must also sum each vault's
  *jetton* balance valued in USD (USDT/USDe ≈ $1; exTON via price feed), added to
  the existing native-TON V1 sum. (V1-only TON→USD endpoint stays correct until V2
  vaults exist — see [launch-guardrails].)
- New env: V2 factory address; whitelisted master addresses (USDT mainnet master
  `EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs`; exTON + USDe masters TBD).

---

## 9. Build sequence (staged, each gated)

1. **This doc** → review/approve.
2. `EscrowJettonVault.tact` value layer + jetton-wallet discovery (no factory yet),
   unit-tested against a mock jetton in sandbox.
3. `EscrowJettonFactory.tact` + whitelist + deploy/init wiring.
4. Full test matrix (§7) green for all three assets.
5. Wrappers + deploy scripts; testnet deploy with real exTON/USDT-testnet/USDe.
6. External audit.
7. Frontend/backend integration (§8) + mainnet rollout alongside V1.
```
```
