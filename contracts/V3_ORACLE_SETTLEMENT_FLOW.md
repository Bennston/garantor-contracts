# V3 Oracle Marketplace — Trade Flow & Settlement Technology

> Companion to `V3_ORACLE_MARKETPLACE_DESIGN.md`. This document explains the
> end-to-end trade flow and the technology that drives oracle-settled delivery
> verification and settlement. Written to be read alongside the code — every
> claim cites `file:line`.

## 1. Guiding principle

**Trust is a signature or a time window — never a role.** The relayer, the
finalizer, and even the DAO's own wallet are all untrusted senders. Authenticity
comes from Ed25519 signatures; finality comes from elapsed time plus the right to
object. This is what keeps settlement permissionless and censorship-resistant.

## 2. Trade flow overview

| Stage | Actor | What happens | Documents / IPFS |
|-------|-------|--------------|------------------|
| 1. List | Seller | Sets price/unit, supply, settlement rail, commercial terms | Attach docs via IPFS upload **or** URL links → embedded in terms |
| | | Terms + docs → backend DB → SHA-256 hash → listing deployed on-chain, `agreementCID = hash` | on-chain anchor is the hash |
| 2. Buy | Buyer | UI fetches terms from DB, verifies hash == on-chain before showing "verified"; buys N units → escrow vault deployed → buyer deposits USDT | reads doc links/CIDs |
| 3. Fulfil | Seller | **Oracle rail** (mode 0): submit shipment (container/BL#, carrier SCAC, optional B/L → IPFS CID) → tracking API → DON-signed report | B/L pinned to IPFS here |
| | | **Manual rail** (mode 1): buyer/seller exchange & confirm SHA-256 document hashes | doc-hash, no IPFS needed |
| 4. Settle | — | Oracle: DON report matching `validationType` opens a 48h objection window → finalize. Manual: mutual doc-hash confirm releases | |
| 5. Dispute | DAO council | Contested → 2-of-3 multisig resolution sets buyer/seller split net of DAO fee | reviews agreementCID docs |

### 2.1 IPFS document handling (two distinct touchpoints)

IPFS upload (Pinata) is used in **two** places, both gated on `VITE_PINATA_JWT`
(`IPFS_ENABLED`):

1. **At listing creation** — the seller can attach commercial/reference documents
   (spec sheet, COA, sample B/L, draft contract). The form
   (`MarketplaceView.jsx:333-351`) offers "Upload & pin files (IPFS)" **or**
   pasted "Document links" (http(s) URLs). Links work even without IPFS.
2. **At proof-of-delivery** — the seller uploads the actual Bill of Lading at the
   shipment step (`MarketplaceView.jsx:886-887`); `pinFile` → `blCid` →
   `submitShipment` binds that CID into the DON oracle proof.

**Nuance — `agreementCID` is a hash, not an IPFS CID.** In the current build the
on-chain `agreementCID` is a SHA-256 hash of the canonical terms JSON
(`marketplaceMetaClient.js:5-11`, `computeTermsKey`). Terms + document list live
in the backend DB keyed by that hash; the hash is the tamper-evident on-chain
anchor. A buyer re-computes the hash from the DB row and compares to on-chain.
The field is *named* `agreementCID` for legacy reasons and still accepts a real
legacy IPFS CID (`isTermsKey` / `isIpfsCid` routing).

**Config gotcha:** missing `VITE_PINATA_JWT` silently disables *all* IPFS upload —
listing file-upload UI is hidden (links-only) and B/L file upload at delivery is
disabled. Add `VITE_PINATA_JWT` + `VITE_IPFS_GATEWAY` to the mainnet frontend env,
or consciously launch links-only.

## 3. Milestone 1 — shipment → tracking API → DON-signed report

Four technologies stack up, all designed around "trust the signature, not the sender."

### 3.1 Real-world data source — carrier tracking APIs
A container / bill-of-lading number is a real identifier carriers expose via
tracking APIs. `TrackingApiValidator` + carrier adapters (`cre/carriers.ts`) query
it and reduce the answer to: delivered, failed, or still-in-transit.

### 3.2 CRE bridge — off-chain oracle signer
"CRE" = Chainlink Runtime Environment (hybrid model, see header of
`contracts/oracle_registry.tact`): a Chainlink DON reaches consensus off-chain,
then the bridge (`scripts/runCreBridge.ts`) re-signs a **canonical** report with an
Ed25519 key (the "DON attestation key"). **No Chainlink contracts run on TON** —
only a signature crosses onto the chain.

### 3.3 Ed25519 signatures + TON cell hashing — the cryptography
The report is serialized deterministically into a TON cell and its 256-bit
representation hash is signed (`cre/canonicalReport.ts:31-48`):

```
cell = beginCell()
  .storeAddress(vault).storeUint(tradeId,64).storeUint(validationType,8)
  .storeUint(status,8).storeUint(proofHash,256).endCell();
signed message = cell.hash()          // Ed25519 over this 32-byte hash
```

`proofHash` is the hash of the B/L proof payload, so the document is *bound into*
the signature — the B/L cannot be swapped without invalidating it. The off-chain
preimage (`cre/canonicalReport.ts`) is **byte-for-byte identical** to what
`oracle_registry.tact` reconstructs; `Cell.hash()` is identical in `@ton/core`
and the TVM. One field out of order → every signature silently fails on-chain.

### 3.4 OracleRegistry — the on-chain choke point
Anyone may call `SubmitReport` (permissionless). The registry rebuilds the
canonical cell and verifies via the TVM primitive
`checkSignature(canonical.hash(), signature, donPublicKey)`
(`oracle_registry.tact:126-160`). Pass → it forwards an authenticated
`OracleReport` to the vault. A compromised relayer cannot forge — only relay
genuinely DON-signed reports. The key lives in one place; the DAO rotates it with
a time-locked two-step (`ScheduleDonKey` → wait `timelockDelay` → `ApplyDonKey`),
so a stolen owner key can't instantly swap in a rogue oracle.

## 4. Milestone 2 — settlement

The vault (`contracts/escrow_oracle_vault.tact`) is a state machine; settlement is
deliberately **not** instant.

### 4.1 `validationType` — a type-tag preventing cross-purpose reports
The vault stores the `validationType` it accepts (seeded from the listing) and
requires `msg.validationType == self.validationType`, plus
`sender() == oracleRegistry`. A "shipping delivery" report (type 1) can never
settle a vault expecting a different oracle kind.

### 4.2 The 48h objection window — optimistic settlement
> **Enforced window = 48 hours.** `ObjectionWindow = 172800` seconds
> (`escrow_oracle_vault.tact:231`). NOTE: one inline comment (line ~733) still
> says "72h" — that comment is stale; the code pays out on 48h. Fix the comment
> before mainnet so docs and code agree.

A "delivered" or "failed" report does **not** pay out. It opens the window, records
the pending status, and waits (`receive(msg: OracleReport)`). During the window
**either party** may `RaiseDispute` (buyer may also release early via
`BuyerAcceptDelivery`). After it, **anyone** may send `"FinalizeDelivery"`
(`escrow_oracle_vault.tact:744`), applying the outcome:

- **Delivered** → `_allocateOnSuccess` (seller paid + commission)
- **Failed** → buyer takes trade value + the seller's slashed guarantee bond; seller gets nothing
- **Partial** (status 2) → straight to the DAO council

Same philosophy as optimistic rollups / fraud proofs: assume the oracle is right,
but allow a challenge period. Fund movement is never unilateral or instant.

### 4.3 Manual rail — SHA-256 document-hash confirmation
If the listing chose `settlementMode = 1`, the oracle path is disabled and
settlement is peer-to-peer: buyer and seller each submit a SHA-256 hash of the
delivery documents (`DocumentSubmit` / `DocumentVerify`, reused from V1); matching
hashes release funds. Trust is the two parties agreeing on exact bytes — no oracle.

### 4.4 Timeouts — the backstop
`deadline` / `disputeDeadline` (`CheckExpiry`, timeout-enforcer cron) guarantee
funds always resolve even if the oracle never reports or a dispute stalls.

## 5. Deep dive — a `runCreBridge` run, end to end

1. **Load + preflight guard.** Load the DON keypair from `DON_SECRET_KEY`
   (`keyPairFromSecretKey`), then read `registry.getDonPublicKey()` and compare to
   the loaded key (`runCreBridge.ts:65-69`). Mismatch → abort *before* spending
   gas (a wrong-key report would silently fail `checkSignature`).
2. **Pick the data source.** `pickValidator()` (`runCreBridge.ts:103`) by env, in
   order: `REPORT_STATUS` (static override) → `CARRIER` (shipping oracle,
   `TrackingApiValidator`) → `HEARTBEAT_URL` (2xx/non-2xx liveness).
3. **Validate.** `TrackingApiValidator.validate` (`cre/validators.ts:112`):
   resolves `{ trackingNumber, blCid }` for the trade (backend or static), calls
   `fetchStatus(trackingNumber)`. If **pending** → throws `ShipmentPendingError`,
   run exits cleanly (retry next pass — not a failure). Else maps
   `delivered → Delivered`, else `Failed`, and builds the proof cell:
   `SHIP|<state>|<trackingNumber>|<code>|cid:<blCid>` — binding the B/L CID so the
   signature commits to which B/L was verified.
4. **Sign.** `signReport` (`cre/canonicalReport.ts:47`) Ed25519-signs the canonical
   report hash. Identical preimage to the on-chain reconstruction.
5. **Relay.** `submitReport` (`cre/creBridge.ts`) sends `SubmitReport{..., signature}`
   with gas from `provider.sender()` — an untrusted courier. On-chain: registry
   verifies → forwards `OracleReport` → vault opens the 48h window.

Trust lives entirely in the Ed25519 signature over a deterministic hash — never in
the bridge process, the relayer, or the API caller.

## 6. Deep dive — the settlement money math

**At deposit** (`escrow_oracle_vault.tact:372-373`):

```
buyerDepositAmount  = tradeValue                          // buyer escrows full payment
sellerDepositAmount = tradeValue * guaranteePercent / 100 // seller bond (default 2%, range 1–20%)
totalPool           = buyerDepositAmount + sellerDepositAmount
```

**Delivered** — `_allocateOnSuccess` (`escrow_oracle_vault.tact:780`):

```
commissionAmount = tradeValue * commissionPercent / 100
sellerPayout     = totalPool - commissionAmount
sellerClaimable = sellerPayout ; buyerClaimable = 0 ; commissionairesClaimable = commissionAmount
```

**Failed** — bond slashed (`escrow_oracle_vault.tact:753`):

```
buyerRefund     = buyerDepositAmount + sellerDepositAmount  // payment back + slashed bond
sellerClaimable = 0                                         // no commission on a failure
```

### Worked example — `tradeValue = 1000 USDT`, `guaranteePercent = 2%`, `commissionPercent = 1.5%`

| | Buyer deposits | Seller bond | Pool |
|---|---|---|---|
| At start | 1000 | 20 | 1020 |

- **Delivered:** commission = 1000 × 1.5% = 15. Seller claims 1020 − 15 = **1005**
  (own 20 bond returned + 1000 payment − 15 fee → net +985). Buyer claims 0. DAO gets 15.
- **Failed:** buyer claims 1000 + 20 = **1020** (refund + slashed bond as
  compensation). Seller claims 0 (loses the 20 bond). No fee on a failure.
- **Partial (status 2):** no auto-math → DAO council sets a buyer/seller split net
  of the DAO fee.

### Why it's safe
1. **The bond aligns incentives.** Delivered → returned; failed → goes to the
   buyer. The seller can't costlessly not-ship, and the buyer is always made whole
   plus compensated on a failure — without trusting the seller.
2. **Pull payments, applied after the window.** The report sets a *pending* status;
   the math runs at `FinalizeDelivery` (48h later) or instantly on
   `BuyerAcceptDelivery`. The contract sets `*Claimable` and flips state; each party
   withdraws their own share. No single push transaction moves everyone's funds, so
   a failed send can't trap the rest.

## 7. Pre-mainnet notes surfaced by this write-up

- Fix the stale "72h" comment at `escrow_oracle_vault.tact:~733` → 48h.
- Add `VITE_PINATA_JWT` + `VITE_IPFS_GATEWAY` to the mainnet frontend env (or
  launch the marketplace links-only, consciously).
