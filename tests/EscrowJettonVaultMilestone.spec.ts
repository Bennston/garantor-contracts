import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell } from '@ton/core';
import { EscrowJettonMilestoneFactory } from '../build/EscrowJettonMilestoneFactory/tact_EscrowJettonMilestoneFactory';
import { EscrowJettonVaultMilestone } from '../build/EscrowJettonMilestoneFactory/tact_EscrowJettonVaultMilestone';
import { MockJettonMaster } from '../build/MockJettonMaster/tact_MockJettonMaster';
import { MockJettonWallet } from '../build/MockJettonMaster/tact_MockJettonWallet';
import '@ton/test-utils';

// USDT has 6 decimals.
const USDT = (n: number) => BigInt(Math.round(n * 1_000_000));

// Milestone trade: 6 USDT M0 + 4 USDT M1 = 10 USDT total.
const M0_VALUE      = USDT(6);
const M1_VALUE      = USDT(4);
const BOND          = USDT(0.2);   // seller's performance bond
// Factory default disputeFeeBps = 100 (1% of totalValue). The buyer PREFUNDS this
// and gets it back at close unless a dispute is actually arbitrated.
const DISPUTE_FEE   = (M0_VALUE + M1_VALUE) * 100n / 10000n;   // 0.1 USDT
const BUYER_FUNDING = M0_VALUE + M1_VALUE + DISPUTE_FEE;
const M0_WINDOW     = 3600;        // 1 hour review window
const M1_WINDOW     = 3600;
const M0_DEL_WIN    = 86400;       // 1 day delivery window
const M1_DEL_WIN    = 86400;
const DOC0          = 0xdeadbeef0001n;
const DOC1          = 0xdeadbeef0002n;

const EMPTY_FWD = beginCell().storeUint(0, 1).endCell().asSlice();

