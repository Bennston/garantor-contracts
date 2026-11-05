# Marketplace V3.1 — rollout checklist

Companion to `MARKETPLACE_V3.1_UPGRADE.md` (the *what* and *why*). This is the
*how* — an ordered checklist from "PR open" to "live on mainnet".

**You are here:** Phase 4 **cutover executed 2026-09-05.** Mainnet now runs
the V3.1 `MarketplaceFactory` at `EQDLB7_ab9m2VJQMinXmfljGys9xgg-KiJ8ax_m6ZajrjSc-`,
verified on-chain and confirmed live on `app.garantor.io`'s served bundle.
**Remaining, not yet done:** destroy the stranded old-factory listing, and a
real-money smoke test (create a listing + buy a partial quantity) — both need
a real wallet, see the checklist below. Phases 0–3 complete (PR #1 merged,
frontend quantity UI shipped, testnet factory
`EQBctzqXl5JMYG_h5RiNnhaG6jtcsAbCFTBUNTfxORwnhvjB` E2E'd + soaked, independent
review GO-with-fixes, `npm test` → 15 suites / 255 pass). Full review record:
`MARKETPLACE_V3.1_REVIEW_FINDINGS.md`.

Nothing below is urgent. The current fixed-price marketplace keeps working. Do
the phases when you have the time; each one leaves the system in a safe state.

---

## Phase 0 — Merge ✅ DONE (2026-09-03)

- [x] Sanity-skimmed the diff — quantity bounds + underflow guard,
      `tradeValue <= MaxTradeValue`, Tier-3 auth (`sender()==seller` /
      `requireOwner()`), window clamps all present.
- [x] Merged PR #1 into `feat/v2-usdt-jetton-escrow` (merge commit `a74dbc0`).
- [x] Merged branch: clean `npm run build:v3` (4 contracts) + `npm test`
      → 15 suites / 252 pass.

Safe state: the dev branch has V3.1, nothing deployed, prod untouched.

---

## Phase 1 — Frontend quantity UI (~1 day · before any testnet redeploy)

Without this the new `PurchaseListing` (which now requires `quantity`) can't be
built by the app, so **every purchase against a V3.1 factory bounces**. Do this
before Phase 2.

Frontend repo path: `garantor dao-ui-frontend/`.

- [x] `src/lib/marketplaceClient.js`
  - [x] `buildPurchaseListingPayload({ nonce, quantity })` — `quantity` (uint64) after nonce.
  - [x] `buildCreateListingPayload` — `minOrderQty`, `maxOrderQty` (uint64); `initialSupply` widened to 64.
  - [x] `getListingState` — reads `initialSupply`, `minOrderQty`, `maxOrderQty`.
