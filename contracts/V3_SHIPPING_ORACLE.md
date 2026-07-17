# V3 Shipping Oracle — how the DON verifies delivery of physical goods

Companion to [V3_ORACLE_MARKETPLACE_DESIGN.md](./V3_ORACLE_MARKETPLACE_DESIGN.md).
Written 2026-07-12. Covers how a decentralized-oracle ("DON") verdict on a real
shipment is produced, signed, and bound to the seller's bill of lading — and what
is built vs. still open.

---

## 1. The question that started this

> *"How does the DON verify shipping? Does it relate to the file the seller
> attached on IPFS? Is there a mixup?"*

Yes — there was a real conceptual gap. Three separate document channels were easy
to conflate into one:

| # | Channel | Set when | Verified by | Role |
|---|---------|----------|-------------|------|
| 1 | **`agreementCID`** | listing creation | nobody (informational anchor) | the signed *terms* / legal record ([escrow_oracle_vault.tact:83](./escrow_oracle_vault.tact)) |
| 2 | **`docHash`** (manual rail) | delivery, on `SellerConfirmDelivery` | the **buyer's eyeballs** (`BuyerConfirmReceipt` must match) | manual settlement; no oracle |
| 3 | **`proof`** (oracle rail) | oracle report | opaque, DON-attested | the DON verdict payload |

**The mixup:** the DON does **not** read the seller's B/L. The shipped reference
validators ([validators.ts](../cre/validators.ts)) — `StaticValidator` and
`HttpHeartbeatValidator` — never fetched a shipping document; the heartbeat just
pinged a URL. So "the seller's B/L on IPFS" and "what the DON verified" were
**two disconnected things**, and no validator verified physical shipping at all.

This section closed that gap.

---

## 2. What Chainlink does (and does not) provide

Chainlink has **no "track a shipment" product**. It is a decentralized
compute-and-attestation layer:

- **Data Feeds** (prices), **Functions/CRE** (off-chain compute with DON
  consensus), **VRF**, **Automation**, **CCIP**.
- It guarantees: a *decentralized* network fetched the data, *agreed* on it, and
  delivered the signed result on-chain trustlessly.
- It does **not** supply the shipment-tracking logic or the data source. You write
  the workflow that calls a carrier/IoT API; Chainlink runs and signs it.

We are on **TON, not EVM**, so we do not use literal Chainlink (see design §5,
"No EthSign"). "The DON" here is a **Chainlink-CRE-shaped pattern we built
ourselves**: `CreBridge` signs an Ed25519 report, `OracleRegistry` verifies it.
The `Validator` interface *is* the Functions/CRE job.

**Trust model today:** single DON key (option 1 of 3). A false verdict only
*opens* the 72h objection window; it never drains a vault against an attentive
buyer. Decentralizing later (M-of-N committee, or real Chainlink CRE via a bridge)
requires **no contract change** — the vault only checks "is this signature from a
key the registry trusts?"

---

## 3. Architecture built

```
Seller ships ──POST /api/shipment-tracking──▶  shipment_tracking row (write-once)
                                                  { vault, trackingNumber, blCid }
                                                          │
CRE relayer (runCreBridge, one trade / run):             ▼
  shipmentFor(trade) ──GET /api/shipment-tracking/:vault──▶ { trackingNumber, blCid }
        │  404 → ShipmentPendingError  (not shipped yet → submit nothing, retry)
        ▼
  fetchStatus(trackingNumber) ──▶ carrier API ──▶ delivered | failed | pending
        │  pending / unreachable → wait  (NEVER a false Failed refund)
        ▼
  proof = "SHIP|delivered|<tracking>|<code>|cid:<blCid>"   ← B/L bound into the verdict
        ▼
  CreBridge signs (Ed25519) ─▶ OracleRegistry verifies ─▶ vault opens 72h window
        ▼
  window elapses, no buyer objection ─▶ FinalizeDelivery ─▶ seller paid
```

**The key fix:** the B/L CID is embedded in `proof`, and the registry hashes
`proof` into the signed preimage ([oracle_registry.tact](./oracle_registry.tact),
[canonicalReport.ts](../cre/canonicalReport.ts)). So an on-chain "Delivered" now
**provably commits to the exact document the seller uploaded** — channels 1/3 are
no longer disconnected.

