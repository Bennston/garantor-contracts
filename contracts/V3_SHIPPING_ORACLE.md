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
*opens* the 48h objection window; it never drains a vault against an attentive
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
  CreBridge signs (Ed25519) ─▶ OracleRegistry verifies ─▶ vault opens 48h window
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
and opens the 48h objection window exactly like the automated path. The `Validator`
layer is pluggable by design — the data source may be a carrier API, an IoT feed,
**or a human**.

**3. Dispute / DAO.** `RaiseDispute` → DAO resolve / mutual settle / timeout.

> Trust note: a manual verdict is NOT less safe — it still only *opens* the objection
> window, never moves funds. The buyer can veto with `RaiseDispute` in the 48h. Adding
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

---

## 7. AI delivery cross-check (backend relayer) — BUILT 2026-10, inert by default

Closes the "delivery is not the same as the documents matching the sale" gap for the
backend relayer ([jobs/oracle-relayer.js](../garantor-backend/src/jobs/oracle-relayer.js)).
Once the **carrier** reports `delivered`, Claude cross-checks the seller's bill of
lading (fetched from IPFS by CID) against the listing terms and the carrier milestones
before the DON report is signed.

**Downgrade-only.** The final status comes from a deterministic gate
([lib/oracle-verdict.js](../garantor-backend/src/lib/oracle-verdict.js) `decide()`), not
from the model:

| Carrier says | AI verdict | Relayer does |
|---|---|---|
| not delivered | (AI not called) | wait |
| delivered | consistent (confidence medium/high) | submit **Delivered** |
| delivered | inconsistent, or injection suspected | submit **Partial** → vault goes straight to DISPUTED (council) |
| delivered | inconclusive / low confidence | wait; after `ORACLE_AI_MAX_WAIT_HOURS` (24) → **Partial** |
| delivered | AI unavailable / error | wait (never escalates, never pays) |

The AI never issues **Failed** (which would auto-slash the seller bond after the
objection window) and can never create a payout the carrier did not already signal, so
a fully manipulated model can at worst reproduce the carrier-only behaviour. The vault
and registry are unchanged — Partial already exists on-chain.

**Provenance.** The signed proof cell is `AIV1|<D|P>|<sha256 of the evidence>|cid:<B/L CID>`.
The registry hashes it into the DON signature, so a published report commits to the exact
evidence snapshot stored in `oracle_verdicts` (migration 027, append-only: evidence with the
B/L's sha256, model, validated verdict, decision, reason).

**Document fetching** ([lib/evidence-docs.js](../garantor-backend/src/lib/evidence-docs.js)):
CID only (the URL is built from `IPFS_GATEWAY`, never from party input), https only,
redirects not followed, 10 MB cap enforced while streaming, timeout, file type decided by
magic bytes (PDF/PNG/JPEG). Listing document URLs written by parties are NOT fetched.

**Rollout.** `ORACLE_AI_MODE=off` (default) -> `shadow` (evaluate + record, submit exactly
as before; review the recorded verdicts) -> `enforce`. Dry-run one vault without sending
anything: `node scripts/run-oracle-verdict.js --vault <addr> [--vizion]`.
Tests: `node scripts/test-oracle-verdict.js` (offline, 50 checks; `--live` runs the real
model on generated B/L PDFs including prompt-injection attempts — run it once before
`enforce`).

**Caveats.** It checks that the *documents are consistent with the sale*; it cannot see
the goods, so physical quality remains a buyer-dispute matter (the objection window still
applies). A seller can forge a B/L, but a forged document only matters if the carrier
also reports delivery; the AI can only make the outcome stricter. The seller's B/L is sent
to the Anthropic API (privacy disclosure needed).

**Scheduling.** The relayer endpoint `/api/cron/oracle-relayer` is called by the backend repo's
GitHub Actions workflow `.github/workflows/oracle-relayer.yml` (every 30 min, secrets `BACKEND_URL`
+ `CRON_SECRET`; Vercel Hobby's two cron slots are used). While the oracle rail is dormant it only
finalizes expired windows. Each run has a wall-clock budget (`ORACLE_RELAYER_BUDGET_MS`, 50s) and the
AI call a shorter timeout (`ORACLE_AI_TIMEOUT_MS`, 45s) because it runs inside a Vercel function.
Do not enable `shipping-relayer.yml` (the older TS path) alongside it. Deploy steps:
`garantor-backend/AI_FEATURES_DEPLOY.md`.

**Objection window.** The default is **48h** (`172800`), not 72h as older notes say. It is a DAO
parameter on the marketplace factory (`UpdateListingParams`, op 0x6108, `objectionWindow`, valid
5 min..1 year) that is snapshotted into each NEW listing, so a change never touches existing listings
and needs no redeploy. To move future listings to 72h (a Friday report then closes on Monday, not
Sunday) propose it from the DAO multisig with `scripts/proposeMarketplaceParams.ts`
(`EXPECTED_NETWORK=mainnet DRY_RUN=1 npx blueprint run proposeMarketplaceParams --mainnet` to preview).
72h is still short for commodity lab inspection; revisit with real trade data.
