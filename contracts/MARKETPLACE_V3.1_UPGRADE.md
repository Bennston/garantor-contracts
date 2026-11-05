# Marketplace V3.1 — quantity model, parameterised protocol params, listing mutability

Branch: `feat/marketplace-v3.1-quantity-params`
Touches: `contracts/marketplace_listing.tact`, `contracts/marketplace_factory.tact`, `contracts/escrow_oracle_vault.tact`
Compiles: `npm run build:v3` (verified — `OracleRegistry`, `EscrowOracleVault`, `MarketplaceListing`, `MarketplaceFactory` all green with tact 1.6.13).

This is a **breaking wire change** (message layouts change) and therefore needs a
full `MarketplaceFactory` redeploy on testnet → verify → mainnet, plus a
lock-step frontend release. Existing on-chain listings/vaults are unaffected —
they keep running their deployed code. See **Migration** below.

---

## Why

The V3 contract model is "*one purchase = one indivisible unit at a fixed
`pricePerUnit`*". `remainingSupply` only ever moves by 1, and a listing's
"total quantity" / "MOQ" / "unit" are off-chain descriptive text the chain never
sees. A seller listing "5 000 m² of WPC panel at 12.60 USDT/m²" actually mints
"100 lots at 12.60 each", and a buyer wanting 100 m² would have to click Purchase
100 times.

V3.1 makes the model match: the buyer picks a quantity, the vault escrows
`pricePerUnit × quantity`, and `remainingSupply` tracks real units. While the
factory has to be redeployed anyway, it also folds in the params that are
currently frozen in contract code (bond %, dispute windows, listing lifetime) and
the listing edits that currently force a destroy-and-recreate.

---

## Tier 1 — buyer-chosen quantity

### `PurchaseListing` (0x6002)
| before | after |
|---|---|
| `nonce: uint256` | `nonce: uint256`, **`quantity: uint64`** |