**Load-bearing safety rule:** anything not conclusively terminal → `pending`
(wait); transport errors throw. An escrow must never refund on an ambiguous
"customs hold" / "exception" or a flaky network. Only an explicit carrier
"returned / lost / undeliverable" settles as Failed.

---

## 4. Build manifest

**Escrow repo (`cre/`, `scripts/`, `tests/`):**
- [cre/validators.ts](../cre/validators.ts) — `TrackingApiValidator`, `ShipmentPendingError`, `CarrierOutcome`, `ShipmentRef`.
- [cre/carriers.ts](../cre/carriers.ts) — `mockCarrier`, `httpCarrierAdapter`, `keywordClassifier`, `carrierFromEnv` (the `fetchStatus` half).
- [cre/shipmentSource.ts](../cre/shipmentSource.ts) — `backendShipmentSource`, `staticShipmentSource` (the `shipmentFor` half).
- [scripts/runCreBridge.ts](../scripts/runCreBridge.ts) — relayer entrypoint; new shipping-oracle branch + clean pending-exit.
- [tests/TrackingApiValidator.spec.ts](../tests/TrackingApiValidator.spec.ts), [tests/Carriers.spec.ts](../tests/Carriers.spec.ts) — 12 tests, pure (no sandbox/build), all green.
- [.env.example](../.env.example) — relayer configuration template.

**Backend repo (`garantor-backend/`, separate git repo):**
- [sql/015_shipment_tracking.sql](../garantor-backend/sql/015_shipment_tracking.sql) — `shipment_tracking` table, keyed by vault address.
- [sql/016_shipment_tracking_carrier_ref.sql](../garantor-backend/sql/016_shipment_tracking_carrier_ref.sql) — adds `carrier_ref` (Vizion reference id) + `carrier_scac`.
- [src/utils/vizion.js](../garantor-backend/src/utils/vizion.js) — Vizion client: `createVizionReference` (POST /references → reference_id).
- [src/db/shipment-tracking.js](../garantor-backend/src/db/shipment-tracking.js) — write-once `upsertShipment` + `getShipmentByVault`.
- [src/api/shipment-tracking.js](../garantor-backend/src/api/shipment-tracking.js) — `POST` (seller submits container/BL; registers with Vizion at ship-time) + `GET /:vault` (relayer reads `carrier_ref || tracking_number`).
- `src/server.js` — route mounts beside marketplace-listings.

**Confirmed provider wiring (Vizion, ocean freight):**
- Create: `POST https://prod.vizionapi.com/references`, header `X-API-Key`, body `{ container_id, carrier_code }` | `{ bill_of_lading }` | `{ booking_number }` → `reference.reference_id`.
- Poll: `GET https://prod.vizionapi.com/references/{reference_id}` → `payload.milestones[]`, classified by [`vizionMilestoneClassifier`](../cre/carriers.ts). ShipsGo (single `status.value`) fits the generic `CARRIER_API_URL` adapter instead.

---

## 5. Configuration (where + how)

Config home: gitignored **`.env` at the escrow-repo root** (blueprint auto-loads
it); on a server, host env vars. Full list in [.env.example](../.env.example).

**Smoke test now (no external deps):** `CARRIER=mock`,
`CARRIER_MOCK_STATE=delivered|failed|pending`, `TRACKING_NUMBER=TEST123`,
`BL_CID=…`, plus the on-chain vars → `npx blueprint run runCreBridge`.
`pending` proves the "submit nothing" path; `delivered` opens the window on-chain.

**Real carrier:** `CARRIER=http`, `CARRIER_API_URL=…/{tracking}`,
`CARRIER_API_KEY=…`, `CARRIER_STATUS_PATH=…`, `BACKEND_URL=…`. The adapter is
provider-agnostic. For **ocean freight / commodities** (our listing fields —
incoterm, loading port, B/L) use a **container aggregator: Vizion / ShipsGo /
project44** — NOT 17track (parcel-focused).

---

## 5b. Settling without a carrier subscription

A carrier subscription only **automates** the "did it deliver?" verdict. It is not
required to settle. Three subscription-free paths exist:

**1. Skip the oracle entirely (no DON key needed).**
- *Manual-rail listings* (`settlementMode = 1`): seller `SellerConfirmDelivery{docHash}`
  → buyer `BuyerConfirmReceipt{docHash}` → funds release. The UI's Confirm-delivery /
  Confirm-receipt flow. Pure two-party, no oracle.
