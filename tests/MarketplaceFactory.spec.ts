import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell, Cell, internal } from '@ton/core';
import { keyPairFromSeed, sign, KeyPair } from '@ton/crypto';
import { MarketplaceFactory, storeCreateListing } from '../build/MarketplaceFactory/tact_MarketplaceFactory';
import { MarketplaceListing } from '../build/MarketplaceListing/tact_MarketplaceListing';
import { EscrowOracleVault } from '../build/EscrowOracleVault/tact_EscrowOracleVault';
import { OracleRegistry } from '../build/OracleRegistry/tact_OracleRegistry';
import { MockJettonMaster } from '../build/MockJettonMaster/tact_MockJettonMaster';
import { MockJettonWallet } from '../build/MockJettonMaster/tact_MockJettonWallet';
import '@ton/test-utils';

const USDT = (n: number) => BigInt(Math.round(n * 1_000_000));
const PRICE = USDT(10);
const GUARANTEE = USDT(0.2);
const COMMISSION = USDT(0.1);
const SELLER_PAYOUT = PRICE + GUARANTEE - COMMISSION;
const VTYPE = 1;
const OBJECTION_WINDOW = 172800;
const DELIVERED = 0;
const EMPTY_FWD = beginCell().storeUint(0, 1).endCell().asSlice();
const bufToBigInt = (b: Buffer) => BigInt('0x' + b.toString('hex'));