`receive(PurchaseListing)`:
- `require(quantity >= minOrderQty, "Below minimum order")`
- `require(maxOrderQty == 0 || quantity <= maxOrderQty, "Above maximum order")`
- `require(quantity <= remainingSupply, "Insufficient supply")` — replaces `remainingSupply > 0`; **no partial fills** (reject if stock can't fully cover the order)
- `tradeValue = pricePerUnit * quantity`; `require(tradeValue > 0 && tradeValue <= MaxTradeValue)`
- `remainingSupply -= quantity` (was `-= 1`)
- new `pendingQty: map<tradeId, uint64>` so `bounced()` restores the exact amount
- `bounced()`: `remainingSupply += pendingQty`, capped at `initialSupply`
- `InitVault.tradeValue` is now `pricePerUnit * quantity` (was `pricePerUnit`)

The idempotency key stays `hash(sender, nonce)` — quantity is **not** in it. A
genuinely new order needs a fresh nonce (the frontend already generates one per
purchase form); a retry of the same nonce dedupes regardless of quantity.

### `ConfigureListing` (0x6001) / `CreateListing` (0x6101) — supply fields
| before | after |
|---|---|
| `initialSupply: uint32` | `initialSupply: **uint64**` |
| — | **`minOrderQty: uint64`** (0 ⇒ 1) |
| — | **`maxOrderQty: uint64`** (0 ⇒ uncapped) |

- `initialSupply` / `remainingSupply` widened `uint32 → uint64` (supply is now
  counted in the listing's own unit — kg, g, m² — which can exceed 4.29 B).
- **`initialSupply` is now stored explicitly** on the listing (+ `initialSupply()`
  getter). Previously it was inferred client-side as `remaining + sold`, which
  breaks once `RestockListing` exists and once a bounce needs a cap.
- `MaxTradeValue = 1e17` minimal units (1e11 USDT @ 6dp) — a ceiling on
  `pricePerUnit × quantity` so a pathological listing can't overflow the vault's
  `coins`-typed `tradeValue`. Enforced on `pricePerUnit` at config and on the
  product at purchase.
- `ConfigureListing` bounds: `minOrderQty <= initialSupply`, and a set
  `maxOrderQty >= minOrderQty`.

---

## Tier 2 — stop baking tunables into contract code

All of these were already forwarded to the vault via `InitVault`, or were vault
`const`s — they're just frozen at compile time. V3.1 threads them through
`CreateListing → ConfigureListing → InitVault` so the DAO retunes them without a
redeploy.

### Listing-level, via `ConfigureListing`
| field | was | now |
|---|---|---|
| `guaranteePercent: uint8` | `init()` literal `2` | explicit from factory (1..20) |
| `commissionPercent: uint8` | `init()` literal `1` | explicit from factory (0..10; **0 is valid**) |
| `deadlineWindow: uint32` | `init()` literal 30 d | factory param (0 ⇒ 30 d) |
| `listingWindow: uint32` | `init()` literal 30 d | factory param (0 ⇒ 30 d) |

### Vault-level, via `ConfigureListing` → `InitVault`
| field | was (`escrow_oracle_vault.tact` const) | now |
|---|---|---|
| `objectionWindow: uint32` | `const ObjectionWindow = 172800` | `InitVault` field; vault state; `objectionWindow()` getter |
| `disputeTimeoutWindow: uint32` | `const DisputeTimeoutWindow = 2592000` | `InitVault` field; vault state; `disputeTimeoutWindow()` getter |
| `destroyGraceWindow: uint32` | `const DestroyGraceWindow = 3600` | `InitVault` field; vault state; `destroyGraceWindow()` getter |

- Consts kept as `DefaultObjectionWindow` / `DefaultDisputeTimeoutWindow` /
  `DefaultDestroyGraceWindow`; a `0` in any window field means "use the default".
- Both the listing (`resolveWindow`) and the vault (`_windowOr`) clamp a resolved
  window to **5 minutes .. 1 year** (`require(v >= 300 && v <= 31536000)`).
- Every `self.ObjectionWindow` / `self.DisputeTimeoutWindow` /
  `self.DestroyGraceWindow` reference in the vault is now the state field.

### Factory
- `MarketplaceFactory` holds the seven params as config, defaulted in `init()` to
  the exact pre-V3.1 values.
- New owner-only **`UpdateListingParams` (0x6108)** retunes them for *future*
  listings. `0` leaves a field unchanged; `commissionPercent` uses `255` as its
  "unchanged" sentinel since `0` is a real value.
- `MarketplaceFactoryConfig` struct + `config()` / `listingParams()` getters
  expose them.

---

## Tier 3 — listing mutability (no destroy + recreate)

Four new receivers on `MarketplaceListing`. **Each affects only what FUTURE
purchases inherit** — vaults already deployed keep the price / terms / windows
they were seeded with, so a buyer's agreed deal never shifts under them.

| msg | op | sender | effect |
|---|---|---|---|
| `UpdatePrice { pricePerUnit }` | 0x6008 | seller | re-price remaining inventory (`> 0`, `<= MaxTradeValue`) |
| `RestockListing { addSupply }` | 0x6009 | seller | `initialSupply += addSupply; remainingSupply += addSupply` (`addSupply > 0`) |
| `UpdateAgreementCID { agreementCID }` | 0x600A | seller | swap the terms hash — fix a typo, **change the listing photo**, revise the shipment window |
| `UpdateProtocolAddrs { oracleRegistry, commissionairesDao }` | 0x600B | owner (factory) | repoint infra for this listing's future vaults after an OracleRegistry migration |

Events: `EvtListingPriceUpdated` (0xF106), `EvtListingRestocked` (0xF107),
`EvtListingTermsUpdated` (0xF108, also fired by `UpdateProtocolAddrs`).
`EvtListingVaultDeployed` (0xF103) gains `quantity` + `tradeValue`.
`EvtListingDeployed` (0xF104) gains `minOrderQty` + `maxOrderQty` and widens
`initialSupply`.

New listing getters: `initialSupply`, `minOrderQty`, `maxOrderQty`,
`listingGuaranteePercent`, `listingCommissionPercent`, `listingObjectionWindow`,
`listingDisputeTimeoutWindow`, `listingDestroyGraceWindow`.

---

## Migration / redeploy runbook

1. `npm run build:v3` — confirm all four artifacts compile (done on this branch).
2. Update the Tact wrappers consumed by tests (regenerated into `build/` on
   compile) and fix every call site — see the test plan.
3. **Testnet**: `deployMarketplaceFactory --testnet` with the new code. New
   `MarketplaceFactory` address ⇒ new `MarketplaceListing` code hash ⇒ new
   listing addresses. Old testnet listings keep working under the old factory.
4. Point the frontend Preview env (`VITE_MARKETPLACE_FACTORY_ADDRESS`) at the new
   testnet factory; ship the frontend quantity UI (see below); run the full
   manual pass (create with a unit + MOQ, buy a partial quantity, restock,
   re-price, edit the photo, dispute-window timing).
5. **Mainnet**: this changes value math and supply accounting — send the diff for
   an audit delta review before the mainnet `deployMarketplaceFactory --mainnet`.
6. Mainnet cutover = new factory address in prod env + the frontend release, done
   together. The one existing mainnet listing (test WPC panel) is under the old
   factory; destroy it or leave it — it can't be migrated.

### Frontend changes needed (separate task, cannot ship before the redeploy)
- Create form: `initialSupply` label uses the chosen unit; add `minOrderQty` /
  `maxOrderQty` inputs; validate `minOrderQty <= initialSupply`,
  `maxOrderQty >= minOrderQty`.
- Purchase flow: quantity input bounded `minOrderQty .. min(maxOrderQty || stock,
  remainingSupply)`, with a live `pricePerUnit × qty` trade-value preview;
  `buildPurchaseListingPayload` gains `quantity`.
- `getListingState` reads the new getters; `SupplyMeter` shows "X of Y `<unit>` ·
  N sold" from the explicit `initialSupply`.
- Optional: seller UI for `UpdatePrice` / `RestockListing` / `UpdateAgreementCID`
  (the last one lets sellers change a listing photo — the V3.1 unlock for the
  thumbnail feature).

---

## Test plan

> **Status: implemented.** `npm test` — **15 suites / 252 tests green** (was 210).
> 43 new V3.1 cases across `MarketplaceListing.spec.ts` (+27),
> `MarketplaceFactory.spec.ts` (+9), `EscrowOracleVault.spec.ts` (+4, numbered
> 38–41). Mechanical call-site updates also touched `CreBridge.spec.ts`.
> One contract tweak fell out of the tests: the listing's `ListingConfigured`
> ack was bumped `0.01 → 0.03` TON — the factory's now-larger handler
> (two extra pending maps + wider event) ran out of gas at `0.01` (exit -14).

`build:v3` regenerates the Tact wrappers, so **every existing spec breaks at the
type level** until call sites pass the new required fields. That mechanical pass
is step 1; the new assertions are step 2.

### Step 1 — mechanical updates to existing specs

| file | change |
|---|---|
| `tests/MarketplaceListing.spec.ts` | `configure()` helper: add `minOrderQty`, `maxOrderQty`, `guaranteePercent`, `commissionPercent`, `deadlineWindow`, `listingWindow`, `objectionWindow`, `disputeTimeoutWindow`, `destroyGraceWindow` to the `ConfigureListing` body (use `0n` for the windows to exercise the default path, explicit `2n`/`1n` for percents). Every `PurchaseListing` send/`storePurchaseListing` gains `quantity: 1n`. Assertions on `remainingSupply` that assumed `-1` still hold with `quantity: 1n`. |
| `tests/MarketplaceFactory.spec.ts` | `CreateListing` body gains `initialSupply` as `bigint`, `minOrderQty: 0n`, `maxOrderQty: 0n`. `EvtListingDeployed` assertions gain `minOrderQty`/`maxOrderQty`. |
| `tests/EscrowOracleVault.spec.ts` | `InitVault` body gains `objectionWindow: 0n`, `disputeTimeoutWindow: 0n`, `destroyGraceWindow: 0n` (default path). Any test asserting the 48 h / 30 d / 1 h timings now reads them from the getters or passes explicit values. |

### Step 2 — new cases

#### `tests/MarketplaceListing.spec.ts` — `describe('V3.1 quantity')`
1. `it('escrows pricePerUnit * quantity in the spawned vault')` — configure `price=10 USDT`, buy `quantity=7n`; assert the vault's `tradeValue == 70 USDT`, `buyerDepositAmount == 70 USDT`, `sellerDepositAmount == 70 * guaranteePercent/100`.
2. `it('decrements remainingSupply by quantity')` — `initialSupply=100`, buy `30`, assert `remainingSupply() == 70`, `initialSupply() == 100`, `vaultsDeployed() == 1`.
3. `it('rejects quantity below minOrderQty')` — `minOrderQty=50`, buy `49` → exit with "Below minimum order"; `remainingSupply` unchanged.
4. `it('rejects quantity above maxOrderQty')` — `maxOrderQty=100`, buy `101` → "Above maximum order".
5. `it('allows quantity == maxOrderQty and == remainingSupply')` — boundary: buy exactly `maxOrderQty`; then a second buyer buys the exact remainder; `remainingSupply() == 0`.
6. `it('rejects an order larger than remaining stock (no partial fill)')` — `remainingSupply=40`, buy `41` → "Insufficient supply"; nothing consumed.
7. `it('rejects tradeValue over MaxTradeValue')` — `price` near the cap, `quantity` that overflows it → "Trade value out of range".
8. `it('restores the exact quantity on a bounced vault deploy')` — force the `InitVault` send to bounce (e.g. deploy the vault address first as a dumb contract, or starve gas); assert `remainingSupply` returns to pre-purchase value, `pendingCount() == 0`, buyer refunded.
9. `it('caps the bounce restore at initialSupply')` — contrived: restock down is impossible, so assert the `min(.., initialSupply)` guard by a bounce after a `RestockListing` reduced… (n/a — restock only adds; keep as a defensive unit assertion that `remainingSupply <= initialSupply` after any bounce).
10. `it('MOQ 0 normalises to 1')` — configure `minOrderQty=0`, buy `1` succeeds, buy `0` → "Below minimum order".

#### `describe('V3.1 Tier 2 params')`
11. `it('seeds the vault with the listing guarantee/commission percents')` — configure `guaranteePercent=5, commissionPercent=0`; buy; assert vault `sellerDepositAmount == tradeValue*5/100` and on success `commissionairesClaimable == 0`.
12. `it('forwards objection/dispute/grace windows to the vault')` — configure explicit `objectionWindow=3600, disputeTimeoutWindow=7200, destroyGraceWindow=1800`; buy; assert `vault.objectionWindow() == 3600` etc.
13. `it('0 window ⇒ vault default')` — configure windows `0`; assert `vault.objectionWindow() == 172800`, `disputeTimeoutWindow() == 2592000`, `destroyGraceWindow() == 3600`.
14. `it('clamps an out-of-range window')` — configure `objectionWindow=10` (< 300) → `ConfigureListing` reverts "Window out of range (5m..1y)".
15. `it('a Delivered report opens a window of the configured length')` — configure `objectionWindow=3600`; drive an oracle Delivered report; assert `objectionDeadline == now + 3600`.
16. `it('dispute timeout uses the configured disputeTimeoutWindow')` — raise a dispute; assert `disputeDeadline == now + configured`.

#### `describe('V3.1 Tier 3 mutations')`
17. `it('UpdatePrice changes only future purchases')` — buy at `price=10` (vault A `tradeValue=10*q`); `UpdatePrice` to `20`; buy again (vault B `tradeValue=20*q`); assert vault A's `tradeValue` unchanged.
18. `it('UpdatePrice rejects non-seller')` — DAO/other sends → "Only seller".
19. `it('UpdatePrice rejects 0 and > MaxTradeValue')`.
20. `it('RestockListing bumps initialSupply and remainingSupply')` — sell down to `remainingSupply=10` (`initialSupply=100`); `RestockListing addSupply=50`; assert `remainingSupply()==60`, `initialSupply()==150`; `EvtListingRestocked` emitted with `remainingSupply=60`.
21. `it('RestockListing rejects non-seller / addSupply 0')`.
22. `it('a listing can be bought again after restock past sold-out')` — buy the whole `remainingSupply` (→ 0, "Insufficient supply" on next); `RestockListing`; next buy succeeds.
23. `it('UpdateAgreementCID swaps the hash for future vaults only')` — buy (vault A carries CID₁); `UpdateAgreementCID` CID₂; buy (vault B carries CID₂); assert `vaultA.agreementCID()` still CID₁; `EvtListingTermsUpdated` emitted.
24. `it('UpdateAgreementCID rejects non-seller')`.
25. `it('UpdateProtocolAddrs is owner-only and repoints future vaults')` — from the factory: change `oracleRegistry`; a subsequent purchase's vault has `oracleRegistryAddr() == new`; a direct seller send → "Access denied" (Ownable).
26. `it('all Tier 3 messages revert on an inactive/destroyed listing')`.

#### `describe('V3.1 getters + config struct')`
27. `it('config() returns the widened + new fields')` — assert `initialSupply`, `minOrderQty`, `maxOrderQty`, `objectionWindow`, `disputeTimeoutWindow`, `destroyGraceWindow` round-trip.
28. `it('single-value getters match config()')`.

#### `tests/MarketplaceFactory.spec.ts` — `describe('V3.1 factory params')`
29. `it('CreateListing forwards minOrderQty/maxOrderQty to the listing')` — create with `minOrderQty=50, maxOrderQty=500`; read the deployed listing's `minOrderQty()/maxOrderQty()`.
30. `it('CreateListing rejects maxOrderQty < minOrderQty')`.
31. `it('seeds new listings with the factory default params')` — fresh factory; create; listing `listingGuaranteePercent()==2`, `listingObjectionWindow()==172800`, etc.
32. `it('UpdateListingParams retunes future listings only')` — create listing A; `UpdateListingParams { guaranteePercent: 5, commissionPercent: 255, deadlineWindow: 0, ... }`; create listing B; assert A's percent still 2, B's is 5.
33. `it('UpdateListingParams commissionPercent sentinel')` — send `commissionPercent: 0` (a real change to 0%); create listing; `listingCommissionPercent()==0`. Send `255`; unchanged.
34. `it('UpdateListingParams is owner-only')`.
35. `it('UpdateListingParams bounds guarantee 1..20 and commission 0..10')`.
36. `it('EvtListingDeployed carries the new fields and uint64 initialSupply')` — create with `initialSupply = 5_000_000_000n` (> uint32) → event + listing report it intact.
37. `it('factory config()/listingParams() expose the seven params')`.

#### `tests/EscrowOracleVault.spec.ts` — `describe('V3.1 seeded windows')`
38. `it('InitVault stores explicit windows and clamps them')` — direct `InitVault` with `objectionWindow=10` → revert; with `3600` → stored.
39. `it('InitVault 0 windows fall back to Default* consts')`.
40. `it('settlement timing uses the seeded windows end-to-end')` — Delivered report → `objectionDeadline` respects the seeded `objectionWindow`; `FinalizeDelivery` only allowed after it; terminal self-destruct deferred by the seeded `destroyGraceWindow`.

### Regression (must stay green, unchanged behaviour with `quantity: 1n` / default windows)
- The full existing `MarketplaceListing` / `MarketplaceFactory` / `EscrowOracleVault`
  suites: deposit → oracle/manual settle → withdraw; dispute → resolve; cancel;
  expiry; renewal; destroy; nonce idempotency; bond-split; commission math;
  wrong-sender deposit refund; self-destruct grace.
- `npm test` (all suites) must pass — V1/V2 contracts are untouched but share the
  build pipeline.

---

## Risk notes for review

- **Value math**: `pricePerUnit * quantity` is the only new multiplication in the
  hot path. `pricePerUnit` is `coins` (124-bit), `quantity` is `uint64`; product
  is bounded by `MaxTradeValue` (1e17) well under `coins` max (~1.3e37). The
  guard is belt-and-braces.
- **Supply accounting**: `remainingSupply` is now `uint64` and moves by
  `quantity`. Underflow is prevented by `require(quantity <= remainingSupply)`
  before the subtraction. Bounce restore is `min(remaining + qty, initialSupply)`.
- **`initialSupply` mutation**: only `RestockListing` (seller) grows it; nothing
  shrinks it. `remainingSupply` can never exceed it.
- **Window clamping** happens in two places (listing `resolveWindow`, vault
  `_windowOr`); both enforce `[300, 31_536_000]`.
- **Ownable**: `UpdateProtocolAddrs` (listing) and `UpdateListingParams`
  (factory) both call `requireOwner()`. `UpdatePrice` / `RestockListing` /
  `UpdateAgreementCID` are `sender() == self.seller`.
- **Idempotency unchanged**: `hash(sender, nonce)` — quantity deliberately
  excluded so a rebroadcast can't slip a different quantity through on the same
  nonce.