- *Buyer direct release* (works on ANY vault, incl. oracle-only): buyer clicks
  "Release funds directly" → seller paid. No oracle involved.

**2. Be the oracle yourself — manual DON verdict (the generated code, run manually).**
For an oracle-only vault (`settlementMode = 0`, where manual confirm is disabled),
verify delivery off-chain by any means, then sign the verdict by hand:
```
ORACLE_REGISTRY_ADDRESS=…   DON_SECRET_KEY=<your genDonKey hex — NOT a subscription>
VAULT_ADDRESS=…             TRADE_ID=…
REPORT_STATUS=0             # 0 Delivered · 1 Failed · 2 Partial
npx blueprint run runCreBridge
```
`REPORT_STATUS` selects the `StaticValidator` (no data source); `CARRIER=mock
CARRIER_MOCK_STATE=delivered` is equivalent. This produces a real DON-signed report
and opens the 72h objection window exactly like the automated path. The `Validator`
layer is pluggable by design — the data source may be a carrier API, an IoT feed,
**or a human**.

**3. Dispute / DAO.** `RaiseDispute` → DAO resolve / mutual settle / timeout.

> Trust note: a manual verdict is NOT less safe — it still only *opens* the objection
> window, never moves funds. The buyer can veto with `RaiseDispute` in the 72h. Adding
> a subscription later flips one env var (`REPORT_STATUS=0` → `CARRIER=vizion`);
> nothing else changes.

---

## 6. Open items

1. **Scheduled relayer / vault discovery — DEFERRED.** `runCreBridge` settles one
   vault per run. Autonomous operation needs (a) discovery of open oracle vaults
   and (b) a schedule. Planned as a **backend cron** (to be added once on the paid
   tier). The `ShipmentPendingError` clean-exit already makes per-vault runs safe
   to schedule. Discovery source (backend `escrows` table vs. factory events) TBD.
2. **Seller-wallet auth on `POST /api/shipment-tracking` — BUILT (TonConnect ton_proof).**
   The caller must prove control of the vault's on-chain seller wallet, via three
   checks in [utils/seller-auth.js](../garantor-backend/src/utils/seller-auth.js):
   (1) [ton_proof](../garantor-backend/src/utils/ton-proof.js) signature valid,
   (2) `publicKey == on-chain get_public_key(address)` (binds key→wallet),
   (3) `address == vault.vaultState.seller` (binds wallet→this vault). The proven
   address overrides any client-claimed `sellerWallet`. Config:
   `TONPROOF_ALLOWED_DOMAINS`, `TONPROOF_MAX_AGE_SEC`. Verifier tested standalone
   (`scripts/test-ton-proof.js`, 6/6).
   **Frontend — BUILT.** [lib/tonProof.js](../garantor%20dao-ui-frontend/src/lib/tonProof.js)
   requests `tonProof` on connect, captures it, and re-authorizes (disconnect→reconnect)
   when a restored session has none; [lib/shipmentClient.js](../garantor%20dao-ui-frontend/src/lib/shipmentClient.js)
   posts `{ tonProof, tonAccount }`; [MarketplaceView.jsx](../garantor%20dao-ui-frontend/src/v2/MarketplaceView.jsx)
   adds a "Submit shipment tracking" action + `ShipmentModal` (container/SCAC + optional
   IPFS-pinned BL) on oracle-only vaults the seller owns. Frontend builds clean.
   **Optional hardening:** issue a per-submission server nonce as the proof `payload`
   (a `GET /ton-proof/payload` step) to tighten the 15-min replay window. Dev note:
   `TONPROOF_ALLOWED_DOMAINS` must include the dev host (e.g. `localhost`) to test locally.
3. **Carrier provider — Vizion wired; needs a key.** Set `VIZION_API_KEY` on the
   backend and `CARRIER=vizion` + `CARRIER_API_KEY` on the relayer. Vizion is
   asynchronous: `POST /references` returns immediately but `milestones[]` fills in
   over minutes/hours as the carrier reports — the relayer's `pending` clean-exit
   handles that (it just keeps polling). ShipsGo remains a config-only alternative.
4. **Decentralize the DON key (optional, later).** Move from single-key to M-of-N
   committee or Chainlink CRE. No contract change required.
