# Garantor V3 — Oracle-Settled Escrow Marketplace Design

Status: **DRAFT for review** · Supersedes nothing (V1 native-TON and V2 jetton stay live). Author: engineering · Date: 2026-07-05

This document locks the architecture for an **oracle-validated escrow marketplace**
before any fund-moving Tact is written. It is the V3 layer: a new, separately-deployed
contract set that reuses the audited V2 jetton value layer and the V1/V2 dispute,
settlement, timeout, and doc-hash logic **verbatim**. V1 and V2 are untouched.

It adapts an external "Universal Escrow Marketplace" brief to what is actually
buildable on TON, correcting three EVM-shaped assumptions in that brief (see §2).

---

## 1. Decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Rollout | **V3 alongside V1/V2.** New `MarketplaceListing` + `OracleRegistry` contracts; the V2 jetton vault is **extended** (new fields + one receiver), never forked or mutated. Frontend routes oracle-settled trades to V3; TON/jetton escrows stay on V1/V2. |
| 2 | Auto-settle trust | **Objection window, not instant payout.** BOTH a "Delivered" and a "Failed" oracle report open a 48h window during which **either buyer or seller** may `RaiseDispute`; only after the window with no objection does anyone's `FinalizeDelivery` apply the reported outcome (Delivered→seller, Failed→slash bond to buyer). "Partial" goes straight to DISPUTED. Preserves "no unilateral fund movement". |
| 2b | Settlement rail pin | **Each listing pins a `settlementMode`: `oracle-only` (0) or `manual-only` (1).** An oracle-only vault disables the two-phase doc-hash confirm; a manual-only vault rejects oracle reports. No vault accepts both rails — the guarantee matches what the listing advertised. |
| 3 | Scope | **Asset-agnostic core.** `validationType` is an enum + opaque `proof` blob. Vertical-specific integrations (commodity NFT, IoT/GPS geofence, API heartbeat) are deferred behind that interface. |
| 4 | Oracles | **Chainlink via the CRE hybrid pattern, not direct integration** (Chainlink has no on-chain TON deployment — no Data Feeds/Functions/CCIP/Forwarder on TON). A Chainlink CRE workflow fetches supply-chain/IoT/API data; the DON reaches consensus; our CRE bridge re-signs a canonical report with an **Ed25519 attestation key**; any relayer pushes `{report, signature}` to `OracleRegistry`, which **verifies the signature** (native `checkSignature`/CHKSIGNU) against the DAO-registered key. Trust anchor = the signature, not the sender. Price data (if ever needed) via **Pyth**/**RedStone** (both live on TON). |
| 5 | Legal anchor | **No EthSign** (EVM/EIP-712, incompatible with TON ed25519). The agreement is anchored as an **IPFS CID stored on the vault**, extending the existing `docHash` mechanism. |
| 6 | AI agents | Agent participation is an **off-chain concern** (backend wallets on the existing enforcer + cron infra). AI dispute resolution slots into the **address-gated arbitrator/signer layer — no contract change**, per the existing dispute-resolution model. |
| 7 | Audit | **Required before mainnet.** No mainnet V3 deploy until the new contracts (and the V2 vault extension) pass an external audit. Gates on V2's audit as well. |

---

## 2. Corrections to the source brief (TON reality)

The originating brief was written for an EVM chain and relabeled "TON." Three
load-bearing claims do not hold and are replaced here:

| Brief claim | TON reality | Replacement |
|-------------|-------------|-------------|
| Chainlink Oracles / Functions / Price Feeds (direct on-chain) | Chainlink has no on-chain TON deployment. BUT the **CRE hybrid** works: off-chain DON consensus + a signed report verified on-chain (TON's TVM has native Ed25519 `checkSignature`, and secp256k1 `ECRECOVER` since TVM 2023.07 if the DON's raw key is ever verified directly). | CRE workflow → DON consensus → Ed25519-signed canonical report → `OracleRegistry` verifies the signature. Pyth/RedStone for price data. |
| EthSign (EIP-712) "anchored to TON wallets" | EthSign / Sign Protocol is EVM/ECDSA; TON wallets sign ed25519. | Agreement **IPFS CID** on-chain (extends `docHash`); optional TON ed25519 signature for on-chain proof. |
| "Asynchronously deploys EscrowVault clones" (EVM minimal-proxy) | TON has no clone/proxy pattern. | Deterministic per-trade contract deploy from init-code + `tradeId` — already the Garantor factory pattern. |

The brief's *innovation framing* (oracle-validated settlement, legal anchor, agent
automation) is sound; only the named vendors change.

---

## 3. What is reused verbatim (do NOT rewrite)

V3 is ~70% existing code. From V2 (`escrow_jetton_vault.tact`) and V1:

- Jetton value layer: `ProvideWalletAddress`/`TakeWalletAddress` wallet discovery,
  deposit-via-`JettonTransferNotification`, spoof-safe crediting, outbound
  `JettonTransfer` payouts, over-deposit refunds, gas budget, self-destruct-when-drained.
- State machine (states 0–7), two-phase confirm, pull-pattern claimables.
- Dispute set: `RaiseDispute`, `ResolveDispute` (DAO 2-of-3 multisig arbitrator),
  `ProposeSettlement` (mutual %-split), 30-day `CheckDisputeTimeout` 50/50 backstop,
  expiry → cancel refund.
- `daoFee <= 10%` allocation invariant; conservation Σ claimables == Σ deposits.
- Factory registry / time-lock / admin shape.
- Events (`Evt*`) + the `scan-vaults.mjs` indexer.

**The genuinely new work is only §4.**

---

## 4. New / changed components

### 4.1 `OracleRegistry.tact` (new) — DON-signature gateway
DAO-owned. Stores the **trusted DON attestation key** (Ed25519, DAO-rotatable) and
verifies the signature on every report. Reports route THROUGH the registry because
TON is async — a vault cannot synchronously read a foreign map, and the CRE model
puts trust in the signature rather than the sender.

```
donPublicKey: Int as uint256;   // Ed25519 key of the CRE bridge; rotated via owner-only SetDonKey

// Canonical report preimage (MUST match the off-chain signer byte-for-byte):
//   cell = beginCell().storeAddress(vault).storeUint(tradeId,64)
//            .storeUint(validationType,8).storeUint(status,8).storeUint(proofHash,256).endCell()
//   signed message = cell.hash()
```

- **`SubmitReport{ vault, tradeId, validationType, status, proof?, signature }`** is
  **permissionless** — any relayer may push it. The registry recomputes the canonical
  hash and `require(checkSignature(hash, signature, donPublicKey))`. A compromised
  relayer cannot forge a report; it can only relay DON-signed ones.
- On valid signature it forwards an authenticated `OracleReport` to the vault. The
  vault trusts only `sender() == oracleRegistry` and re-checks `validationType`.
- No fund custody. Owner-only `SetDonKey` rotates the key in one place (per-vault keys
  avoided so rotation doesn't touch every live vault). **TODO before mainnet:** wrap
  `SetDonKey` in the V1 time-lock; optionally add per-`validationType` keys.

> Trust chain: Chainlink DON consensus → CRE bridge Ed25519 key → registry signature
> check → vault. The DON guarantees data correctness off-chain; the on-chain check
> guarantees the report is the one the bridge attested.

### 4.2 `MarketplaceListing.tact` (new)
The marketplace layer above the factory. Today a factory deploys one vault per trade;
a listing carries **inventory** and spawns one vault **per purchase**.

New state:
```
seller:          Address;
jettonMaster:    Address;    // must be V2-whitelisted (USDT phase 1)
pricePerUnit:    Int as coins;   // jetton minimal units
remainingSupply: Int as uint32;
validationType:  Int as uint8;   // seeded into each vault
agreementCID:    Slice;      // IPFS CID of the signed terms (legal anchor)
```

On buyer purchase: validate `remainingSupply > 0`, decrement it, and deploy one
`EscrowJettonVault` (V2, extended) seeded with `validationType` + `agreementCID`,
routing the buyer's jetton deposit through the standard V2 notification path.
Emits `EvtListingVaultDeployed`. Vault address stays deterministic from `tradeId`.

### 4.3 `EscrowJettonVault` extension (changed, not forked)
Add to V2's vault:

New state fields:
```
validationType:   Int as uint8;   // expected report kind (from the listing)
agreementCID:      Slice;          // IPFS CID of the signed agreement
objectionDeadline: Int as uint32;  // 0 until a "Delivered" report opens the window
```

New receiver `ValidationReport`:
```
message ValidationReport {
    tradeId:   Int as uint64;
    status:    Int as uint8;   // 0=Delivered 1=Failed 2=Partial
    proof:     Slice;          // opaque: GPS/temp log/API code/etc. (asset-agnostic)
}
```
Logic:
1. `require(registry-membership of sender())` — caller must be a whitelisted oracle.
2. `require(msg.validationType matches self.validationType)` — report kind must match
   what the listing declared (an "API check" oracle cannot settle a "GPS" vault).
3. `status == Delivered` → set `objectionDeadline = now() + OBJECTION_WINDOW`
   (default 48h). Does **not** pay out yet.
4. `status == Failed` → route to the existing refund path (buyer refunded, as expiry/cancel).
5. `status == Partial` → route to the existing `DISPUTED` flow (`ProposeSettlement` /
   DAO `ResolveDispute` / 30-day timeout all apply unchanged).

New permissionless receiver `FinalizeDelivery` (or fold into `CheckDisputeTimeout`-style
poll): after `objectionDeadline`, if the buyer has not raised a dispute, auto-settle via
the existing success allocation (seller + commission, pull pattern). If the buyer disputes
within the window, the standard dispute machinery takes over.

> This keeps the invariant: funds move only on (a) buyer consent, (b) oracle "Delivered"
> **plus** buyer non-objection, (c) DAO arbitration, or (d) a timeout backstop. A single
> compromised oracle can *open* a window but cannot *drain* a vault against an attentive buyer.

---

## 5. Lifecycle (oracle-settled trade)

1. Seller creates a `MarketplaceListing` (price, supply, `validationType`, `agreementCID`).
2. Buyer purchases → listing decrements supply, deploys an extended `EscrowJettonVault`,
   buyer deposits the jetton (V2 notification path); seller deposits guarantee.
3. Seller delivers off-chain; a whitelisted oracle/relayer submits `ValidationReport`.
4. `Delivered` → objection window opens. `Failed` → refund. `Partial` → dispute.
5. Window elapses with no buyer objection → `FinalizeDelivery` auto-settles.
   Buyer objection → `RaiseDispute` → DAO resolve / mutual settle / 30-day 50/50.
6. Vault pays out in jettons, drains, and self-destructs (V2 terminal logic).

---

## 6. Security checklist (auditor focus)

1. `ValidationReport` accepted **iff** `sender()` is an enabled oracle in `OracleRegistry`
   **and** `msg.validationType == self.validationType`.
2. "Delivered" only ever *opens* `objectionDeadline`; it never sets claimables directly.
3. `FinalizeDelivery` pays out **iff** `now() >= objectionDeadline` and state is not `DISPUTED`.
4. A buyer dispute during the window pre-empts finalization (state → `DISPUTED`).
5. `OracleRegistry` mutations are DAO-only + time-locked; multi-sig ownership required.
6. All V2 invariants preserved: deposit crediting (`sender() == myJettonWallet`),
   over-deposit refund, conservation, reentrancy-safe pull, self-destruct only when drained.
7. `agreementCID` is informational (evidence anchor); it never gates fund movement,
   so a malformed CID cannot lock funds.
8. `remainingSupply` decrement is atomic with vault deploy; a bounced deploy restores supply.

---

## 7. Off-chain (backend / frontend follow-ons)

- **Oracle relayer service** (backend): holds a registered TON wallet; for API/heartbeat
  validation it polls the target and submits a signed `ValidationReport`. For physical
  goods, an IoT/geofence relayer signs `(tradeId, status, proof)`. Reuse the existing
  enforcer-wallet + Vercel-cron infra.
- **AI agents**: optional backend wallets that create listings / initiate purchases /
  raise disputes autonomously. No contract change; agent-driven trades logged to the
  backend DB for audit.
- **Frontend**: listing creation form (price, supply, `validationType`, agreement upload
  → IPFS CID); buyer purchase flow; live status ("Awaiting Delivery", "Oracle Reported —
  Objection Window", "Settled"); permissioned oracle-admin panel for report resubmission.
- **TVL**: extend `/api/tvl` to include V3 jetton-vault balances (as already required for V2).

---

## 8. Fees

Fold into the existing `daoFee` allocation (already `<= 10%` invariant-guarded):
- **Match fee:** 0.5% of trade value at settlement.
- **Oracle fee:** pass-through (small fixed jetton amount) to the reporting relayer,
  deducted before seller payout.
- **Dispute deposit:** 5% arbitration bond from the losing party (via the existing
  dispute/settlement accounting).

---

## 9. Build sequence (staged, each gated)

1. ✅ **This doc** → reviewed/approved.
2. ✅ `OracleRegistry.tact` + `EscrowOracleVault.tact` `OracleReport` receiver — built,
   compiles (Tact 1.6.13), tested against the jetton sandbox harness.
3. ✅ Objection-window `FinalizeDelivery` + buyer-objection pre-emption; state tests green.
4. ✅ **DON-signature upgrade** — registry now verifies an Ed25519 signature over the
   canonical report (Chainlink CRE hybrid) instead of gating by sender address; DAO-rotatable
   key; permissionless relay. Tests: wrong-key rejected, tampered-status rejected, valid relay.
5. ✅ `MarketplaceListing.tact` (inventory + per-purchase seeded vault deploy).
6. ✅ Test matrix green (`EscrowOracleVault.spec.ts` 10/10, `MarketplaceListing.spec.ts`
   6/6, full suite **141/141**): deliver→finalize→pay, Failed→refund, Partial→dispute,
   buyer-objects→pre-empt, non-registry rejected, bad-signature rejected, wrong-type
   rejected, supply decrement + sold-out + duplicate-nonce + bounce restore, end-to-end
   purchase→deposit→DON report→settle.
7. ✅ **Time-locked DON-key rotation** — `ScheduleDonKey`→wait `timelockDelay` (24h,
   min 1h)→`ApplyDonKey`, `CancelDonKey`; initial key set at deploy. **Bond-slashing
   on Failed** — buyer takes the entire pool (trade value + slashed seller bond);
   seller forfeits the bond. **`MarketplaceFactory.tact`** — DAO-owned, deploys +
   configures listings (factory is listing `owner`; `dao`=arbitrator seeded into vaults),
   `ListingConfigured` ack finalizes bookkeeping, seller→listing discovery registry.
   Note: listing retains an operating TON buffer (ack sends a fixed 0.01, not
   SendRemainingValue) so mode-0 vault deploys have gas.
8. ✅ **CRE bridge service** (`cre/`) — `canonicalReport.ts` (byte-exact encoder/signer,
   pinned to the contract by `tests/CreBridge.spec.ts`), `creBridge.ts` (`CreBridge`:
   validate→sign→relay), `validators.ts` (`StaticValidator`, `HttpHeartbeatValidator`).
   **Deploy scripts + wrappers**: `.compile.ts` for all 4 V3 contracts; `genDonKey`,
   `deployOracleRegistry`, `deployMarketplaceFactory` (guarded), `createListing`,
   `rotateDonKey`, `runCreBridge`; npm aliases (`build:v3`, `deploy:*`, `cre:run`).
9. ✅ **Frontend integration** — `marketplaceConfig.js` (inert until
   `VITE_MARKETPLACE_FACTORY_ADDRESS` + `VITE_ORACLE_REGISTRY_ADDRESS` are set,
   mirrors V2's gating), `marketplaceClient.js` (payload builders for
   CreateListing/PurchaseListing/vault actions; reads via SINGLE-VALUE getters
   only — added 8 simple getters to `MarketplaceListing` so the wire format
   never depends on how a >14-field struct boxes over RPC), `MarketplaceView.jsx`
   (self-contained route: seller listing management, buyer purchase-by-address,
   deposit, oracle objection-window countdown, finalize/withdraw), wired into
   `RouterV2`/`SidebarV2` behind the same enablement gate. Verified live: dev
   server renders the disabled state correctly with no env set, zero console
   errors, `npm run build` succeeds, and the rest of the app (nav, dashboard) is
   unaffected.
10. ✅ **Testnet smoke-test script** (`scripts/smokeTestV3.ts`) — drives the full
   loop end-to-end against a REAL deployed testnet: sanity-checks the DON key,
   funds/derives an ephemeral buyer wallet (`BUYER_MNEMONIC`), creates a listing,
   purchases (spawns a vault), both parties deposit, the CRE bridge submits a
   DON-signed Delivered report, confirms the objection window opens, then either
   stops (printing resume instructions) or — if `WAIT_FOR_FINALIZE=1` — polls out
   the real 48h window and finalizes + withdraws. Resumable via
   `LISTING_ADDRESS`/`VAULT_ADDRESS`+`TRADE_ID` overrides.
11. ☐ Time-lock wrap the factory admin ops; external audit; mainnet rollout.

**Tier map now built:** `MarketplaceFactory` (DAO) → `MarketplaceListing` (per seller/
product, inventory) → `EscrowOracleVault` (per purchase) → settled by DON-signed reports
via `OracleRegistry`. Tests: 3 V3 suites (`EscrowOracleVault` 11, `MarketplaceListing` 6,
`MarketplaceFactory` 5), full suite **147/147**.

**Status: local-only, uncommitted.** All V3 code lives in `garantor-dao-escrow`; per the
escrow push rules any commit goes to origin all-at-once.