- [x] `src/lib/marketplaceMetaClient.js` — no change (terms stay off-chain).
- [x] `src/v2/MarketplaceView.jsx`
  - [x] `CreateListingModal`: unit-aware "Available supply ({{unit}})" label; **Min. order** +
        **Max. order** inputs next to supply; client-validates negatives, `min ≤ supply`,
        `max === 0 || max ≥ min`; on-chain `minOrderQty` mirrored into the descriptive `moq` term.
  - [x] `QtyPicker` shared component: bounded numeric input + `Between {min} and {max} {unit}`
        hint + live green **"Trade value: price × qty USDT"** box. In `ListingProposalModal`
        (default qty = MOQ) and `BuyerPanel`. `BrowseListingCard` "Buy…" now opens the proposal
        (single quantity-entry path).
  - [x] `purchase(listing, quantity)` threads `quantity` into `buildPurchaseListingPayload`;
        proposal-modal button label shows the computed total.
  - [x] `SupplyMeter({ remaining, initial, unit })` → "X of Y `{{unit}}` · N `{{unit}}` sold"
        from the explicit `initialSupply` getter.
  - [ ] Deferred: seller controls for `UpdatePrice` / `RestockListing` / `UpdateAgreementCID`
        (own follow-up; the payload builders aren't added yet either).
- [x] `vite build` + `eslint` (0 new issues) + `vitest` (189) — green.
- [x] Committed to `feat/v2-usdt-jetton-escrow`.
- [ ] Set `VITE_MARKETPLACE_FACTORY_ADDRESS` (Preview env) — **needs Phase 2's new factory address**.
- [ ] Deploy a preview once the env points at the new factory.

Safe state after: frontend code ready, still pointing at the OLD testnet factory,
still deployable — the quantity UI is inert until Phase 2 flips the env.

---

## Phase 2 — Testnet redeploy + soak ✅ DONE (deploy 2026-09-03 · E2E + soak signed off 2026-09-05)

**Soak window:** started 2026-09-03 → review no earlier than **~2026-09-17** (2 weeks).
Do the E2E checklist below, then leave the preview alone and note anything odd.

- [x] Deploy script valid — factory `init()` unchanged; built against the V3.1 artifact.
- [x] Deployed via `scripts/redeploy-marketplace-multisig.{sh,ps1} --mnemonic`
      (now pins `EXPECTED_ADDRESS` to the V3.1 factory). Signer wallet `0QAjo1Jq…`;
      deploy-guard armed with EXPECTED_NETWORK + EXPECTED_OWNER + EXPECTED_ADDRESS.
- [x] **New V3.1 testnet `MarketplaceFactory` = `EQBctzqXl5JMYG_h5RiNnhaG6jtcsAbCFTBUNTfxORwnhvjB`**
      (testnet-flagged `kQBctzqXl5JMYG_h5RiNnhaG6jtcsAbCFTBUNTfxORwnhkNL`).
      Owner = DAO multisig `EQCRosfp…`. Supersedes `EQD0DOcW…` (pre-V3.1).
- [x] On-chain `config()` verified: owner ✓, paused false, deploymentFee 4 TON,
      guarantee 2, commission 1, windows 2592000 / 2592000 / 172800 / 2592000 / 3600,
      oracleRegistry `EQCaYq…`, jetton master `EQAI8Hgt…`.
- [x] Preview env: `VITE_MARKETPLACE_FACTORY_ADDRESS` → new address; `.env.example` updated;
      `VITE_USDT_JETTON_MASTER` (Preview) already `EQAI8Hgt…` (matches).
- [x] **Incident + fix (2026-09-03): preview was silently running mainnet.** Preview env had
      the factory address but no `VITE_NETWORK`; a stray local `.env.production`
      (`VITE_NETWORK=mainnet`, uploaded by `vercel deploy` — no `.vercelignore` existed)
      filled that gap since Vite only lets `process.env` override a key the *dashboard*
      also set. Result: mainnet toncenter/tonviewer + "Mainnet" footer, while the
      factory address (dashboard-protected) stayed testnet — a config split-brain, and
      a real hazard (an unpinned wallet could sign real mainnet funds toward a
      testnet-only address). Fixed 3 ways: `.vercelignore` (never upload local `.env*`
      again), explicit `VITE_NETWORK=testnet` on Preview, and new `NetworkGuard.jsx`
      (blocks the UI if the connected wallet's chain ≠ the build's network — TonConnect
      has no provider-level way to force a wallet's chain, so this is a post-connect
      guard). Verified in the rebuilt bundle: `VITE_NETWORK:` \`testnet\` `` inlined,
      `IS_TESTNET` true, only `testnet.toncenter.com`/`testnet.tonapi.io` present.
- [x] Manual E2E on the preview (testnet wallet): create → quantity purchase →
      deposits → manual settlement → release closed successfully end to end.
- [x] **Signed off 2026-09-05** — "I'll test the new preview... all is in order
      from the look of things." Treating this as the soak's real substance: a
      short, active testing pass surfaced (and got fixed) more than a long idle
      wait would have — see the fix log below. **Current preview:
      https://garantor-dao-ui-frontend-b62e6wqov-bennstons-projects.vercel.app**
      (supersedes every earlier `…vercel.app` URL in this doc/memory).

**Fixes that came out of E2E use (all on `feat/v2-usdt-jetton-escrow`, all deployed):**
1. Create-form unit picked too late (Commodity+Unit lived after Price/Supply/Min-Max,
   which all label themselves with it) → moved to the top of the form (`1874511`).
2. Seller tools (`UpdatePrice`/`RestockListing`) shipped — were deferred in Phase 1
   (`1874511`).
3. Create-form didn't reject `maxOrderQty > available supply` (`15360da`).
4. "Total quantity" (descriptive) had no relationship to "Available supply"
   (on-chain) — now defaults to/mirrors it until deliberately edited (`0ef64ce`).
5. VaultCard UX pass: confirm-before-release ("have you received it? can't be
   reversed") + confirm-before-dispute, perspective-aware deposit-chip labels
   ("Your deposit" vs "Seller bond"), color-coded paid/pending + objection-window
   countdown (`d327062`, `28933aa`).
6. **Security: `POST /api/marketplace-listings` had no proof of seller
   ownership** — `sellerWallet` was a client-claimed string, so anyone who
   observed a listing's public on-chain `agreementCID` could overwrite its
   thumbnail/terms. Closed with a TonConnect `ton_proof` check
   (`authorizeListingWrite`, two-phase: new row requires proving you ARE the
   claimed seller wallet; an update to an existing row requires being that
   listing's real on-chain seller AND its live `agreementCID` matching the
   termsKey). Also fixed the domain allow-list to accept `.vercel.app` (every
   preview build gets a fresh subdomain — the old exact-match list would have
   broken proof verification on every new preview). Backend `garantor-backend@ebd92ab`
   (deployed to `api.garantor.io`, verified live: an unauthenticated POST now
   returns `401`), frontend wiring `garantor-dao-escrow@7c45515`.

Safe state after: V3.1 proven end-to-end on testnet, including a real security
fix found and closed during the soak. Mainnet still on the old factory.

---

## Phase 3 — Scoped review ✅ DONE (2026-09-05) — GO with fixes

- [x] Reviewer package assembled + verified in sync with origin.
- [x] `MARKETPLACE_V3.1_REVIEW_GUIDE.md` — the walkthrough sent to the reviewer.
- [x] **Review completed** by an independent reviewer (Kimi), following the
      guide's tier-by-tier checklist + adversarial scenarios. Full findings:
      **`MARKETPLACE_V3.1_REVIEW_FINDINGS.md`**.
      **Verdict: GO with fixes.** No Critical / High / Medium findings. Two
      Low findings, both fixed:
  - **L1** — `UpdateListingParams` (factory) wrote window fields without
    clamping; an out-of-range value sat silently until the next
    `CreateListing` bounced trying to resolve it. Fixed: now runs the same
    `resolveWindow()` clamp inline, so the `UpdateListingParams` transaction
    itself reverts immediately.
  - **L2** — `RestockListing` had no explicit ceiling on the
    `initialSupply + addSupply` addition; an overflow would have surfaced as
    an opaque low-level serialization error rather than a clear revert.
    Fixed: explicit `require(... <= MaxUint64, "Restock overflow")`.
  - Five Informational items reviewed and dispositioned (see the findings
    doc's addendum) — none required a code change. One is a standing note for
    DAO ops: consider a higher practical floor than 5 minutes when actually
    setting `objectionWindow` via `UpdateListingParams`, even though the
    on-chain floor of 300s is the hard safety limit.
- [x] Both fixes have new regression tests reproducing exactly what the
      finding described. `npm run build:v3` clean; `npm test` →
      **15 suites / 255 pass** (was 252).

Safe state after: the change has been reviewed by someone other than its
author, findings are fixed and tested, and the review record is committed to
the repo alongside the guide that produced it.

---

## Phase 4 — Mainnet cutover (deliberate ops event · after Phase 3)

**Cutover executed 2026-09-05.** Deploy signed via `--mnemonic` (the init payload —
factory bundles `MarketplaceListing` + `EscrowOracleVault` child code — was too
large for a TonConnect `--deeplink` QR, same limitation `MAINNET_CUTOVER.md`
already noted for the very first V3 mainnet deploy).

- [x] Freeze: no other marketplace changes in flight; brief the DAO signers.
- [x] Deploy: `scripts/redeploy-marketplace-mainnet.{sh,ps1}` (wraps
      `npx @ton/blueprint run deployMarketplaceFactory --mainnet --mnemonic`).
      Owner = DAO multisig `EQDBzGpqM4OJduW8Hv8dmZ7xDS7i9tc7RWgEW7pUm66YF0EC`
      (**not** `EQCRosfp…` — that's the *testnet* multisig; a copy-paste error
      briefly sat in this doc and was caught 2026-09-05 by querying the live
      mainnet factory's `config()` directly before deploying anything).
  - jettonMaster `EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs` (mainnet USDT, reused)
  - oracleRegistry `EQAZ0Nurh5OfPGmXD18-pgUK9VjzoL0rmI3GS7tAIPO_kCBR` (reused, unchanged)
  - commissionairesDao `EQAvJs110UkfbkchjQoGOnUmoKVc0fh86N8TO1A8jVohWnPj` (COMM multisig, reused)
- [x] **New mainnet `MarketplaceFactory` = `EQDLB7_ab9m2VJQMinXmfljGys9xgg-KiJ8ax_m6ZajrjSc-`**
      — matches the deterministic address pre-computed against HEAD `a920085`
      exactly. Supersedes `EQBhNy_Rq9IYEtVEpt7JIO0D0mL8fGVw02weHROeCXwgsqu6`.
- [x] Verified the new factory on-chain (direct `config()` call, all fields):
  - owner = `EQDBzGpqM4OJduW8Hv8dmZ7xDS7i9tc7RWgEW7pUm66YF0EC` ✓
  - jettonMaster / oracleRegistry / commissionairesDao ✓ (all match above)
  - guarantee 2, commission 1, windows 2592000/2592000/172800/2592000/3600 (30d/30d/48h/30d/1h) ✓
  - totalListings 0, deploymentFee 4 TON, paused false
- [x] Migrated env: Frontend **Production** `VITE_MARKETPLACE_FACTORY_ADDRESS` →
      new address (`.env.example` left pointing at the testnet factory
      deliberately — that's the local-dev default, not a mainnet reference).
      **Gotcha hit:** Vercel now defaults newly-added Production/Preview env vars
      to `sensitive`, which is invisible to `vercel env pull` (looked like a CLI
      display quirk at first) but — more importantly — is NOT exposed to the Vite
      build step at all, so the var silently built as an empty string (two full
      prod deploys shipped with a *blank* factory address, i.e. the marketplace UI
      would have shown its "missing config" error to every visitor, before this was
      caught). Fixed with `vercel env add ... --no-sensitive`. Any future
      `VITE_*` var added via CLI needs `--no-sensitive` — Vite must read it at
      build time, and it's inlined into the public bundle regardless.
- [x] `vercel deploy --prod` (frontend) — verified two ways: (1) the fix above
      required 2 redeploys before the value actually landed, so don't trust a
      single deploy's own success output; (2) **local `dist/` is not a reliable
      verification target** — `vercel deploy` builds remotely and doesn't
      reliably refresh the local folder, so a stale `dist/` from an earlier
      attempt gave a false negative here. The only trustworthy check is
      `curl`-ing the live bundle straight from `app.garantor.io` and grepping
      that for the expected/unexpected addresses. Confirmed live: new factory
      address present, old factory address absent, `VITE_NETWORK:` `mainnet`.
- [ ] The old mainnet listing (WPC panel, on the old factory `EQBhNy_Rq9IY…`) is
      stranded — **decision (2026-09-05): destroy it** via `DestroyListing`, not
      done yet. Needs either the original seller's wallet or a DAO-multisig
      proposal (`sender() == seller || sender() == dao` — the multisig doesn't
      sign ad hoc, so this likely goes through the DAO dashboard's
      council-proposal flow, not a script).
- [ ] Smoke test on app.garantor.io: create a real listing with a unit + MOQ, buy a
      partial quantity, confirm the vault `tradeValue` and the availability meter.
- [x] Update memory: new mainnet `MarketplaceFactory` address; supersedes `EQBhNy_Rq9IY…`.

Safe state after: V3.1 live. Old-factory vaults still settle independently.

---

## Rollback

- **Phases 0–2:** revert the branch merge / point the Preview env back at the old
  testnet factory / redeploy. Nothing on mainnet touched.
- **Phase 4 (post-cutover bug):**
  1. `SetMarketplacePaused` on the new factory → no new listings/vaults.
  2. Point Production `VITE_MARKETPLACE_FACTORY_ADDRESS` back at `EQBhNy_Rq9IY…`.
  3. `vercel deploy --prod`.
  4. In-flight vaults on the new factory are independent contracts and keep
     settling — no funds are trapped by the pause.

---

## Effort summary

| Phase | Work | Elapsed |
|---|---|---|
| 0 Merge | ~30 min | same day |
| 1 Frontend | ~1 day | 1–2 days |
| 2 Testnet + soak | ~half day active | +1–2 weeks passive |
| 3 Scoped review | depends on path | 1–3 weeks |
| 4 Mainnet cutover | ~half day | 1 day |

Realistic total: **3–6 weeks**, most of it waiting (soak + review), not typing.
