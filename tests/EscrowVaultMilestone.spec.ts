import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano }                                          from '@ton/core';
import { EscrowVaultMilestone }                           from '../build/EscrowVaultMilestone/tact_EscrowVaultMilestone';
import '@ton/test-utils';

// ─── Scenario constants (Urea N46% commodity trade) ───────────────────────────
const TRADE_ID      = 1n;
const M0_VALUE      = toNano('400');    // 20% — loading port
const M1_VALUE      = toNano('1600');   // 80% — discharge port
const TOTAL_VALUE   = M0_VALUE + M1_VALUE;
const PERF_BOND     = toNano('40');     // 2% performance bond
const ARBITRATOR_FEE = toNano('0.1');
const REFERRER_BPS  = 100;             // 1%

// Windows — all must be >= 3600 (contract enforces minimum)
const M0_REVIEW_WINDOW    = 259_200;   // 72 h buyer review
const M1_REVIEW_WINDOW    = 172_800;   // 48 h buyer review
const M0_DELIVERY_WINDOW  = 2_592_000; // 30 days seller delivery
const M1_DELIVERY_WINDOW  = 3_888_000; // 45 days seller delivery
const PRE_ACTIVATION_TIMEOUT = 604_800; // 7 days

// Referrer fee: 1% of TOTAL_VALUE = 20 TON. Buyer must deposit totalValue + referrerFee.
const REFERRER_FEE = TOTAL_VALUE * BigInt(REFERRER_BPS) / 10000n; // 20 TON

// Document hashes (SHA-256 of bill of lading / SGS inspection report)
const MOCK_BL_HASH  = BigInt('0x7f3a9c2d1e8b4f6a3c9d2e7b4f1a8c3e6d9f2b5a8c1e4b7a0d3f6c9b2e5a8d1f');
const MOCK_SGS_HASH = BigInt('0x2b8d4e1a7f3c9d5e2a8f1b4e7c0a3d6f9b2e5c8a1d4f7b0e3c6a9d2f5b8e1c4');