describe('MarketplaceFactory (V3: factory → listing → vault)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let dao: SandboxContract<TreasuryContract>;
    let commissionaires: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let relayer: SandboxContract<TreasuryContract>;

    let master: SandboxContract<MockJettonMaster>;
    let registry: SandboxContract<OracleRegistry>;
    let factory: SandboxContract<MarketplaceFactory>;

    let donKey: KeyPair;
    let NOW: number;

    const mint = async (to: Address, amount: bigint) =>
        master.send(deployer.getSender(), { value: toNano('0.1') }, { $$type: 'MockMint', to, amount });

    const walletOf = async (owner: Address) =>
        blockchain.openContract(await MockJettonWallet.fromInit(owner, master.address));

    const balanceOf = async (owner: Address): Promise<bigint> => {
        const w = await walletOf(owner);
        const state = await blockchain.getContract(w.address);
        if (state.accountState?.type !== 'active') return 0n;
        return await w.getBalance();
    };

    const depositTo = async (vaultAddr: Address, owner: SandboxContract<TreasuryContract>, amount: bigint) => {
        const w = await walletOf(owner.address);
        return w.send(owner.getSender(), { value: toNano('0.3') }, {
            $$type: 'JettonTransfer',
            queryId: 0n, amount, destination: vaultAddr, responseDestination: owner.address,
            customPayload: null, forwardTonAmount: toNano('0.1'), forwardPayload: EMPTY_FWD,
        });
    };

    const signReport = (vaultAddr: Address, tradeId: bigint, vt: number, status: number): Cell => {
        const h = beginCell()
            .storeAddress(vaultAddr).storeUint(tradeId, 64).storeUint(vt, 8).storeUint(status, 8).storeUint(0n, 256)
            .endCell().hash();
        return beginCell().storeBuffer(sign(h, donKey.secretKey)).endCell();
    };

    // Must cover deploymentFee (4 TON) + ListingGasBudget (0.1) + buffer.
    const createListing = async (
        who: SandboxContract<TreasuryContract>,
        supply: number | bigint,
        nonce: bigint,
        opts: { minOrderQty?: bigint; maxOrderQty?: bigint; price?: bigint } = {},
    ) =>
        factory.send(who.getSender(), { value: toNano('4.3') }, {
            $$type: 'CreateListing',
            pricePerUnit: opts.price ?? PRICE,
            initialSupply: BigInt(supply),
            minOrderQty: opts.minOrderQty ?? 0n,   // V3.1
            maxOrderQty: opts.maxOrderQty ?? 0n,   // V3.1
            validationType: BigInt(VTYPE),
            settlementMode: 0n,   // oracle-only
            agreementCID: null,
            nonce,
        });

    const openListing = async (id: bigint) =>
        blockchain.openContract(await MarketplaceListing.fromInit(factory.address, master.address, id));

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        NOW = Math.floor(Date.now() / 1000);
        blockchain.now = NOW;
        donKey = keyPairFromSeed(Buffer.alloc(32, 7));

        deployer = await blockchain.treasury('deployer');
        dao = await blockchain.treasury('dao');
        commissionaires = await blockchain.treasury('commissionaires');
        seller = await blockchain.treasury('seller');
        buyer = await blockchain.treasury('buyer');
        relayer = await blockchain.treasury('relayer');

        const content = beginCell().storeUint(0, 8).storeBit(false).endCell();
        master = blockchain.openContract(await MockJettonMaster.fromInit(deployer.address, content));
        await mint(buyer.address, USDT(100));
        await mint(seller.address, USDT(100));

        registry = blockchain.openContract(await OracleRegistry.fromInit(dao.address, bufToBigInt(donKey.publicKey)));
        await registry.send(dao.getSender(), { value: toNano('0.05') }, null);

        factory = blockchain.openContract(await MarketplaceFactory.fromInit(
            dao.address, master.address, registry.address, commissionaires.address,
        ));
        await factory.send(dao.getSender(), { value: toNano('0.05') }, null);   // deploy
        await deployer.send({ to: factory.address, value: toNano('2'), bounce: false });
    });

    it('deploys and configures a listing, and registers it under the seller', async () => {
        await createListing(seller, 3, 1n);

        expect(await factory.getTotalListings()).toBe(1n);
        expect(await factory.getSellerListingCount(seller.address)).toBe(1n);
        expect(await factory.getSellerListingAtIndex(seller.address, 0n)).toBe(1n);

        const listing = blockchain.openContract(await MarketplaceListing.fromInit(
            factory.address, master.address, 1n,
        ));
        expect(listing.address.equals(await factory.getListingAddress(1n))).toBe(true);

        const cfg = await listing.getConfig();
        expect(cfg.active).toBe(true);
        expect(cfg.remainingSupply).toBe(3n);
        expect(cfg.seller.equals(seller.address)).toBe(true);
        expect(cfg.owner.equals(factory.address)).toBe(true);   // listing admin is the factory
        expect(cfg.dao.equals(dao.address)).toBe(true);         // vault arbitrator is the DAO
    });

    it('full stack: factory → listing → purchase → deposit → DON settle pays the seller', async () => {
        await createListing(seller, 2, 1n);
        const listing = blockchain.openContract(await MarketplaceListing.fromInit(
            factory.address, master.address, 1n,
        ));

        // Buyer purchases a unit → listing deploys a seeded oracle vault.
        await listing.send(buyer.getSender(), { value: toNano('0.6') }, { $$type: 'PurchaseListing', nonce: 1n, quantity: 1n });
        expect(await listing.getRemainingSupply()).toBe(1n);

        const vault = blockchain.openContract(await EscrowOracleVault.fromInit(listing.address, dao.address, 1n));
        // Vault's arbitrator (owner) is the DAO, not the factory or listing.
        const vs = await vault.getVaultState();
        expect(vs.seller.equals(seller.address)).toBe(true);
        expect(vs.buyer.equals(buyer.address)).toBe(true);
        expect(await vault.getWalletResolved()).toBe(true);

        await depositTo(vault.address, buyer, PRICE);
        await depositTo(vault.address, seller, GUARANTEE);
        expect((await vault.getVaultState()).state).toBe(2n);

        await registry.send(relayer.getSender(), { value: toNano('0.3') }, {
            $$type: 'SubmitReport',
            vault: vault.address, tradeId: 1n, validationType: BigInt(VTYPE), status: BigInt(DELIVERED),
            proof: null, signature: signReport(vault.address, 1n, VTYPE, DELIVERED),
        });

        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect((await vault.getVaultState()).state).toBe(3n);

        await vault.send(seller.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });
        await vault.send(commissionaires.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + SELLER_PAYOUT);
        expect(await balanceOf(commissionaires.address)).toBe(COMMISSION);
    });

    it('rejects a duplicate CreateListing (same nonce from same seller)', async () => {
        await createListing(seller, 3, 5n);
        const dup = await createListing(seller, 3, 5n);
        expect(dup.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect(await factory.getTotalListings()).toBe(1n);
    });

    it('assigns independent listing ids to different sellers', async () => {
        const seller2 = await blockchain.treasury('seller2');
        await createListing(seller, 3, 1n);
        await createListing(seller2, 5, 1n);

        expect(await factory.getTotalListings()).toBe(2n);
        expect(await factory.getSellerListingAtIndex(seller.address, 0n)).toBe(1n);
        expect(await factory.getSellerListingAtIndex(seller2.address, 0n)).toBe(2n);

        const l2 = blockchain.openContract(await MarketplaceListing.fromInit(
            factory.address, master.address, 2n,
        ));
        const cfg = await l2.getConfig();
        expect(cfg.seller.equals(seller2.address)).toBe(true);
        expect(cfg.remainingSupply).toBe(5n);
    });

    it('only the owner can repoint the oracle registry', async () => {
        const bad = await factory.send(seller.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateOracleRegistry', newRegistry: seller.address,
        });
        expect(bad.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect((await factory.getConfig()).oracleRegistry.equals(registry.address)).toBe(true);
    });

    it('ships with a 4 TON default deployment fee', async () => {
        expect(await factory.getDeploymentFee()).toBe(toNano('4'));
        expect((await factory.getConfig()).deploymentFee).toBe(toNano('4'));
    });

    it('rejects a CreateListing that underpays the deployment fee', async () => {
        const under = await factory.send(seller.getSender(), { value: toNano('2') }, {
            $$type: 'CreateListing',
            pricePerUnit: PRICE, initialSupply: 3n, minOrderQty: 0n, maxOrderQty: 0n,
            validationType: BigInt(VTYPE),
            settlementMode: 0n, agreementCID: null, nonce: 9n,
        });
        expect(under.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect(await factory.getTotalListings()).toBe(0n);
    });

    it('lets only the owner retune the deployment fee, and it takes effect', async () => {
        // Non-owner cannot change it.
        const bad = await factory.send(seller.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateDeploymentFee', newFee: toNano('1'),
        });
        expect(bad.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect(await factory.getDeploymentFee()).toBe(toNano('4'));

        // Owner lowers it to 1 TON.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateDeploymentFee', newFee: toNano('1'),
        });
        expect(await factory.getDeploymentFee()).toBe(toNano('1'));

        // A create that would have bounced at 4 TON now succeeds at 1.3 TON.
        await factory.send(seller.getSender(), { value: toNano('1.3') }, {
            $$type: 'CreateListing',
            pricePerUnit: PRICE, initialSupply: 3n, minOrderQty: 0n, maxOrderQty: 0n,
            validationType: BigInt(VTYPE),
            settlementMode: 0n, agreementCID: null, nonce: 11n,
        });
        expect(await factory.getTotalListings()).toBe(1n);
    });

    it('rejects a deployment fee below the floor', async () => {
        const bad = await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateDeploymentFee', newFee: toNano('0.01'),
        });
        expect(bad.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
        expect(await factory.getDeploymentFee()).toBe(toNano('4'));
    });

    it('accrues the deployment fee into totalFeesCollected and lets the owner withdraw it', async () => {
        await createListing(seller, 3, 1n);

        const configBefore = await factory.getConfig();
        expect(configBefore.totalFeesCollected).toBe(toNano('4'));   // deploymentFee

        const result = await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'WithdrawFees' });

        expect(result.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: true });
        expect(result.transactions).toHaveTransaction({ from: factory.address, to: dao.address, success: true });

        const configAfter = await factory.getConfig();
        expect(configAfter.totalFeesCollected).toBe(0n);
    });

    it('rejects WithdrawFees from a non-owner', async () => {
        await createListing(seller, 3, 1n);

        const bad = await factory.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'WithdrawFees' });
        expect(bad.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect((await factory.getConfig()).totalFeesCollected).toBe(toNano('4'));
    });

    it('keeps the operational reserve behind and lets the owner retune it', async () => {
        expect((await factory.getConfig()).operationalReserve).toBe(toNano('2'));

        // Raise the reserve above the accrued fee so nothing is withdrawable.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateOperationalReserve', newOperationalReserve: toNano('100'),
        });
        expect((await factory.getConfig()).operationalReserve).toBe(toNano('100'));

        await createListing(seller, 3, 1n);
        const bad = await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'WithdrawFees' });
        expect(bad.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
        expect((await factory.getConfig()).totalFeesCollected).toBe(toNano('4'));
    });

    it('M2: a listing address stays stable after UpdateOracleRegistry (derives only from immutable params)', async () => {
        await createListing(seller, 3, 1n);
        const before = await factory.getListingAddress(1n);

        // Migrate the oracle registry — an admin op the factory deliberately provides.
        const newRegistry = await blockchain.treasury('newRegistry');
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateOracleRegistry', newRegistry: newRegistry.address,
        });

        // The existing listing's address must be unchanged, and still resolve to the
        // live deployed listing — pre-fix this getter re-derived to a dead address.
        const after = await factory.getListingAddress(1n);
        expect(after.equals(before)).toBe(true);
        const listing = blockchain.openContract(await MarketplaceListing.fromInit(factory.address, master.address, 1n));
        expect(listing.address.equals(after)).toBe(true);
        expect((await listing.getConfig()).active).toBe(true);
    });

    it('renewal fees flow through the factory accounting (totalFeesCollected), like creation fees', async () => {
        await createListing(seller, 3, 1n);
        expect((await factory.getConfig()).totalFeesCollected).toBe(toNano('4'));   // creation fee only

        const listing = blockchain.openContract(await MarketplaceListing.fromInit(factory.address, master.address, 1n));
        const expiryBefore = await listing.getExpiresAt();

        // Seller renews; a factory-created listing's renewFee equals the deploymentFee (4 TON).
        const res = await listing.send(seller.getSender(), { value: toNano('4.3') }, { $$type: 'RenewListing' });
        // The fee went to the factory (owner), NOT straight to the DAO.
        expect(res.transactions).toHaveTransaction({ from: listing.address, to: factory.address, success: true });

        // ...and was credited to the factory's fee accounting.
        expect((await factory.getConfig()).totalFeesCollected).toBeGreaterThan(toNano('7.9'));   // ~4 creation + ~4 renewal
        expect(await listing.getExpiresAt()).toBeGreaterThan(expiryBefore);
    });

    it('marketplace-wide pause blocks new listings; owner-only; resumable', async () => {
        expect(await factory.getPaused()).toBe(false);

        // Non-owner cannot pause.
        const badPause = await factory.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'SetMarketplacePaused', paused: true });
        expect(badPause.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect(await factory.getPaused()).toBe(false);

        // Owner pauses.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'SetMarketplacePaused', paused: true });
        expect(await factory.getPaused()).toBe(true);

        // CreateListing is now refused (no new listing recorded).
        const blocked = await createListing(seller, 3, 77n);
        expect(blocked.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
        expect(await factory.getTotalListings()).toBe(0n);

        // Owner resumes → creation works again.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'SetMarketplacePaused', paused: false });
        expect(await factory.getPaused()).toBe(false);
        await createListing(seller, 3, 78n);
        expect(await factory.getTotalListings()).toBe(1n);
    });

    // ── V3.1: quantity params + tunable protocol params ──────────────────────
    describe('V3.1 factory params', () => {
        it('29: CreateListing forwards minOrderQty/maxOrderQty to the listing', async () => {
            await createListing(seller, 1000, 1n, { minOrderQty: 50n, maxOrderQty: 500n });
            const l = await openListing(1n);
            expect(await l.getMinOrderQty()).toBe(50n);
            expect(await l.getMaxOrderQty()).toBe(500n);
            const cfg = await l.getConfig();
            expect(cfg.initialSupply).toBe(1000n);
            expect(cfg.remainingSupply).toBe(1000n);
        });

        it('30: CreateListing rejects maxOrderQty < minOrderQty', async () => {
            const bad = await createListing(seller, 1000, 2n, { minOrderQty: 100n, maxOrderQty: 50n });
            expect(bad.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
            expect(await factory.getTotalListings()).toBe(0n);
        });

        it('31: new listings inherit the factory default params (2% / 1% / 48h / 30d / 1h)', async () => {
            await createListing(seller, 10, 3n);
            const l = await openListing(1n);
            expect(await l.getListingGuaranteePercent()).toBe(2n);
            expect(await l.getListingCommissionPercent()).toBe(1n);
            expect(await l.getListingObjectionWindow()).toBe(172800n);
            expect(await l.getListingDisputeTimeoutWindow()).toBe(2592000n);
            expect(await l.getListingDestroyGraceWindow()).toBe(3600n);
        });

        it('32: UpdateListingParams retunes FUTURE listings only', async () => {
            await createListing(seller, 10, 1n);                     // listing A: defaults
            await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 5n, commissionPercent: 255n,       // 255 = leave commission unchanged
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 3600n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            await createListing(await blockchain.treasury('seller2'), 10, 1n);   // listing B: retuned

            const a = await openListing(1n);
            const b = await openListing(2n);
            expect(await a.getListingGuaranteePercent()).toBe(2n);   // unchanged
            expect(await a.getListingObjectionWindow()).toBe(172800n);
            expect(await b.getListingGuaranteePercent()).toBe(5n);   // retuned
            expect(await b.getListingObjectionWindow()).toBe(3600n);
        });

        it('33: commissionPercent sentinel — 0 is a real change, 255 is "unchanged"', async () => {
            await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 0n, commissionPercent: 0n,        // set commission to 0%
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect((await factory.getConfig()).commissionPercent).toBe(0n);

            await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 0n, commissionPercent: 255n,      // unchanged
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect((await factory.getConfig()).commissionPercent).toBe(0n);
        });

        it('34: UpdateListingParams is owner-only', async () => {
            const bad = await factory.send(seller.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 5n, commissionPercent: 255n,
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect(bad.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });
            expect((await factory.getConfig()).guaranteePercent).toBe(2n);
        });

        it('35: UpdateListingParams bounds guarantee 1..20 and commission 0..10', async () => {
            const badG = await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 21n, commissionPercent: 255n,
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect(badG.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });

            const badC = await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 0n, commissionPercent: 11n,
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect(badC.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
            expect((await factory.getConfig()).guaranteePercent).toBe(2n);
        });

        it('36: EvtListingDeployed carries the new fields and a uint64 initialSupply', async () => {
            const big = 5_000_000_000n;   // > uint32 max
            await createListing(seller, big, 1n, { minOrderQty: 10n, maxOrderQty: 0n });
            const l = await openListing(1n);
            expect(await l.getInitialSupply()).toBe(big);
            expect(await l.getRemainingSupply()).toBe(big);
            expect(await l.getMinOrderQty()).toBe(10n);
        });

        it('37: factory config() exposes the seven tunable params', async () => {
            const cfg = await factory.getConfig();
            expect(cfg.guaranteePercent).toBe(2n);
            expect(cfg.commissionPercent).toBe(1n);
            expect(cfg.deadlineWindow).toBe(2592000n);
            expect(cfg.listingWindow).toBe(2592000n);
            expect(cfg.objectionWindow).toBe(172800n);
            expect(cfg.disputeTimeoutWindow).toBe(2592000n);
            expect(cfg.destroyGraceWindow).toBe(3600n);
        });

        // ── Review fix L1: UpdateListingParams must clamp windows itself, not
        // just leave it to the next CreateListing to discover via a bounce. ──
        it('38: UpdateListingParams rejects an out-of-range window and leaves state unchanged', async () => {
            const bad = await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 0n, commissionPercent: 255n,
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 10n, // below the 300s floor
                disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect(bad.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
            expect((await factory.getConfig()).objectionWindow).toBe(172800n); // unchanged default

            // A subsequent CreateListing is unaffected — proves the bad value never landed.
            await createListing(seller, 10, 90n);
            const l = await openListing(1n);
            expect(await l.getListingObjectionWindow()).toBe(172800n);
        });

        it('39: UpdateListingParams accepts an in-range window and it flows to new listings', async () => {
            await factory.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateListingParams',
                guaranteePercent: 0n, commissionPercent: 255n,
                deadlineWindow: 0n, listingWindow: 0n,
                objectionWindow: 3600n,
                disputeTimeoutWindow: 0n, destroyGraceWindow: 0n,
            });
            expect((await factory.getConfig()).objectionWindow).toBe(3600n);
            await createListing(seller, 10, 91n);
            const l = await openListing(1n);
            expect(await l.getListingObjectionWindow()).toBe(3600n);
        });
    });

    // ── MK-N2 (factory half): a bounced listing deploy must release the seller's
    // nonce, or the wallet's auto-retry of the identical signed form fails with
    // "Duplicate listing submission" forever. ──
    it('40: a bounced listing deploy releases the nonce so the same signed form can be retried', async () => {
        const listingAddr = await factory.getListingAddress(1n);

        // Drive CreateListing one step: the factory marks the nonce seen and fires
        // the deploy+configure message, left in-flight via the paused iterator.
        const body = beginCell().store(storeCreateListing({
            $$type: 'CreateListing',
            pricePerUnit: PRICE,
            initialSupply: 3n,
            minOrderQty: 0n,
            maxOrderQty: 0n,
            validationType: BigInt(VTYPE),
            settlementMode: 0n,
            agreementCID: null,
            nonce: 1n,
        })).endCell();
        const relaxed = internal({ to: factory.address, value: toNano('4.3'), body, bounce: true });
        const iter = await blockchain.sendMessageIter(
            { info: { ...relaxed.info, src: seller.address }, body: relaxed.body } as any,
            { allowParallel: true },
        );
        await iter.next();
        expect(await factory.getTotalListings()).toBe(0n);   // deploy still in-flight, not acked

        // While the first form is in-flight, an identical resubmission is rejected.
        const dup = await createListing(seller, 3, 1n);
        expect(dup.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: false });

        // The deploy bounces back from the (never-initialized) listing address.
        const bounceBody = beginCell().storeUint(0xFFFFFFFF, 32).storeUint(0x1001, 32).endCell();
        const b = internal({ to: factory.address, value: toNano('0.3'), body: bounceBody, bounce: false });
        const bounced = await blockchain.sendMessage({
            info: { ...b.info, src: listingAddr, bounced: true },
            body: b.body,
        } as any);

        // The seller was refunded and the nonce released: the identical form now succeeds.
        expect(bounced.transactions).toHaveTransaction({ from: factory.address, to: seller.address, success: true });
        const retry = await createListing(seller, 3, 1n);
        expect(retry.transactions).toHaveTransaction({ from: seller.address, to: factory.address, success: true });
        expect(await factory.getTotalListings()).toBe(1n);

        // clean up the still-open iterator (the stale deploy lands harmlessly — its
        // ListingConfigured ack no longer matches a pending entry and is rejected)
        let r = await iter.next();
        while (!r.done) r = await iter.next();
        expect(await factory.getTotalListings()).toBe(1n);
    });
});
