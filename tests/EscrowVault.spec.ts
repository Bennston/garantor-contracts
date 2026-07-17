import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano, Address } from '@ton/core';
import { EscrowVault } from '../build/EscrowVault/tact_EscrowVault';
import { EscrowFactory } from '../build/EscrowFactory/tact_EscrowFactory';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('EscrowVault', () => {
    let blockchain: Blockchain;
    let factory: SandboxContract<TreasuryContract>;
    let dao: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let commissionairesDao: SandboxContract<TreasuryContract>;
    let vault: SandboxContract<EscrowVault>;
    let vaultCode: Cell;

    const TRADE_VALUE = toNano('10');       // 10 TON trade
    const GUARANTEE_PERCENT = 2;
    const COMMISSION_PERCENT = 1;
    const TRADE_ID = 1n;

    beforeAll(async () => {
        vaultCode = await compile('EscrowVault');
    });

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        factory = await blockchain.treasury('factory');
        dao = await blockchain.treasury('dao');
        buyer = await blockchain.treasury('buyer');
        seller = await blockchain.treasury('seller');
        commissionairesDao = await blockchain.treasury('commissionaires');

        // Deploy the vault (factory deploys it)
        vault = blockchain.openContract(
            await EscrowVault.fromInit(
                factory.address,     // factory
                dao.address,         // dao
                TRADE_ID             // seqno
            )
        );

        // Deploy vault contract
        const deployResult = await vault.send(
            factory.getSender(),
            { value: toNano('0.1') },
            {
                $$type: 'InitVault',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: TRADE_VALUE,
                guaranteePercent: BigInt(GUARANTEE_PERCENT),
                commissionPercent: BigInt(COMMISSION_PERCENT),
                commissionairesDao: commissionairesDao.address,
                tradeId: TRADE_ID,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        expect(deployResult.transactions).toHaveTransaction({
            from: factory.address,
            to: vault.address,
            success: true,
            deploy: true,
        });
    });

    it('should deploy and initialize correctly', async () => {
        const state = await vault.getVaultState();
        expect(state.state).toBe(1n); // AWAITING_DEPOSITS
        expect(state.buyer.equals(buyer.address)).toBe(true);
        expect(state.seller.equals(seller.address)).toBe(true);
        expect(state.tradeValue).toBe(TRADE_VALUE);
        expect(state.buyerDeposited).toBe(false);
        expect(state.sellerDeposited).toBe(false);
    });

    it('should reject init from non-factory', async () => {
        // Try to init from random address
        const attacker = await blockchain.treasury('attacker');
        const vault2 = blockchain.openContract(
            await EscrowVault.fromInit(factory.address, dao.address, 999n)
        );
        const result = await vault2.send(
            attacker.getSender(),
            { value: toNano('0.1') },
            {
                $$type: 'InitVault',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: TRADE_VALUE,
                guaranteePercent: BigInt(GUARANTEE_PERCENT),
                commissionPercent: BigInt(COMMISSION_PERCENT),
                commissionairesDao: commissionairesDao.address,
                tradeId: 999n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        expect(result.transactions).toHaveTransaction({
            from: attacker.address,
            to: vault2.address,
            success: false,
        });
    });

    it('should accept buyer deposit with correct amount', async () => {
        const requiredDeposit = await vault.getRequiredBuyerDeposit();
        expect(requiredDeposit).toBe(TRADE_VALUE);

        const result = await vault.send(
            buyer.getSender(),
            { value: TRADE_VALUE + toNano('0.05') }, // deposit + gas
            { $$type: 'BuyerDeposit' }
        );

        expect(result.transactions).toHaveTransaction({
            from: buyer.address,
            to: vault.address,
            success: true,
        });

        const state = await vault.getVaultState();
        expect(state.buyerDeposited).toBe(true);
        expect(state.state).toBe(1n); // still AWAITING_DEPOSITS (seller not yet)
    });

    it('should reject buyer deposit from wrong address', async () => {
        const result = await vault.send(
            seller.getSender(),
            { value: TRADE_VALUE + toNano('0.05') },
            { $$type: 'BuyerDeposit' }
        );

        expect(result.transactions).toHaveTransaction({
            from: seller.address,
            to: vault.address,
            success: false,
        });
    });

    it('should reject insufficient buyer deposit', async () => {
        const result = await vault.send(
            buyer.getSender(),
            { value: toNano('0.1') }, // way too low
            { $$type: 'BuyerDeposit' }
        );

        expect(result.transactions).toHaveTransaction({
            from: buyer.address,
            to: vault.address,
            success: false,
        });
    });

    it('should accept seller deposit', async () => {
        const requiredDeposit = await vault.getRequiredSellerDeposit();
        const expectedSellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
        expect(requiredDeposit).toBe(expectedSellerDeposit);

        const result = await vault.send(
            seller.getSender(),
            { value: requiredDeposit + toNano('0.05') },
            { $$type: 'SellerDeposit' }
        );

        expect(result.transactions).toHaveTransaction({
            from: seller.address,
            to: vault.address,
            success: true,
        });
    });

    it('should transition to AWAITING_CONFIRMATION when both deposit', async () => {
        // Buyer deposits
        await vault.send(
            buyer.getSender(),
            { value: TRADE_VALUE + toNano('0.05') },
            { $$type: 'BuyerDeposit' }
        );

        // Seller deposits
        const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
        await vault.send(
            seller.getSender(),
            { value: sellerDeposit + toNano('0.05') },
            { $$type: 'SellerDeposit' }
        );

        const state = await vault.getVaultState();
        expect(state.state).toBe(2n); // AWAITING_CONFIRMATION
        expect(state.buyerDeposited).toBe(true);
        expect(state.sellerDeposited).toBe(true);
    });

    describe('after both deposits', () => {
        beforeEach(async () => {
            // Both deposit
            await vault.send(
                buyer.getSender(),
                { value: TRADE_VALUE + toNano('0.05') },
                { $$type: 'BuyerDeposit' }
            );
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vault.send(
                seller.getSender(),
                { value: sellerDeposit + toNano('0.05') },
                { $$type: 'SellerDeposit' }
            );
        });

        it('should reject buyer ConfirmTrade before seller has confirmed (ordering enforced)', async () => {
            // Buyer must not be able to confirm before seller — this was HIGH-1 vulnerability.
            // Contract now requires sellerConfirmed == true before buyerConfirmed can be set.
            const resultBuyer = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'ConfirmTrade' }
            );
            expect(resultBuyer.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: false, // must be rejected
            });
            const stateAfter = await vault.getVaultState();
            expect(stateAfter.state).toBe(2n);          // still AWAITING_CONFIRMATION
            expect(stateAfter.buyerConfirmed).toBe(false); // flag must not have been set
        });

        it('should complete trade via doc-hash flow (seller delivers, buyer receipts)', async () => {
            const DOC_HASH = 123456789n;

            // Phase 1: seller submits delivery proof — still AWAITING_CONFIRMATION
            const resultSeller = await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'SellerConfirmDelivery', docHash: DOC_HASH }
            );
            expect(resultSeller.transactions).toHaveTransaction({
                from: seller.address,
                to: vault.address,
                success: true,
            });
            const stateAfterSeller = await vault.getVaultState();
            expect(stateAfterSeller.state).toBe(2n);          // still AWAITING_CONFIRMATION
            expect(stateAfterSeller.sellerConfirmed).toBe(true);

            // Phase 2: buyer confirms receipt with matching hash → SUCCESSFUL
            const resultBuyer = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'BuyerConfirmReceipt', docHash: DOC_HASH }
            );
            expect(resultBuyer.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: true,
            });

            const state = await vault.getVaultState();
            expect(state.state).toBe(3n); // SUCCESSFUL
        });

        it('should reject confirm from non-party', async () => {
            const attacker = await blockchain.treasury('attacker');
            const result = await vault.send(
                attacker.getSender(),
                { value: toNano('0.05') },
                { $$type: 'ConfirmTrade' }
            );

            expect(result.transactions).toHaveTransaction({
                from: attacker.address,
                to: vault.address,
                success: false,
            });
        });

        it('should allow buyer to raise dispute', async () => {
            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'RaiseDispute' }
            );

            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: true,
            });

            const state = await vault.getVaultState();
            expect(state.state).toBe(4n); // DISPUTED
        });

        it('should allow DAO to resolve dispute', async () => {
            // Raise dispute first
            await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'RaiseDispute' }
            );

            const totalPool = TRADE_VALUE + (TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n);
            const buyerShare = totalPool * 60n / 100n;    // 60% to buyer
            const daoFee = totalPool * 5n / 100n;         // 5% DAO fee
            const sellerShare = totalPool - buyerShare - daoFee;

            const result = await vault.send(
                dao.getSender(),
                { value: toNano('0.05') },
                {
                    $$type: 'ResolveDispute',
                    buyerShare,
                    sellerShare,
                    daoFee,
                }
            );

            expect(result.transactions).toHaveTransaction({
                from: dao.address,
                to: vault.address,
                success: true,
            });

            const state = await vault.getVaultState();
            expect(state.state).toBe(5n); // RESOLVED
            expect(state.buyerClaimable).toBe(buyerShare);
            expect(state.sellerClaimable).toBe(sellerShare);
            expect(state.commissionairesClaimable).toBe(daoFee);
        });

        it('should reject dispute resolution from non-DAO', async () => {
            await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'RaiseDispute' }
            );

            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                {
                    $$type: 'ResolveDispute',
                    buyerShare: toNano('5'),
                    sellerShare: toNano('5'),
                    daoFee: toNano('0.2'),
                }
            );

            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: false,
            });
        });

        // ─── Mutual dispute settlement (ProposeSettlement) ────────────────────

        it('[SETTLEMENT] buyer and seller settle a dispute 60/40 with no DAO fee', async () => {
            await vault.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'RaiseDispute' });
            expect((await vault.getVaultState()).state).toBe(4n); // DISPUTED

            // Buyer proposes 60% to buyer — not executed until seller echoes it
            await vault.send(buyer.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 60n });
            expect(await vault.getSettleProposed()).toBe(true);
            expect(await vault.getSettleBuyerPct()).toBe(60n);
            expect((await vault.getVaultState()).state).toBe(4n); // still DISPUTED

            // Seller approves the same 60% → resolves
            const result = await vault.send(seller.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 60n });
            expect(result.transactions).toHaveTransaction({
                from: seller.address, to: vault.address, success: true,
            });

            const totalPool   = TRADE_VALUE + (TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n);
            const buyerShare  = totalPool * 60n / 100n;
            const sellerShare = totalPool - buyerShare;

            const state = await vault.getVaultState();
            expect(state.state).toBe(5n); // RESOLVED
            expect(state.buyerClaimable).toBe(buyerShare);
            expect(state.sellerClaimable).toBe(sellerShare);
            expect(state.commissionairesClaimable).toBe(0n); // no DAO fee on self-settlement
            // Conservation: entire pool allocated to the two parties
            expect(state.buyerClaimable + state.sellerClaimable).toBe(totalPool);
        });

        it('[SETTLEMENT] a single proposal does not resolve — counterparty must echo', async () => {
            await vault.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'RaiseDispute' });
            await vault.send(buyer.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 50n });
            await vault.send(buyer.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 50n });
            expect((await vault.getVaultState()).state).toBe(4n); // still DISPUTED
        });

        it('[SETTLEMENT] rejects a non-party and a non-disputed vault', async () => {
            // Not disputed yet (state AwaitingConfirmation) → rejected
            const earlyRes = await vault.send(buyer.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 50n });
            expect(earlyRes.transactions).toHaveTransaction({
                from: buyer.address, to: vault.address, success: false,
            });

            // Raise dispute, then a stranger tries to settle → rejected
            await vault.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'RaiseDispute' });
            const stranger = await blockchain.treasury('stranger');
            const strangerRes = await vault.send(stranger.getSender(), { value: toNano('0.05') },
                { $$type: 'ProposeSettlement', buyerPct: 50n });
            expect(strangerRes.transactions).toHaveTransaction({
                from: stranger.address, to: vault.address, success: false,
            });
            expect((await vault.getVaultState()).state).toBe(4n); // unchanged
        });
    });

    describe('withdrawal (pull pattern)', () => {
        beforeEach(async () => {
            // Full successful trade flow via doc-hash confirmation
            await vault.send(
                buyer.getSender(),
                { value: TRADE_VALUE + toNano('0.05') },
                { $$type: 'BuyerDeposit' }
            );
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vault.send(
                seller.getSender(),
                { value: sellerDeposit + toNano('0.05') },
                { $$type: 'SellerDeposit' }
            );
            // Doc-hash flow: seller delivers with proof, buyer confirms with matching hash
            const DOC_HASH = 999888777n;
            await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'SellerConfirmDelivery', docHash: DOC_HASH }
            );
            await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'BuyerConfirmReceipt', docHash: DOC_HASH }
            );
        });

        it('should allow seller to withdraw after success', async () => {
            const stateBefore = await vault.getVaultState();
            expect(stateBefore.sellerClaimable).toBeGreaterThan(0n);

            const result = await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'Withdraw' }
            );

            expect(result.transactions).toHaveTransaction({
                from: vault.address,
                to: seller.address,
                success: true,
            });

            const stateAfter = await vault.getVaultState();
            expect(stateAfter.sellerClaimable).toBe(0n);
        });

        it('should allow commissionaires to withdraw', async () => {
            const result = await vault.send(
                commissionairesDao.getSender(),
                { value: toNano('0.05') },
                { $$type: 'Withdraw' }
            );

            expect(result.transactions).toHaveTransaction({
                from: vault.address,
                to: commissionairesDao.address,
                success: true,
            });

            const state = await vault.getVaultState();
            expect(state.commissionairesClaimable).toBe(0n);
        });

        it('should reject double withdrawal', async () => {
            // First withdrawal succeeds
            await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'Withdraw' }
            );

            // Second withdrawal should fail (nothing to withdraw)
            const result = await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'Withdraw' }
            );

            expect(result.transactions).toHaveTransaction({
                from: seller.address,
                to: vault.address,
                success: false,
            });
        });

        it('should reject withdrawal from unauthorized address', async () => {
            const attacker = await blockchain.treasury('attacker');
            const result = await vault.send(
                attacker.getSender(),
                { value: toNano('0.05') },
                { $$type: 'Withdraw' }
            );

            expect(result.transactions).toHaveTransaction({
                from: attacker.address,
                to: vault.address,
                success: false,
            });
        });
    });

    describe('cancellation', () => {
        it('should allow cancel before both deposits', async () => {
            // Buyer deposits only
            await vault.send(
                buyer.getSender(),
                { value: TRADE_VALUE + toNano('0.05') },
                { $$type: 'BuyerDeposit' }
            );

            // Buyer cancels
            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'CancelTrade' }
            );

            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: true,
            });

            const state = await vault.getVaultState();
            expect(state.state).toBe(6n); // CANCELLED
            expect(state.buyerClaimable).toBe(TRADE_VALUE); // buyer gets refund
        });

        it('should reject cancel after both deposits', async () => {
            await vault.send(
                buyer.getSender(),
                { value: TRADE_VALUE + toNano('0.05') },
                { $$type: 'BuyerDeposit' }
            );
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vault.send(
                seller.getSender(),
                { value: sellerDeposit + toNano('0.05') },
                { $$type: 'SellerDeposit' }
            );

            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'CancelTrade' }
            );

            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: false,
            });
        });
    });

    // ── Deadline + doc-hash edge cases ────────────────────────────────────────

    describe('deadline enforcement', () => {
        let vaultWithDeadline: SandboxContract<EscrowVault>;

        beforeEach(async () => {
            // #4 forbids creating an already-expired vault. Deploy with a near-future
            // deadline, fund it, then advance the chain past the deadline.
            const base = Math.floor(Date.now() / 1000);
            const deadline = BigInt(base + 3600);

            vaultWithDeadline = blockchain.openContract(
                await EscrowVault.fromInit(factory.address, dao.address, 999n)
            );
            await vaultWithDeadline.send(
                factory.getSender(),
                { value: toNano('0.1') },
                {
                    $$type: 'InitVault',
                    buyer: buyer.address,
                    seller: seller.address,
                    tradeValue: TRADE_VALUE,
                    guaranteePercent: BigInt(GUARANTEE_PERCENT),
                    commissionPercent: BigInt(COMMISSION_PERCENT),
                    commissionairesDao: commissionairesDao.address,
                    tradeId: 999n,
                    deadline: deadline,
                }
            );

            // Both deposit (deposits carry no deadline check)
            await vaultWithDeadline.send(buyer.getSender(),  { value: TRADE_VALUE + toNano('0.05') }, { $$type: 'BuyerDeposit' });
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vaultWithDeadline.send(seller.getSender(), { value: sellerDeposit + toNano('0.05') }, { $$type: 'SellerDeposit' });

            // Advance past the deadline so confirm paths are blocked and CheckExpiry works.
            blockchain.now = base + 7200;
        });

        it('should reject ConfirmTrade after deadline', async () => {
            const result = await vaultWithDeadline.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'ConfirmTrade' }
            );
            expect(result.transactions).toHaveTransaction({
                from: seller.address,
                to: vaultWithDeadline.address,
                success: false,
            });
        });

        it('should reject SellerConfirmDelivery after deadline', async () => {
            const result = await vaultWithDeadline.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'SellerConfirmDelivery', docHash: 0xabcdef1234n }
            );
            expect(result.transactions).toHaveTransaction({
                from: seller.address,
                to: vaultWithDeadline.address,
                success: false,
            });
        });

        it('should allow CheckExpiry after deadline passes', async () => {
            const anyone = await blockchain.treasury('anyone');
            const result = await vaultWithDeadline.send(
                anyone.getSender(),
                { value: toNano('0.05') },
                'CheckExpiry'
            );
            expect(result.transactions).toHaveTransaction({
                from: anyone.address,
                to: vaultWithDeadline.address,
                success: true,
            });
            const state = await vaultWithDeadline.getVaultState();
            expect(state.state).toBe(7n); // EXPIRED
        });

        it('should allow cancel after expiry', async () => {
            const anyone = await blockchain.treasury('anyone');
            await vaultWithDeadline.send(anyone.getSender(), { value: toNano('0.05') }, 'CheckExpiry');

            const result = await vaultWithDeadline.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'CancelTrade' }
            );
            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vaultWithDeadline.address,
                success: true,
            });
            const state = await vaultWithDeadline.getVaultState();
            expect(state.state).toBe(6n); // CANCELLED
            expect(state.buyerClaimable).toBe(TRADE_VALUE);
        });

        it('should reject CheckExpiry before deadline', async () => {
            // Deploy a vault with future deadline
            const futureDeadline = BigInt(Math.floor(Date.now() / 1000) + 86400);
            const vaultFuture = blockchain.openContract(
                await EscrowVault.fromInit(factory.address, dao.address, 998n)
            );
            await vaultFuture.send(
                factory.getSender(),
                { value: toNano('0.1') },
                {
                    $$type: 'InitVault',
                    buyer: buyer.address,
                    seller: seller.address,
                    tradeValue: TRADE_VALUE,
                    guaranteePercent: BigInt(GUARANTEE_PERCENT),
                    commissionPercent: BigInt(COMMISSION_PERCENT),
                    commissionairesDao: commissionairesDao.address,
                    tradeId: 998n,
                    deadline: futureDeadline,
                }
            );
            await vaultFuture.send(buyer.getSender(),  { value: TRADE_VALUE + toNano('0.05') }, { $$type: 'BuyerDeposit' });
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vaultFuture.send(seller.getSender(), { value: sellerDeposit + toNano('0.05') }, { $$type: 'SellerDeposit' });

            const result = await vaultFuture.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                'CheckExpiry'
            );
            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vaultFuture.address,
                success: false,
            });
        });
    });

    describe('doc-hash flow', () => {
        const SELLER_HASH = 0xdeadbeef1234567890abcdef1234567890abcdef1234567890abcdef12345678n;
        const WRONG_HASH  = 0x1111111111111111111111111111111111111111111111111111111111111111n;

        beforeEach(async () => {
            // Both deposit
            await vault.send(buyer.getSender(),  { value: TRADE_VALUE + toNano('0.05') }, { $$type: 'BuyerDeposit' });
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vault.send(seller.getSender(), { value: sellerDeposit + toNano('0.05') }, { $$type: 'SellerDeposit' });
        });

        it('should allow seller to submit doc hash', async () => {
            const result = await vault.send(
                seller.getSender(),
                { value: toNano('0.05') },
                { $$type: 'SellerConfirmDelivery', docHash: SELLER_HASH }
            );
            expect(result.transactions).toHaveTransaction({
                from: seller.address,
                to: vault.address,
                success: true,
            });
            const state = await vault.getVaultState();
            expect(state.sellerConfirmed).toBe(true);
            expect(state.sellerDocHash).toBe(SELLER_HASH);
            expect(state.state).toBe(2n); // still AWAITING_CONFIRMATION
        });

        it('should reject BuyerConfirmReceipt before seller submits hash', async () => {
            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'BuyerConfirmReceipt', docHash: SELLER_HASH }
            );
            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: false,
            });
        });

        it('should reject BuyerConfirmReceipt with wrong hash', async () => {
            await vault.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'SellerConfirmDelivery', docHash: SELLER_HASH });

            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'BuyerConfirmReceipt', docHash: WRONG_HASH }
            );
            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: false,
            });
            const state = await vault.getVaultState();
            expect(state.state).toBe(2n); // still AWAITING_CONFIRMATION — not released
        });

        it('should release funds when buyer submits matching hash', async () => {
            await vault.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'SellerConfirmDelivery', docHash: SELLER_HASH });

            const result = await vault.send(
                buyer.getSender(),
                { value: toNano('0.05') },
                { $$type: 'BuyerConfirmReceipt', docHash: SELLER_HASH }
            );
            expect(result.transactions).toHaveTransaction({
                from: buyer.address,
                to: vault.address,
                success: true,
            });
            const state = await vault.getVaultState();
            expect(state.state).toBe(3n); // SUCCESSFUL
            expect(state.sellerClaimable).toBeGreaterThan(0n);
            expect(state.buyerDocHash).toBe(SELLER_HASH);
        });
    });

    describe('dispute timeout backstop (#3)', () => {
        beforeEach(async () => {
            // Fund → AWAITING_CONFIRMATION, then raise a dispute → DISPUTED.
            await vault.send(buyer.getSender(),  { value: TRADE_VALUE + toNano('0.05') }, { $$type: 'BuyerDeposit' });
            const sellerDeposit = TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n;
            await vault.send(seller.getSender(), { value: sellerDeposit + toNano('0.05') }, { $$type: 'SellerDeposit' });
            await vault.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'RaiseDispute' });
        });

        it('sets a dispute deadline on entering DISPUTED', async () => {
            expect((await vault.getVaultState()).state).toBe(4n); // DISPUTED
            expect(await vault.getDisputeDeadline()).toBeGreaterThan(0n);
        });

        it('rejects CheckDisputeTimeout before the window', async () => {
            const anyone = await blockchain.treasury('anyone');
            const result = await vault.send(anyone.getSender(), { value: toNano('0.05') }, 'CheckDisputeTimeout');
            expect(result.transactions).toHaveTransaction({
                from: anyone.address, to: vault.address, success: false,
            });
            expect((await vault.getVaultState()).state).toBe(4n); // still DISPUTED
        });

        it('permissionlessly splits the pool 50/50 after the window (no permanent lock)', async () => {
            const dd = await vault.getDisputeDeadline();
            blockchain.now = Number(dd) + 1;

            const anyone = await blockchain.treasury('anyone');
            const result = await vault.send(anyone.getSender(), { value: toNano('0.05') }, 'CheckDisputeTimeout');
            expect(result.transactions).toHaveTransaction({
                from: anyone.address, to: vault.address, success: true,
            });

            const state = await vault.getVaultState();
            expect(state.state).toBe(5n); // RESOLVED
            const pool = TRADE_VALUE + (TRADE_VALUE * BigInt(GUARANTEE_PERCENT) / 100n);
            expect(state.buyerClaimable).toBe(pool / 2n);
            expect(state.sellerClaimable).toBe(pool - pool / 2n);
            expect(state.commissionairesClaimable).toBe(0n);
        });
    });
});