// ─── Suite setup ──────────────────────────────────────────────────────────────
describe('EscrowVaultMilestone — Urea N46% Smoke Tests', () => {
    let blockchain:  Blockchain;
    let factory:     SandboxContract<TreasuryContract>;
    let buyer:       SandboxContract<TreasuryContract>;
    let seller:      SandboxContract<TreasuryContract>;
    let arbitrator:  SandboxContract<TreasuryContract>;
    let referrer:    SandboxContract<TreasuryContract>;
    let vault:       SandboxContract<EscrowVaultMilestone>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        factory    = await blockchain.treasury('factory');
        buyer      = await blockchain.treasury('buyer');
        seller     = await blockchain.treasury('seller');
        arbitrator = await blockchain.treasury('arbitrator');
        referrer   = await blockchain.treasury('referrer');

        // Vault is keyed by (factory, tradeId) — same as on-chain deterministic address
        vault = blockchain.openContract(
            await EscrowVaultMilestone.fromInit(factory.address, TRADE_ID)
        );
    });

    // ─── Helper: factory sends InitMilestoneVault (deploys + configures) ──────
    async function initVault() {
        // Factory deploys vault + configures it.
        // Value covers: deployment gas only — buyer payment comes via DepositPayment.
        const initResult = await vault.send(
            factory.getSender(),
            { value: toNano('0.5') },
            {
                $$type:            'InitMilestoneVault',
                tradeId:           TRADE_ID,
                buyer:             buyer.address,
                seller:            seller.address,
                arbitrator:        arbitrator.address,
                referrer:          referrer.address,
                referrerFeeBps:    BigInt(REFERRER_BPS),
                milestoneCount:    2n,
                m0Value:           M0_VALUE,
                m1Value:           M1_VALUE,
                m0Window:          BigInt(M0_REVIEW_WINDOW),
                m1Window:          BigInt(M1_REVIEW_WINDOW),
                m0DeliveryWindow:  BigInt(M0_DELIVERY_WINDOW),
                m1DeliveryWindow:  BigInt(M1_DELIVERY_WINDOW),
                arbitratorFee:     ARBITRATOR_FEE,
                performanceBond:   PERF_BOND,
                tradeRef:          'Urea N46% 5000MT April 2025',
            }
        );
        expect(initResult.transactions).toHaveTransaction({ from: factory.address, to: vault.address, success: true });
    }

    // ─── Helper: buyer and seller fund the vault (activates it) ───────────────
    async function fundVault() {
        // Buyer deposits trade value + referrer fee (vault pays referrer from its balance)
        const buyResult = await vault.send(
            buyer.getSender(),
            { value: TOTAL_VALUE + REFERRER_FEE + toNano('0.5') },
            'DepositPayment'
        );
        expect(buyResult.transactions).toHaveTransaction({ from: buyer.address, to: vault.address, success: true });

        // Seller deposits performance bond — this activates the vault
        const bondResult = await vault.send(
            seller.getSender(),
            { value: PERF_BOND + toNano('0.1') },
            'DepositBond'
        );
        expect(bondResult.transactions).toHaveTransaction({ from: seller.address, to: vault.address, success: true });
    }

    // ─── Shared setup: init + fund ────────────────────────────────────────────
    async function setupActiveVault() {
        await initVault();
        await fundVault();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 1: Init state is correct after both deposits
    // ─────────────────────────────────────────────────────────────────────────
    it('should initialise to ACTIVE state after both deposits', async () => {
        await setupActiveVault();

        expect(await vault.getVaultState()).toBe(1n);       // ACTIVE
        expect(await vault.getActiveMilestone()).toBe(0n);  // cursor at M0
        expect(await vault.getM0State()).toBe(0n);          // M0 PENDING
        expect(await vault.getM1State()).toBe(0n);          // M1 PENDING
        expect(await vault.getSellerBonded()).toBe(true);
        expect(await vault.getBuyerFunded()).toBe(true);
        expect(await vault.getTotalValue()).toBe(TOTAL_VALUE);
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND);

        // Delivery deadline for M0 should be set (non-zero)
        const m0dd = await vault.getM0DeliveryDeadline();
        expect(m0dd).toBeGreaterThan(0n);
    });

    it('refunds buyer funding if seller never bonds before activation timeout', async () => {
        await initVault();

        const buyerBefore = await buyer.getBalance();

        await vault.send(
            buyer.getSender(),
            { value: TOTAL_VALUE + REFERRER_FEE + toNano('0.5') },
            'DepositPayment'
        );

        expect(await vault.getVaultState()).toBe(0n);
        expect(await vault.getBuyerFunded()).toBe(true);
        expect(await vault.getSellerBonded()).toBe(false);

        blockchain.now = Math.floor(Date.now() / 1000) + PRE_ACTIVATION_TIMEOUT + 3600;

        const refundResult = await vault.send(
            buyer.getSender(),
            { value: toNano('0.1') },
            'RefundPreActivationStall'
        );

        expect(refundResult.transactions).toHaveTransaction({
            from: buyer.address,
            to: vault.address,
            success: true,
        });
        expect(refundResult.transactions).toHaveTransaction({
            from: vault.address,
            to: buyer.address,
            success: true,
        });

        const buyerAfter = await buyer.getBalance();
        expect(buyerAfter).toBeGreaterThan(buyerBefore - toNano('1'));
    });

    it('refunds seller bond if buyer never funds before activation timeout', async () => {
        await initVault();

        const sellerBefore = await seller.getBalance();

        await vault.send(
            seller.getSender(),
            { value: PERF_BOND + toNano('0.1') },
            'DepositBond'
        );

        expect(await vault.getVaultState()).toBe(0n);
        expect(await vault.getSellerBonded()).toBe(true);
        expect(await vault.getBuyerFunded()).toBe(false);

        blockchain.now = Math.floor(Date.now() / 1000) + PRE_ACTIVATION_TIMEOUT + 3600;

        const refundResult = await vault.send(
            seller.getSender(),
            { value: toNano('0.1') },
            'RefundPreActivationStall'
        );

        expect(refundResult.transactions).toHaveTransaction({
            from: seller.address,
            to: vault.address,
            success: true,
        });
        expect(refundResult.transactions).toHaveTransaction({
            from: vault.address,
            to: seller.address,
            success: true,
        });

        const sellerAfter = await seller.getBalance();
        expect(sellerAfter).toBeGreaterThan(sellerBefore - toNano('0.5'));
    });

    it('sweeps and self-destructs a stuck vault even if NEITHER party ever funded it', async () => {
        await initVault();

        expect(await vault.getVaultState()).toBe(0n);
        expect(await vault.getBuyerFunded()).toBe(false);
        expect(await vault.getSellerBonded()).toBe(false);

        blockchain.now = Math.floor(Date.now() / 1000) + PRE_ACTIVATION_TIMEOUT + 3600;

        // Permissionless — a stranger can trigger the sweep.
        const stranger = await blockchain.treasury('stranger');
        const refundResult = await vault.send(
            stranger.getSender(),
            { value: toNano('0.1') },
            'RefundPreActivationStall'
        );

        expect(refundResult.transactions).toHaveTransaction({
            from: stranger.address,
            to: vault.address,
            success: true,
        });
        // Nothing was funded, so the fallback sweep target (seller) receives the
        // vault's stranded gas and the vault self-destructs.
        expect(refundResult.transactions).toHaveTransaction({
            from: vault.address,
            to: seller.address,
            success: true,
        });

        const state = await blockchain.getContract(vault.address);
        expect(state.accountState?.type).not.toBe('active');
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 2: Happy path — both milestones confirmed, vault closes GREEN
    // ─────────────────────────────────────────────────────────────────────────
    it('[HAPPY PATH] both milestones confirmed → vault CLOSED, seller paid, bond returned', async () => {
        await setupActiveVault();

        const sellerBefore   = await seller.getBalance();
        const referrerBefore = await referrer.getBalance();

        // ── M0: seller submits docs, buyer confirms ──
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        expect(await vault.getM0State()).toBe(1n); // CONFIRMING

        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 0n });
        expect(await vault.getM0State()).toBe(2n);          // DONE
        expect(await vault.getActiveMilestone()).toBe(1n);  // cursor advanced to M1

        // Referrer receives fee on first release
        expect(await referrer.getBalance()).toBeGreaterThan(referrerBefore);

        // M1 delivery deadline should now be set
        const m1dd = await vault.getM1DeliveryDeadline();
        expect(m1dd).toBeGreaterThan(0n);

        // ── M1: seller submits docs, buyer confirms ──
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });
        expect(await vault.getM1State()).toBe(1n); // CONFIRMING

        // Capture seller balance right before the closing tx
        const sellerBeforeClose = await seller.getBalance();

        // Buyer confirms M1 — this tx closes + destroys the vault
        const closeResult = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 1n });

        // Vault sent M1 value + bond to seller (two outgoing messages in close)
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: seller.address, success: true,
        });
        // Vault swept residue to buyer (self-destruct)
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });

        // Seller received M1_VALUE + PERF_BOND in the closing tx
        const sellerAfterClose = await seller.getBalance();
        const expectedMin = M1_VALUE + PERF_BOND - toNano('0.5');
        expect(sellerAfterClose - sellerBeforeClose).toBeGreaterThan(expectedMin);

        // Seller's total gain across the trade covers M0 + M1 + bond (minus gas)
        const sellerTotalGain = sellerAfterClose - sellerBefore;
        expect(sellerTotalGain).toBeGreaterThan(M0_VALUE + M1_VALUE + PERF_BOND - toNano('2'));
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 3: Dispute path — M0 disputed, M1 runs independently, then resolved
    // ─────────────────────────────────────────────────────────────────────────
    it('[DISPUTE PATH] M0 disputed → M1 proceeds independently → both resolve CLOSED', async () => {
        await setupActiveVault();

        // ── M0: seller submits, buyer disputes ──
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        expect(await vault.getM0State()).toBe(1n); // CONFIRMING

        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'BL quantity mismatch' });

        expect(await vault.getM0State()).toBe(3n);          // DISPUTED
        expect(await vault.getActiveMilestone()).toBe(1n);  // cursor ADVANCED — M1 can proceed
        expect(await vault.getVaultState()).toBe(1n);       // still ACTIVE

        // M1 delivery deadline starts only once the M0 dispute is actually resolved
        const m1dd = await vault.getM1DeliveryDeadline();
        expect(m1dd).toBe(0n);

        // ── M1: runs in parallel while M0 is in arbitration ──
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });
        expect(await vault.getM1State()).toBe(1n); // CONFIRMING

        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 1n });
        expect(await vault.getM1State()).toBe(2n); // DONE
        // Vault stays open — M0 dispute not yet resolved
        expect(await vault.getVaultState()).toBe(1n);

        // ── Arbitrator resolves M0 (seller wins) — this closes the vault ──
        const sellerBefore = await seller.getBalance();
        const closeResult = await vault.send(arbitrator.getSender(), { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: true });

        // Vault sends M0 value + bond to seller, sweeps residue to buyer (destroys)
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: seller.address, success: true,
        });
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });

        // Seller received M0 value + bond at close (two messages)
        const sellerAfter = await seller.getBalance();
        const expectedMin = M0_VALUE + PERF_BOND - toNano('0.5');
        expect(sellerAfter - sellerBefore).toBeGreaterThan(expectedMin);
    });

    it('starts the M1 delivery deadline only after the M0 dispute is resolved', async () => {
        await setupActiveVault();

        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'Waiting on arbitrator' });

        expect(await vault.getM1DeliveryDeadline()).toBe(0n);

        await vault.send(arbitrator.getSender(), { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: true });

        expect(await vault.getM1DeliveryDeadline()).toBeGreaterThan(0n);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 4: Dispute path — M1 disputed, buyer wins, bond slashed
    // ─────────────────────────────────────────────────────────────────────────
    it('[DISPUTE PATH] M1 disputed, buyer wins → M1 value + bond refunded to buyer → CLOSED', async () => {
        await setupActiveVault();

        // Fast-path M0
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 0n });

        // M1: seller submits, buyer disputes
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 1n, reason: 'Quality below spec — moisture high' });
        expect(await vault.getM1State()).toBe(3n); // DISPUTED

        const buyerBefore = await buyer.getBalance();

        // Arbitrator rules for buyer — vault closes (m0=2 DONE, m1=2 DONE after resolution)
        const closeResult = await vault.send(arbitrator.getSender(), { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 1n, releaseToSeller: false });

        // Vault sends M1 value + slashed bond to buyer
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });

        // Buyer gained M1_VALUE + PERF_BOND (slashed)
        const buyerAfter = await buyer.getBalance();
        const expectedMin = M1_VALUE + PERF_BOND - toNano('0.5');
        expect(buyerAfter - buyerBefore).toBeGreaterThan(expectedMin);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 5: BuyerClaimAbandoned — seller misses M0 delivery deadline
    // ─────────────────────────────────────────────────────────────────────────
    it('buyer can claim abandoned if seller misses M0 delivery deadline', async () => {
        await setupActiveVault();

        // Advance time past M0 delivery deadline
        const m0dd = Number(await vault.getM0DeliveryDeadline());
        blockchain.now = m0dd + 3600;

        const buyerBefore = await buyer.getBalance();

        const result = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerClaimAbandoned', index: 0n });
        expect(result.transactions).toHaveTransaction({ from: buyer.address, to: vault.address, success: true });

        expect(await vault.getM0State()).toBe(2n);          // DONE (refunded)
        expect(await vault.getActiveMilestone()).toBe(1n);  // cursor advanced

        // Only M0's proportional share of the bond is slashed to buyer; the rest
        // stays as seller collateral for M1, matching arbitration's slash math.
        const m0BondSlash = PERF_BOND * M0_VALUE / TOTAL_VALUE;
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND - m0BondSlash);

        // Buyer received M0 value + M0's bond share
        const buyerAfter = await buyer.getBalance();
        const expectedMin = M0_VALUE + m0BondSlash - toNano('0.5');
        expect(buyerAfter - buyerBefore).toBeGreaterThan(expectedMin);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 6: Auto-release on review timeout (CheckTimeout)
    // ─────────────────────────────────────────────────────────────────────────
    it('CheckTimeout auto-releases M0 after buyer review window expires', async () => {
        await setupActiveVault();

        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        expect(await vault.getM0State()).toBe(1n); // CONFIRMING

        // Fast-forward past M0 review window
        blockchain.now = Math.floor(Date.now() / 1000) + M0_REVIEW_WINDOW + 3600;

        const sellerBefore = await seller.getBalance();

        const result = await vault.send(buyer.getSender(), { value: toNano('0.1') }, 'CheckTimeout');
        expect(result.transactions).toHaveTransaction({ to: vault.address, success: true });

        expect(await vault.getM0State()).toBe(2n);          // auto-released
        expect(await vault.getActiveMilestone()).toBe(1n);  // cursor advanced

        const sellerAfter = await seller.getBalance();
        expect(sellerAfter).toBeGreaterThan(sellerBefore);
    });

    it('CheckTimeout force-splits a disputed milestone after the arbitrator timeout', async () => {
        await setupActiveVault();

        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'Arbitrator silent' });

        const disputeDeadline = Number(await vault.getM0DisputeDeadline());
        expect(disputeDeadline).toBeGreaterThan(0);

        const buyerBefore = await buyer.getBalance();
        const sellerBefore = await seller.getBalance();

        blockchain.now = disputeDeadline + 3600;

        const result = await vault.send(buyer.getSender(), { value: toNano('0.1') }, 'CheckTimeout');
        expect(result.transactions).toHaveTransaction({ from: buyer.address, to: vault.address, success: true });

        expect(await vault.getM0State()).toBe(2n);
        expect(await vault.getM0DisputeDeadline()).toBe(0n);
        expect(await vault.getM1DeliveryDeadline()).toBeGreaterThan(0n);

        const buyerAfter = await buyer.getBalance();
        const sellerAfter = await seller.getBalance();
        const halfM0 = M0_VALUE / 2n;
        expect(buyerAfter - buyerBefore).toBeGreaterThan(halfM0 - toNano('0.5'));
        expect(sellerAfter - sellerBefore).toBeGreaterThan(halfM0 - toNano('0.5'));
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 7: Bond is NOT double-spent — released once at vault close only
    // ─────────────────────────────────────────────────────────────────────────
    it('bond is held until vault close — not returned during releaseMilestone1', async () => {
        await setupActiveVault();

        // Complete M0 happy path
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 0n });

        // Bond must still be non-zero BEFORE M1 completes
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND);

        // Confirm M1 — the closing tx sends M1_VALUE + bond to seller in one atomic close
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });

        const sellerBefore = await seller.getBalance();

        // Buyer confirms M1 — vault closes and self-destructs
        const closeResult = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 1n });

        // Two outgoing messages to seller: M1_VALUE and then PERF_BOND (from checkVaultClose)
        const sellerTxs = closeResult.transactions.filter(
            tx => tx.outMessages && [...tx.outMessages.values()].some(m => m.info.dest?.toString() === seller.address.toString())
        );
        expect(sellerTxs.length).toBeGreaterThan(0);

        // Seller received M1_VALUE + PERF_BOND in the closing tx
        const sellerAfter = await seller.getBalance();
        const expectedMin = M1_VALUE + PERF_BOND - toNano('0.5');
        expect(sellerAfter - sellerBefore).toBeGreaterThan(expectedMin);
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 8: Access control — non-seller cannot call SellerConfirmMilestone
    // ─────────────────────────────────────────────────────────────────────────
    it('rejects SellerConfirmMilestone from non-seller', async () => {
        await setupActiveVault();

        const result = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });

        expect(result.transactions).toHaveTransaction({
            from:    buyer.address,
            to:      vault.address,
            success: false,
        });
        expect(await vault.getM0State()).toBe(0n); // unchanged
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 9: Cannot confirm non-active milestone (M1 while M0 is active)
    // ─────────────────────────────────────────────────────────────────────────
    it('rejects SellerConfirmMilestone for non-active milestone index', async () => {
        await setupActiveVault();
        // activeMilestone = 0, so trying index 1 must fail
        const result = await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });

        expect(result.transactions).toHaveTransaction({
            from:    seller.address,
            to:      vault.address,
            success: false,
        });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 10: Rejects zero doc hash
    // ─────────────────────────────────────────────────────────────────────────
    it('rejects SellerConfirmMilestone with zero doc hash', async () => {
        await setupActiveVault();

        const result = await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: 0n });

        expect(result.transactions).toHaveTransaction({
            from:    seller.address,
            to:      vault.address,
            success: false,
        });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST 11: InitMilestoneVault rejected from non-factory sender
    // ─────────────────────────────────────────────────────────────────────────
    it('rejects InitMilestoneVault from non-factory sender', async () => {
        await initVault(); // deploy via factory first

        // Try to re-init from buyer (should fail: "Already initialised" or "Only factory can init")
        const result = await vault.send(
            buyer.getSender(),
            { value: toNano('0.5') },
            {
                $$type:            'InitMilestoneVault',
                tradeId:           TRADE_ID,
                buyer:             buyer.address,
                seller:            seller.address,
                arbitrator:        arbitrator.address,
                referrer:          referrer.address,
                referrerFeeBps:    BigInt(REFERRER_BPS),
                milestoneCount:    2n,
                m0Value:           M0_VALUE,
                m1Value:           M1_VALUE,
                m0Window:          BigInt(M0_REVIEW_WINDOW),
                m1Window:          BigInt(M1_REVIEW_WINDOW),
                m0DeliveryWindow:  BigInt(M0_DELIVERY_WINDOW),
                m1DeliveryWindow:  BigInt(M1_DELIVERY_WINDOW),
                arbitratorFee:     ARBITRATOR_FEE,
                performanceBond:   PERF_BOND,
                tradeRef:          'Fake re-init',
            }
        );

        expect(result.transactions).toHaveTransaction({
            from:    buyer.address,
            to:      vault.address,
            success: false,
        });
    });

    // ═════════════════════════════════════════════════════════════════════════
    // PROPORTIONAL BOND SLASH TESTS
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Bond arithmetic:
    //   PERF_BOND   = 40 TON
    //   M0_VALUE    = 400 TON  (20% of trade)
    //   M1_VALUE    = 1600 TON (80% of trade)
    //   TOTAL_VALUE = 2000 TON
    //   m0BondSlash = 40 * 400 / 2000 = 8 TON  (M0 share)
    //   remainingBond = 40 - 8 = 32 TON         (held for M1)

    it('[PROPORTIONAL SLASH] M0 buyer-wins dispute slashes only M0 share of bond; M1 proceeds with remaining bond', async () => {
        await setupActiveVault();

        const m0BondSlash   = PERF_BOND * M0_VALUE / TOTAL_VALUE;  // 8 TON
        const remainingBond = PERF_BOND - m0BondSlash;              // 32 TON

        // M0: seller submits, buyer disputes
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'Short shipment — BL quantity mismatch' });

        expect(await vault.getM0State()).toBe(3n); // DISPUTED

        const buyerBefore = await buyer.getBalance();

        // Arbitrator rules for buyer
        const resolveResult = await vault.send(arbitrator.getSender(), { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: false });

        // Vault sends M0_VALUE + proportional bond slash to buyer
        expect(resolveResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });

        const buyerAfter = await buyer.getBalance();
        expect(buyerAfter - buyerBefore).toBeGreaterThan(M0_VALUE + m0BondSlash - toNano('0.5'));

        // KEY assertion: only M0 share slashed — 32 TON remains in vault for M1
        expect(await vault.getPerformanceBond()).toBe(remainingBond);

        // Vault still ACTIVE — M1 can proceed
        expect(await vault.getVaultState()).toBe(1n);
        expect(await vault.getM1DeliveryDeadline()).toBeGreaterThan(0n);

        // ── M1 proceeds and completes normally ──
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });

        const sellerBefore = await seller.getBalance();

        const closeResult = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerConfirmMilestone', index: 1n });

        // Vault closes: seller receives M1_VALUE + remaining bond
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: seller.address, success: true,
        });

        const sellerAfter = await seller.getBalance();
        expect(sellerAfter - sellerBefore).toBeGreaterThan(M1_VALUE + remainingBond - toNano('0.5'));
    });

    it('[PROPORTIONAL SLASH] full bond is NOT consumed — only M0-proportional share is slashed', async () => {
        await setupActiveVault();

        const m0BondSlash   = PERF_BOND * M0_VALUE / TOTAL_VALUE;  // 8 TON
        const remainingBond = PERF_BOND - m0BondSlash;              // 32 TON

        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'Moisture above specification' });
        await vault.send(arbitrator.getSender(), { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: false });

        const bondAfter = await vault.getPerformanceBond();

        // Old behaviour slashed PERF_BOND (40 TON) entirely — new behaviour slashes only 8 TON
        expect(bondAfter).toBe(remainingBond);      // exactly 32 TON remains
        expect(bondAfter).toBeLessThan(PERF_BOND);  // some was slashed
        expect(bondAfter).toBeGreaterThan(0n);       // but NOT all
    });

    // ═════════════════════════════════════════════════════════════════════════
    // MUTUAL CANCEL (FORCE MAJEURE) TESTS
    // ═════════════════════════════════════════════════════════════════════════

    it('[FORCE MAJEURE] M0 mutual cancel: buyer refunded, bond intact, M1 delivery starts', async () => {
        await setupActiveVault();

        // Initially no consent
        expect(await vault.getM0CancelBuyer()).toBe(false);
        expect(await vault.getM0CancelSeller()).toBe(false);

        // Buyer registers consent — nothing executes yet
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });

        expect(await vault.getM0CancelBuyer()).toBe(true);
        expect(await vault.getM0State()).toBe(0n);          // still PENDING — waiting for seller
        expect(await vault.getActiveMilestone()).toBe(0n);  // cursor unchanged

        const buyerBefore = await buyer.getBalance();

        // Seller registers consent → both consented → M0 cancelled
        const cancelResult = await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });

        // Vault sends M0_VALUE refund to buyer
        expect(cancelResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });

        expect(await vault.getM0State()).toBe(2n);          // DONE
        expect(await vault.getActiveMilestone()).toBe(1n);  // cursor advanced to M1

        const buyerAfter = await buyer.getBalance();
        expect(buyerAfter - buyerBefore).toBeGreaterThan(M0_VALUE - toNano('0.5'));

        // Bond is NOT slashed — force majeure is no-fault
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND);

        // M1 delivery deadline now open
        expect(await vault.getM1DeliveryDeadline()).toBeGreaterThan(0n);

        // Vault stays open — M1 still pending
        expect(await vault.getVaultState()).toBe(1n);
    });

    it('[FORCE MAJEURE] single-party consent does not execute cancel', async () => {
        await setupActiveVault();

        // Only seller consents
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });

        expect(await vault.getM0CancelSeller()).toBe(true);
        expect(await vault.getM0CancelBuyer()).toBe(false);

        // Nothing executed — M0 still pending, cursor unmoved, bond untouched
        expect(await vault.getM0State()).toBe(0n);
        expect(await vault.getActiveMilestone()).toBe(0n);
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND);
    });

    it('[FORCE MAJEURE] both milestones mutually cancelled → full refund to buyer, bond returned to seller', async () => {
        await setupActiveVault();

        const buyerBefore  = await buyer.getBalance();
        const sellerBefore = await seller.getBalance();

        // ── Cancel M0 ──
        await vault.send(buyer.getSender(),  { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });

        expect(await vault.getM0State()).toBe(2n);
        expect(await vault.getPerformanceBond()).toBe(PERF_BOND); // bond still intact after M0 cancel

        // ── Cancel M1 — this closes the vault ──
        await vault.send(buyer.getSender(),  { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 1n });
        const closeResult = await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 1n });

        // M1_VALUE sent to buyer on cancel
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: buyer.address, success: true,
        });
        // Bond returned to seller at checkVaultClose
        expect(closeResult.transactions).toHaveTransaction({
            from: vault.address, to: seller.address, success: true,
        });

        // Buyer received M0_VALUE + M1_VALUE (full refund, minus gas)
        const buyerAfter = await buyer.getBalance();
        expect(buyerAfter - buyerBefore).toBeGreaterThan(TOTAL_VALUE - toNano('1'));

        // Seller received bond back (force majeure — no penalty)
        const sellerAfter = await seller.getBalance();
        expect(sellerAfter - sellerBefore).toBeGreaterThan(PERF_BOND - toNano('0.5'));
    });

    it('[FORCE MAJEURE] MutualCancelMilestone rejected when M0 is in DISPUTED state', async () => {
        await setupActiveVault();

        // Raise a dispute on M0
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'Dispute already raised' });

        expect(await vault.getM0State()).toBe(3n); // DISPUTED

        // MutualCancel cannot bypass active arbitration
        const result = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });

        expect(result.transactions).toHaveTransaction({
            from: buyer.address, to: vault.address, success: false,
        });
        expect(await vault.getM0State()).toBe(3n); // still DISPUTED
    });

    it('[MED-4] referrer is NOT paid when M1 dispute is ruled for buyer', async () => {
        // MED-4 fix: payReferrer() moved inside the releaseToSeller=true branch only.
        // Strategy: dispute BOTH M0 and M1 independently, then resolve M1 to buyer.
        // Vault stays alive (M0 still DISPUTED), so we can read referrerPaid after.
        await setupActiveVault();

        // M0: seller confirms, buyer disputes → activeMilestone advances to 1
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'M0 loading docs rejected' });
        expect(await vault.getM0State()).toBe(3n); // DISPUTED

        // M1: seller confirms independently, buyer disputes M1 too
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 1n, docHash: MOCK_SGS_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 1n, reason: 'M1 discharge docs rejected' });
        expect(await vault.getM1State()).toBe(3n); // DISPUTED

        // Arbitrator resolves M1 → BUYER wins
        const result = await vault.send(
            arbitrator.getSender(),
            { value: toNano('0.1') },
            { $$type: 'ArbitratorResolveMilestone', index: 1n, releaseToSeller: false }
        );

        // Vault is still alive — M0 is still DISPUTED so checkVaultClose doesn't fire
        expect(await vault.getM0State()).toBe(3n); // M0 still unresolved
        expect(await vault.getM1State()).toBe(2n); // M1 resolved (DONE)

        // Referrer must NOT have been paid (buyer won M1, no delivery occurred)
        expect(await vault.getReferrerPaid()).toBe(false);
        expect(result.transactions).not.toHaveTransaction({
            to: referrer.address, success: true,
        });
    });

    it('[MED-5] mutual cancel consent can be retracted before counterparty agrees', async () => {
        // MED-5 fix: flags toggle on re-send, allowing a party to retract before
        // the counterparty has also consented.
        await setupActiveVault();

        // Buyer signals intent to cancel M0
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });
        expect(await vault.getM0CancelBuyer()).toBe(true);

        // Buyer changes mind — re-sends to retract
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });
        expect(await vault.getM0CancelBuyer()).toBe(false); // toggled back

        // Seller now consents — but buyer already retracted, so cancel does NOT execute
        const result = await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'MutualCancelMilestone', index: 0n });
        expect(await vault.getM0State()).toBe(0n); // still PENDING — cancel did not fire
        expect(await vault.getVaultState()).toBe(1n); // vault still ACTIVE
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TEST: Mutual dispute settlement (ProposeMilestoneSettlement)
    // ─────────────────────────────────────────────────────────────────────────

    // Helper: drive M0 into DISPUTED state
    async function disputeM0() {
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'SellerConfirmMilestone', index: 0n, docHash: MOCK_BL_HASH });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'BuyerDisputeMilestone', index: 0n, reason: 'BL quantity mismatch' });
        expect(await vault.getM0State()).toBe(3n); // DISPUTED
    }

    it('[SETTLEMENT] disputed M0 settled 70/30 by mutual consent — exact conservation', async () => {
        await setupActiveVault();
        await disputeM0();

        // Buyer proposes 70% to buyer; not executed yet (no counterparty match)
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 70n });
        expect(await vault.getM0SettleProposed()).toBe(true);
        expect(await vault.getM0SettleBuyerPct()).toBe(70n);
        expect(await vault.getM0State()).toBe(3n); // still DISPUTED — not executed

        // Seller approves the same 70% → executes
        const buyerBefore  = await buyer.getBalance();
        const sellerBefore = await seller.getBalance();
        const res = await vault.send(seller.getSender(), { value: toNano('0.2') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 70n });

        expect(res.transactions).toHaveTransaction({ from: vault.address, to: buyer.address,  success: true });
        expect(res.transactions).toHaveTransaction({ from: vault.address, to: seller.address, success: true });

        expect(await vault.getM0State()).toBe(2n);    // DONE
        expect(await vault.getVaultState()).toBe(1n); // still ACTIVE (M1 pending)

        // buyerShare = 400 * 70/100 = 280; seller gets remainder 120.
        // Buyer paid no gas on the executing tx (seller sent it) → receives full 280.
        const buyerGain = await buyer.getBalance() - buyerBefore;
        expect(buyerGain).toBeGreaterThan(toNano('279.5'));
        expect(buyerGain).toBeLessThanOrEqual(toNano('280'));

        // Seller sent the executing tx (paid gas) and receives 120.
        const sellerGain = await seller.getBalance() - sellerBefore;
        expect(sellerGain).toBeGreaterThan(toNano('119'));
        expect(sellerGain).toBeLessThanOrEqual(toNano('120'));

        // Settling M0 must start M1's delivery window so M1 cannot deadlock.
        expect(await vault.getM1DeliveryDeadline()).toBeGreaterThan(0n);
    });

    it('[SETTLEMENT] a single proposal does not execute — counterparty must echo', async () => {
        await setupActiveVault();
        await disputeM0();

        // Buyer proposes twice — still no execution without seller's matching approval
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 50n });
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 50n });
        expect(await vault.getM0State()).toBe(3n); // still DISPUTED
    });

    it('[SETTLEMENT] a mismatched percentage becomes a counter-offer, not an execution', async () => {
        await setupActiveVault();
        await disputeM0();

        // Buyer proposes 80%; seller responds with 40% (counter) → no execution
        await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 80n });
        await vault.send(seller.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 40n });
        expect(await vault.getM0State()).toBe(3n);              // still DISPUTED
        expect(await vault.getM0SettleBuyerPct()).toBe(40n);    // seller's counter is now pending

        // Buyer accepts the seller's 40% → executes
        const res = await vault.send(buyer.getSender(), { value: toNano('0.2') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 40n });
        expect(res.transactions).toHaveTransaction({ from: vault.address, to: seller.address, success: true });
        expect(await vault.getM0State()).toBe(2n); // DONE
    });

    it('[SETTLEMENT] rejects a non-party and a non-disputed milestone', async () => {
        await setupActiveVault();

        // M0 is PENDING (not disputed) → settlement rejected
        const pendingRes = await vault.send(buyer.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 50n });
        expect(pendingRes.transactions).toHaveTransaction({
            from: buyer.address, to: vault.address, success: false,
        });

        // Drive M0 to disputed, then a stranger tries to settle → rejected
        await disputeM0();
        const stranger = await blockchain.treasury('stranger');
        const strangerRes = await vault.send(stranger.getSender(), { value: toNano('0.1') },
            { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 50n });
        expect(strangerRes.transactions).toHaveTransaction({
            from: stranger.address, to: vault.address, success: false,
        });
        expect(await vault.getM0State()).toBe(3n); // unchanged
    });
});