describe('EscrowJettonVaultMilestone (V2 / USDT milestone)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let owner: SandboxContract<TreasuryContract>;    // factory owner = arbitrator
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let referrer: SandboxContract<TreasuryContract>;
    let stranger: SandboxContract<TreasuryContract>;

    let master: SandboxContract<MockJettonMaster>;
    let factory: SandboxContract<EscrowJettonMilestoneFactory>;
    let vault: SandboxContract<EscrowJettonVaultMilestone>;

    let NOW: number;

    const mint = async (to: Address, amount: bigint) => {
        await master.send(deployer.getSender(), { value: toNano('0.1') }, {
            $$type: 'MockMint', to, amount,
        });
    };

    const walletOf = async (addr: Address) =>
        blockchain.openContract(await MockJettonWallet.fromInit(addr, master.address));

    const balanceOf = async (addr: Address): Promise<bigint> => {
        const w = await walletOf(addr);
        const state = await blockchain.getContract(w.address);
        if (state.accountState?.type !== 'active') return 0n;
        return await w.getBalance();
    };

    const depositJettons = async (sender: SandboxContract<TreasuryContract>, amount: bigint) => {
        const w = await walletOf(sender.address);
        return w.send(sender.getSender(), { value: toNano('0.3') }, {
            $$type: 'JettonTransfer',
            queryId: 0n,
            amount,
            destination: vault.address,
            responseDestination: sender.address,
            customPayload: null,
            forwardTonAmount: toNano('0.1'),
            forwardPayload: EMPTY_FWD,
        });
    };

    // Fund both parties: buyer pays totalValue, seller pays bond.
    const fundBoth = async () => {
        await depositJettons(seller, BOND);
        await depositJettons(buyer, BUYER_FUNDING);
    };

    // Confirm M0 fully (seller then buyer).
    const confirmM0 = async () => {
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerConfirmMilestone',  index: 0n });
    };

    // Confirm M1 fully.
    const confirmM1 = async () => {
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 1n, docHash: DOC1 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerConfirmMilestone',  index: 1n });
    };

    let __msNonce = 0n;
    const createEscrow = async (opts: { referrerFeeBps?: bigint; nonce?: bigint } = {}) => {
        const refBps = opts.referrerFeeBps ?? 0n;
        const nonce = opts.nonce ?? (__msNonce += 1n);
        return factory.send(buyer.getSender(), { value: toNano('3') }, {
            $$type: 'CreateJettonMilestoneEscrow',
            buyer:            buyer.address,
            seller:           seller.address,
            arbitrator:       owner.address,   // ignored — factory pins to owner
            referrer:         referrer.address,
            referrerFeeBps:   refBps,
            milestoneCount:   2n,
            jettonMaster:     master.address,
            m0Value:          M0_VALUE,
            m1Value:          M1_VALUE,
            m0Window:         BigInt(M0_WINDOW),
            m1Window:         BigInt(M1_WINDOW),
            m0DeliveryWindow: BigInt(M0_DEL_WIN),
            m1DeliveryWindow: BigInt(M1_DEL_WIN),
            performanceBond:  BOND,
            tradeRef:         'test-trade-001',
            nonce,
        });
    };

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        NOW = Math.floor(Date.now() / 1000);
        blockchain.now = NOW;

        deployer  = await blockchain.treasury('deployer');
        owner     = await blockchain.treasury('owner');
        buyer     = await blockchain.treasury('buyer');
        seller    = await blockchain.treasury('seller');
        referrer  = await blockchain.treasury('referrer');
        stranger  = await blockchain.treasury('stranger');

        // Deploy mock USDT master.
        const content = beginCell().storeUint(0, 8).storeBit(false).endCell();
        master = blockchain.openContract(await MockJettonMaster.fromInit(deployer.address, content));
        await mint(buyer.address,  USDT(1000));
        await mint(seller.address, USDT(1000));

        // Deploy factory (owner + jettonMaster).
        factory = blockchain.openContract(
            await EscrowJettonMilestoneFactory.fromInit(owner.address, master.address),
        );
        // Fund factory so it has operational reserve.
        const topup = await blockchain.treasury('topup');
        await topup.send({ to: factory.address, value: toNano('5'), bounce: false });

        // Create the milestone escrow (tradeId 1).
        await createEscrow();

        vault = blockchain.openContract(
            await EscrowJettonVaultMilestone.fromInit(factory.address, 1n),
        );
    });

    // ─── Initialisation ──────────────────────────────────────────────────────────

    it('resolves its jetton wallet after init', async () => {
        expect(await vault.getWalletResolved()).toBe(true);
        const expected = await master.getGetWalletAddress(vault.address);
        expect((await vault.getJettonWallet()).equals(expected)).toBe(true);
        expect(await vault.getVaultState()).toBe(0n);    // inactive — no deposits yet
        expect(await vault.getTotalValue()).toBe(M0_VALUE + M1_VALUE);
        expect(await vault.getPerformanceBond()).toBe(BOND);
    });

    it('activates vault after both parties fund', async () => {
        await fundBoth();
        expect(await vault.getVaultState()).toBe(1n);   // active
        expect(await vault.getSellerBonded()).toBe(true);
        expect(await vault.getBuyerFunded()).toBe(true);
        expect(await vault.getActiveMilestone()).toBe(0n);
        // Vault's jetton wallet holds total + bond + the buyer's prefunded
        // arbitration fee (refunded at close unless a dispute is arbitrated).
        expect(await balanceOf(vault.address)).toBe(M0_VALUE + M1_VALUE + BOND + DISPUTE_FEE);
        expect(await vault.getDisputeFee()).toBe(DISPUTE_FEE);
        expect(await vault.getDisputeFeePaid()).toBe(false);
    });

    // ─── Happy path ───────────────────────────────────────────────────────────────

    it('happy path: M0 confirm → M1 confirm → bond returned → vault closed', async () => {
        const sellerStart = await balanceOf(seller.address);
        const buyerStart  = await balanceOf(buyer.address);

        await fundBoth();

        // ── Milestone 0 ──
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        expect(await vault.getM0State()).toBe(1n);  // confirming
        expect(await vault.getM0DocHash()).toBe(DOC0);

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerConfirmMilestone', index: 0n });
        expect(await vault.getM0State()).toBe(2n);  // done
        expect(await vault.getActiveMilestone()).toBe(1n);

        // Seller received M0 payout immediately.
        expect(await balanceOf(seller.address)).toBe(sellerStart - BOND + M0_VALUE);

        // ── Milestone 1 ──
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 1n, docHash: DOC1 });
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerConfirmMilestone', index: 1n });

        // Vault self-destructs on close — verify by balance outcomes.
        // Seller received M0 + M1 + bond back; buyer spent totalValue.
        expect(await balanceOf(seller.address)).toBe(sellerStart + M0_VALUE + M1_VALUE);
        expect(await balanceOf(buyer.address)).toBe(buyerStart - M0_VALUE - M1_VALUE);
        // Vault's jetton wallet drained.
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    // ─── Review window timeout auto-release ──────────────────────────────────────

    it('CheckTimeout auto-releases M0 after review window expires', async () => {
        await fundBoth();
        // Seller confirms M0 delivery.
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        expect(await vault.getM0State()).toBe(1n);

        // Advance past the review window.
        blockchain.now = NOW + M0_WINDOW + 10;

        // Anyone can trigger timeout.
        await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'CheckTimeout');
        expect(await vault.getM0State()).toBe(2n);
        expect(await vault.getActiveMilestone()).toBe(1n);

        // Seller received M0 payout.
        expect(await balanceOf(seller.address)).toBe(USDT(1000) - BOND + M0_VALUE);
    });

    // ─── Buyer dispute then arbitrator resolves ───────────────────────────────────

    it('arbitrator resolves M0 dispute in seller favour', async () => {
        await fundBoth();
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'not delivered' });
        expect(await vault.getM0State()).toBe(3n);  // disputed

        // Owner (pinned arbitrator) resolves in seller's favour.
        await vault.send(owner.getSender(), { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: true });
        expect(await vault.getM0State()).toBe(2n);

        // Seller received M0; M1 delivery deadline is now set.
        expect(await balanceOf(seller.address)).toBe(USDT(1000) - BOND + M0_VALUE);
        expect(await vault.getActiveMilestone()).toBe(1n);
    });

    it('arbitrator resolves M0 dispute in buyer favour — slashes bond', async () => {
        await fundBoth();
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'fraud' });

        await vault.send(owner.getSender(), { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: false });
        expect(await vault.getM0State()).toBe(2n);

        // Buyer gets M0 value back + a pro-rata bond slash.
        // Bond slash = bond * m0Value / totalValue = 0.2 * 6/10 = 0.12 USDT.
        const bondSlash = BOND * M0_VALUE / (M0_VALUE + M1_VALUE);
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - BUYER_FUNDING + M0_VALUE + bondSlash);
        expect(await vault.getPerformanceBond()).toBe(BOND - bondSlash);
    });

    // ─── Prefunded arbitration fee ───────────────────────────────────────────────
    // V1 paid the arbitrator from the vault's spare TON; the jetton port dropped
    // that outright, leaving milestone arbitration uncompensated. These pin the
    // replacement: buyer prefunds, council is paid only for work actually done.

    it('pays the prefunded arbitration fee to the arbitrator on an arbitrated dispute', async () => {
        await fundBoth();
        expect(await vault.getDisputeFeePaid()).toBe(false);
        expect(await balanceOf(owner.address)).toBe(0n);   // arbitrator holds nothing yet

        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'not as described' });
        await vault.send(owner.getSender(),  { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: true });

        expect(await balanceOf(owner.address)).toBe(DISPUTE_FEE);
        expect(await vault.getDisputeFeePaid()).toBe(true);
    });

    it('charges the arbitration fee at most once, even if both milestones are arbitrated', async () => {
        await fundBoth();

        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'a' });
        await vault.send(owner.getSender(),  { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: true });

        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 1n, docHash: DOC1 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 1n, reason: 'b' });
        await vault.send(owner.getSender(),  { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 1n, releaseToSeller: true });

        // The fee prices "this trade needed the council", not each ruling — so a
        // two-dispute trade can never cost the buyer more than they prefunded.
        expect(await balanceOf(owner.address)).toBe(DISPUTE_FEE);
    });

    it('refunds the arbitration fee to the buyer at close when nothing was arbitrated', async () => {
        const buyerStart = await balanceOf(buyer.address);
        await fundBoth();
        // Buyer is out the fee while the trade is live...
        expect(await balanceOf(buyer.address)).toBe(buyerStart - BUYER_FUNDING);

        await confirmM0();
        await confirmM1();

        // ...and gets it back on a clean close: no dispute, no council work, no
        // fee. Otherwise it would be a silent surcharge on every honest trade.
        expect(await balanceOf(buyer.address)).toBe(buyerStart - M0_VALUE - M1_VALUE);
        expect(await balanceOf(owner.address)).toBe(0n);
    });

    // ─── Dispute timeout (backstop 50/50) ────────────────────────────────────────

    it('dispute timeout splits M0 50/50', async () => {
        await fundBoth();
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'stale' });

        // Advance past the 30-day dispute window.
        blockchain.now = NOW + 30 * 86400 + 10;
        await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'CheckTimeout');
        expect(await vault.getM0State()).toBe(2n);

        // buyer gets M0/2, seller gets M0/2.
        const half = M0_VALUE / 2n;
        const sellerHalf = M0_VALUE - half;
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - BUYER_FUNDING + half);
        expect(await balanceOf(seller.address)).toBe(USDT(1000) - BOND + sellerHalf);
    });

    // ─── Mutual settlement ────────────────────────────────────────────────────────

    it('mutual settlement: both agree 40% buyer for M0', async () => {
        await fundBoth();
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'partial' });

        // Buyer proposes 40% to themselves.
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 40n });
        expect(await vault.getM0State()).toBe(3n);  // still disputed — only one side
        // Seller agrees with the same value.
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'ProposeMilestoneSettlement', index: 0n, buyerPct: 40n });
        expect(await vault.getM0State()).toBe(2n);  // settled

        // buyer 40% = 2.4, seller 60% = 3.6 of M0_VALUE (6 USDT).
        const buyerCut  = M0_VALUE * 40n / 100n;
        const sellerCut = M0_VALUE - buyerCut;
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - BUYER_FUNDING + buyerCut);
        expect(await balanceOf(seller.address)).toBe(USDT(1000) - BOND + sellerCut);
    });

    // ─── Mutual cancel milestone ──────────────────────────────────────────────────

    it('mutual cancel of M0 refunds buyer and advances to M1', async () => {
        await fundBoth();
        // Both parties agree to cancel M0.
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });
        expect(await vault.getM0State()).toBe(0n);  // still pending (only one side)
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });

        expect(await vault.getM0State()).toBe(2n);   // cancelled
        expect(await vault.getActiveMilestone()).toBe(1n);
        // Buyer got M0 value back.
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - BUYER_FUNDING + M0_VALUE);
    });

    it('mutual cancel of both milestones closes the vault', async () => {
        await fundBoth();
        // Cancel M0.
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });
        // Cancel M1.
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 1n });
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 1n });

        // Vault self-destructs on close — verify by balances.
        expect(await balanceOf(buyer.address)).toBe(USDT(1000));
        expect(await balanceOf(seller.address)).toBe(USDT(1000));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('refunds prepaid referrer fee to buyer when neither milestone pays the referrer (M1 fix)', async () => {
        // Fresh escrow WITH a 5% referrer fee (tradeId 2).
        const refBps = 500n;
        await createEscrow({ referrerFeeBps: refBps });
        vault = blockchain.openContract(await EscrowJettonVaultMilestone.fromInit(factory.address, 2n));
        const referrerFee = (M0_VALUE + M1_VALUE) * refBps / 10000n;

        // Buyer prepays total + referrer fee; seller posts bond.
        await depositJettons(seller, BOND);
        await depositJettons(buyer, M0_VALUE + M1_VALUE + referrerFee + DISPUTE_FEE);
        expect(await vault.getVaultState()).toBe(1n);   // active

        // Both milestones mutually cancelled → nothing ever released to the seller,
        // so payReferrer is never called. Pre-fix, referrerFee would strand here.
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 0n });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 1n });
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'MutualCancelMilestone', index: 1n });

        // Referrer never paid; buyer fully refunded incl. the prepaid fee; nothing stranded.
        expect(await balanceOf(referrer.address)).toBe(0n);
        expect(await balanceOf(buyer.address)).toBe(USDT(1000));
        expect(await balanceOf(seller.address)).toBe(USDT(1000));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    // ─── Buyer claims abandoned delivery ─────────────────────────────────────────

    it('buyer claims M0 abandoned after delivery deadline', async () => {
        await fundBoth();
        // Advance past M0 delivery window without seller confirming.
        blockchain.now = NOW + M0_DEL_WIN + 10;

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerClaimAbandoned', index: 0n });
        expect(await vault.getM0State()).toBe(2n);

        // Buyer got M0 + M0's proportional share of the bond (bond * m0Value / totalValue).
        // The remaining share stays as seller collateral for M1, matching arbitration's slash math.
        const m0BondSlash = BOND * M0_VALUE / (M0_VALUE + M1_VALUE);
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - BUYER_FUNDING + M0_VALUE + m0BondSlash);
        expect(await vault.getPerformanceBond()).toBe(BOND - m0BondSlash);
        expect(await vault.getActiveMilestone()).toBe(1n);
    });

    // ─── Pre-activation stall refund ─────────────────────────────────────────────

    it('RefundPreActivationStall returns jettons after 7 days with one-sided funding', async () => {
        // Only buyer funds.
        await depositJettons(buyer, BUYER_FUNDING);
        expect(await vault.getBuyerFunded()).toBe(true);
        expect(await vault.getSellerBonded()).toBe(false);
        expect(await vault.getVaultState()).toBe(0n);  // still inactive

        // Advance past the 7-day pre-activation window.
        blockchain.now = NOW + 7 * 86400 + 10;

        await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'RefundPreActivationStall');

        // Vault self-destructs after refund — verify by balances.
        expect(await balanceOf(buyer.address)).toBe(USDT(1000));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('sweeps and self-destructs a stuck vault even if NEITHER party ever funded it', async () => {
        // Nobody deposits at all — e.g. TakeWalletAddress never resolved, or both
        // parties simply abandoned the trade.
        expect(await vault.getVaultState()).toBe(0n);
        expect(await vault.getBuyerFunded()).toBe(false);
        expect(await vault.getSellerBonded()).toBe(false);

        const STALL_AT = NOW + 7 * 86400 + 10;
        blockchain.now = STALL_AT;

        const result = await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'RefundPreActivationStall');
        expect(result.transactions).toHaveTransaction({ from: stranger.address, to: vault.address, success: true });
        expect(await vault.getVaultState()).toBe(2n);   // CLOSED

        // Destroy is deferred through the grace window: a jetton deposit could
        // still be in flight, and a dead vault can never refund it.
        let state = await blockchain.getContract(vault.address);
        expect(state.accountState?.type).toBe('active');

        // Past the window, anyone may reap it — residual gas swept to the buyer.
        blockchain.now = STALL_AT + 3601;
        const reap = await vault.send(stranger.getSender(), { value: toNano('0.05') }, 'Reap');
        expect(reap.transactions).toHaveTransaction({ from: vault.address, to: buyer.address, success: true });

        state = await blockchain.getContract(vault.address);
        expect(state.accountState?.type).not.toBe('active');
    });

    // ─── Referrer fee ─────────────────────────────────────────────────────────────

    // The referrer fee is owed once per trade, not once per milestone. If the
    // first milestone never pays the seller, the fee must carry to the next one
    // rather than being lost or paid for a milestone the seller lost.
    it('carries the referrer fee to M1 when M0 is disputed and resolved for the buyer', async () => {
        await createEscrow({ referrerFeeBps: 500n });
        vault = blockchain.openContract(
            await EscrowJettonVaultMilestone.fromInit(factory.address, 2n),
        );
        const refFee = (M0_VALUE + M1_VALUE) * 500n / 10000n;
        await depositJettons(seller, BOND);
        await depositJettons(buyer, M0_VALUE + M1_VALUE + refFee + DISPUTE_FEE);

        // M0 goes against the seller — no seller payout, so no referrer fee yet.
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: 0n, docHash: DOC0 });
        await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: 0n, reason: 'not delivered' });
        await vault.send(owner.getSender(),  { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: 0n, releaseToSeller: false });

        expect(await vault.getM0State()).toBe(2n);
        expect(await vault.getReferrerPaid()).toBe(false);
        expect(await balanceOf(referrer.address)).toBe(0n);

        // M1 does pay the seller — the fee lands here instead.
        await confirmM1();
        expect(await vault.getReferrerPaid()).toBe(true);
        expect(await balanceOf(referrer.address)).toBe(refFee);
    });

    it('refunds the referrer fee to the buyer when the seller never gets paid at all', async () => {
        await createEscrow({ referrerFeeBps: 500n });
        vault = blockchain.openContract(
            await EscrowJettonVaultMilestone.fromInit(factory.address, 2n),
        );
        const refFee = (M0_VALUE + M1_VALUE) * 500n / 10000n;
        const buyerStart = await balanceOf(buyer.address);
        await depositJettons(seller, BOND);
        await depositJettons(buyer, M0_VALUE + M1_VALUE + refFee + DISPUTE_FEE);

        // Both milestones go to the buyer — the referrer introduced a trade that
        // paid the seller nothing, so the fee is never earned and must come back.
        for (const i of [0n, 1n]) {
            await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmMilestone', index: i, docHash: DOC0 });
            await vault.send(buyer.getSender(),  { value: toNano('0.1') }, { $$type: 'BuyerDisputeMilestone',  index: i, reason: 'no' });
            await vault.send(owner.getSender(),  { value: toNano('0.1') }, { $$type: 'ArbitratorResolveMilestone', index: i, releaseToSeller: false });
        }

        expect(await balanceOf(referrer.address)).toBe(0n);
        // Buyer is out only the arbitration fee (a dispute WAS arbitrated); the
        // referrer fee and both milestone values came back, plus the bond slash.
        expect(await balanceOf(buyer.address)).toBe(buyerStart - DISPUTE_FEE + BOND);
    });

    it('referrer receives fee on first milestone confirmation', async () => {
        // Create a new trade with a 5% referrer fee.
        await createEscrow({ referrerFeeBps: 500n });
        // tradeId 2 is the new vault.
        vault = blockchain.openContract(
            await EscrowJettonVaultMilestone.fromInit(factory.address, 2n),
        );

        const refFee = (M0_VALUE + M1_VALUE) * 500n / 10000n;  // 5% of 10 = 0.5 USDT
        await depositJettons(seller, BOND);
        await depositJettons(buyer, M0_VALUE + M1_VALUE + refFee + DISPUTE_FEE);

        expect(await vault.getVaultState()).toBe(1n);
        expect(await vault.getReferrerFee()).toBe(refFee);

        await confirmM0();
        // Referrer gets fee after first milestone paid.
        expect(await balanceOf(referrer.address)).toBe(refFee);
        expect(await vault.getReferrerPaid()).toBe(true);

        await confirmM1();
        // Referrer not double-paid.
        expect(await balanceOf(referrer.address)).toBe(refFee);
    });

    // ─── Spoofed deposit ─────────────────────────────────────────────────────────

    it('rejects a deposit notification not from vault jetton wallet', async () => {
        const res = await vault.send(stranger.getSender(), { value: toNano('0.1') }, {
            $$type: 'JettonTransferNotification',
            queryId: 0n,
            amount: USDT(10),
            sender: buyer.address,
            forwardPayload: EMPTY_FWD,
        });
        expect(res.transactions).toHaveTransaction({
            from: stranger.address,
            to: vault.address,
            success: false,
        });
        expect(await vault.getVaultState()).toBe(0n);
        expect(await vault.getBuyerFunded()).toBe(false);
    });

    // ─── Over-deposit refund ──────────────────────────────────────────────────────

    it('refunds the excess on buyer over-deposit', async () => {
        const required = BUYER_FUNDING;
        await depositJettons(buyer, required + USDT(3));
        // Buyer only loses `required`, not the extra 3 USDT.
        expect(await balanceOf(buyer.address)).toBe(USDT(1000) - required);
    });

    // ─── Factory registry ─────────────────────────────────────────────────────────

    it('factory increments totalVaults after successful creation', async () => {
        const cfg = await factory.getFactoryConfig();
        expect(cfg.totalVaultsDeployed).toBe(1n);

        await createEscrow();
        const cfg2 = await factory.getFactoryConfig();
        expect(cfg2.totalVaultsDeployed).toBe(2n);
    });
});
