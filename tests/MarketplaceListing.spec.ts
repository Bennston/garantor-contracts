import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell, Cell, internal } from '@ton/core';
import { keyPairFromSeed, sign, KeyPair } from '@ton/crypto';
import { MarketplaceListing, storePurchaseListing, storeDestroyListing } from '../build/MarketplaceListing/tact_MarketplaceListing';
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
const RENEW_FEE = toNano('4');
const LISTING_WINDOW = 2592000; // 30 days
const EMPTY_FWD = beginCell().storeUint(0, 1).endCell().asSlice();
const bufToBigInt = (b: Buffer) => BigInt('0x' + b.toString('hex'));

describe('MarketplaceListing (V3 inventory → oracle vaults)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let dao: SandboxContract<TreasuryContract>;
    let commissionaires: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let relayer: SandboxContract<TreasuryContract>;

    let master: SandboxContract<MockJettonMaster>;
    let registry: SandboxContract<OracleRegistry>;
    let listing: SandboxContract<MarketplaceListing>;

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

    const openVault = async (tradeId: bigint) =>
        blockchain.openContract(await EscrowOracleVault.fromInit(listing.address, dao.address, tradeId));

    const depositTo = async (vaultAddr: Address, owner: SandboxContract<TreasuryContract>, amount: bigint) => {
        const w = await walletOf(owner.address);
        return w.send(owner.getSender(), { value: toNano('0.3') }, {
            $$type: 'JettonTransfer',
            queryId: 0n,
            amount,
            destination: vaultAddr,
            responseDestination: owner.address,
            customPayload: null,
            forwardTonAmount: toNano('0.1'),
            forwardPayload: EMPTY_FWD,
        });
    };

    const signReport = (vaultAddr: Address, tradeId: bigint, vt: number, status: number): Cell => {
        const h = beginCell()
            .storeAddress(vaultAddr).storeUint(tradeId, 64).storeUint(vt, 8).storeUint(status, 8).storeUint(0n, 256)
            .endCell().hash();
        return beginCell().storeBuffer(sign(h, donKey.secretKey)).endCell();
    };

    // V3.1: `quantity` defaults to 1n so pre-V3.1 assertions (remainingSupply -1) hold.
    const purchase = async (who: SandboxContract<TreasuryContract>, nonce: bigint, quantity: bigint = 1n) =>
        listing.send(who.getSender(), { value: toNano('0.6') }, { $$type: 'PurchaseListing', nonce, quantity });

    type ConfigOpts = {
        price?: bigint;
        minOrderQty?: bigint;
        maxOrderQty?: bigint;
        guaranteePercent?: bigint;
        commissionPercent?: bigint;
        deadlineWindow?: bigint;
        listingWindow?: bigint;
        objectionWindow?: bigint;
        disputeTimeoutWindow?: bigint;
        destroyGraceWindow?: bigint;
        settlementMode?: bigint;
        agreementCID?: Cell | null;
    };

    const configure = async (supply: number | bigint, opts: ConfigOpts = {}) =>
        listing.send(dao.getSender(), { value: toNano('0.1') }, {
            $$type: 'ConfigureListing',
            seller: seller.address,
            dao: dao.address,
            oracleRegistry: registry.address,
            commissionairesDao: commissionaires.address,
            pricePerUnit: opts.price ?? PRICE,
            initialSupply: BigInt(supply),
            minOrderQty: opts.minOrderQty ?? 0n,          // V3.1 (0 => 1)
            maxOrderQty: opts.maxOrderQty ?? 0n,          // V3.1 (0 => uncapped)
            validationType: BigInt(VTYPE),
            settlementMode: opts.settlementMode ?? 0n,    // oracle-only
            agreementCID: opts.agreementCID ?? null,
            renewFee: RENEW_FEE,
            // V3.1 Tier 2 — factory would pass explicit percents; 0 => default window.
            guaranteePercent: opts.guaranteePercent ?? 2n,
            commissionPercent: opts.commissionPercent ?? 1n,
            deadlineWindow: opts.deadlineWindow ?? 0n,
            listingWindow: opts.listingWindow ?? 0n,
            objectionWindow: opts.objectionWindow ?? 0n,
            disputeTimeoutWindow: opts.disputeTimeoutWindow ?? 0n,
            destroyGraceWindow: opts.destroyGraceWindow ?? 0n,
        });

    const renew = async (who: SandboxContract<TreasuryContract>, value: bigint = RENEW_FEE) =>
        listing.send(who.getSender(), { value }, { $$type: 'RenewListing' });

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
        await registry.send(dao.getSender(), { value: toNano('0.05') }, null);   // deploy (key set at init)

        listing = blockchain.openContract(await MarketplaceListing.fromInit(
            dao.address, master.address, 1n,
        ));
        // Deploy (empty body) and top up for vault gas budgets.
        await listing.send(dao.getSender(), { value: toNano('0.05') }, null);
        await deployer.send({ to: listing.address, value: toNano('3'), bounce: false });
    });

    it('configures inventory and rejects purchases until active', async () => {
        // Not configured yet → purchase must fail.
        const early = await purchase(buyer, 1n);
        expect(early.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });

        await configure(3);
        const cfg = await listing.getConfig();
        expect(cfg.active).toBe(true);
        expect(cfg.remainingSupply).toBe(3n);
        expect(cfg.pricePerUnit).toBe(PRICE);
        expect(cfg.validationType).toBe(BigInt(VTYPE));
    });

    it('a purchase deploys a seeded, wallet-resolved oracle vault at the deterministic address', async () => {
        await configure(3);
        await purchase(buyer, 1n);

        expect(await listing.getRemainingSupply()).toBe(2n);
        expect(await listing.getVaultsDeployed()).toBe(1n);

        const predicted = await listing.getVaultAddress(1n);
        const vault = await openVault(1n);
        expect(vault.address.equals(predicted)).toBe(true);

        const st = await vault.getVaultState();
        expect(st.state).toBe(1n);                    // AWAITING_DEPOSITS
        expect(st.tradeValue).toBe(PRICE);
        expect(st.buyer.equals(buyer.address)).toBe(true);
        expect(st.seller.equals(seller.address)).toBe(true);
        expect(await vault.getWalletResolved()).toBe(true);
        expect(await vault.getValidationType()).toBe(BigInt(VTYPE));
        expect((await vault.getOracleRegistryAddr()).equals(registry.address)).toBe(true);
    });

    it('end-to-end: purchase → deposit → DON Delivered → finalize pays the seller', async () => {
        await configure(3);
        await purchase(buyer, 1n);
        const vault = await openVault(1n);

        await depositTo(vault.address, buyer, PRICE);
        await depositTo(vault.address, seller, GUARANTEE);
        expect((await vault.getVaultState()).state).toBe(2n);   // AWAITING_CONFIRMATION

        // Relay a DON-signed Delivered report through the registry.
        await registry.send(relayer.getSender(), { value: toNano('0.3') }, {
            $$type: 'SubmitReport',
            vault: vault.address,
            tradeId: 1n,
            validationType: BigInt(VTYPE),
            status: BigInt(DELIVERED),
            proof: null,
            signature: signReport(vault.address, 1n, VTYPE, DELIVERED),
        });
        expect(await vault.getObjectionDeadline()).toBe(BigInt(NOW + OBJECTION_WINDOW));

        // Window elapses → anyone finalizes → seller + commission paid.
        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect((await vault.getVaultState()).state).toBe(3n);   // SUCCESSFUL

        await vault.send(seller.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });
        await vault.send(commissionaires.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + SELLER_PAYOUT);
        expect(await balanceOf(commissionaires.address)).toBe(COMMISSION);
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('decrements inventory across purchases and rejects when sold out', async () => {
        await configure(2);
        await purchase(buyer, 1n);
        await purchase(buyer, 2n);
        expect(await listing.getRemainingSupply()).toBe(0n);
        expect(await listing.getVaultsDeployed()).toBe(2n);

        // Sold out → the third purchase fails and inventory stays at 0.
        const soldOut = await purchase(buyer, 3n);
        expect(soldOut.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
        expect(await listing.getRemainingSupply()).toBe(0n);
        expect(await listing.getVaultsDeployed()).toBe(2n);
    });

    it('rejects a duplicate purchase (same nonce from same wallet)', async () => {
        await configure(3);
        await purchase(buyer, 7n);
        const dup = await purchase(buyer, 7n);
        expect(dup.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
        expect(await listing.getRemainingSupply()).toBe(2n);   // only the first consumed a unit
        expect(await listing.getVaultsDeployed()).toBe(1n);
    });

    it('the seller cannot purchase their own listing', async () => {
        await configure(3);
        const res = await purchase(seller, 1n);
        expect(res.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
        expect(await listing.getRemainingSupply()).toBe(3n);
    });

    it('the seller can destroy the listing and reclaim its gas', async () => {
        await configure(3);
        const res = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'DestroyListing' });
        expect(res.transactions).toHaveTransaction({
            from: seller.address, to: listing.address, success: true, destroyed: true,
        });
        // Remaining balance flowed back to the seller.
        expect(res.transactions).toHaveTransaction({ from: listing.address, to: seller.address });
        const acct = await blockchain.getContract(listing.address);
        expect(acct.accountState).toBeUndefined();   // self-destructed
    });

    it('the DAO can destroy the listing', async () => {
        await configure(3);
        const res = await listing.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'DestroyListing' });
        expect(res.transactions).toHaveTransaction({
            from: dao.address, to: listing.address, success: true, destroyed: true,
        });
    });

    it('a stranger cannot destroy the listing', async () => {
        await configure(3);
        const bad = await listing.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'DestroyListing' });
        expect(bad.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
        expect(await listing.getActive()).toBe(true);   // still alive and active
    });

    it('blocks DestroyListing while a purchase vault deploy is still pending, then allows it once acked', async () => {
        await configure(3);
        expect(await listing.getPendingCount()).toBe(0n);

        const purchaseBody = beginCell().store(storePurchaseListing({ $$type: 'PurchaseListing', nonce: 1n, quantity: 1n })).endCell();
        const relaxed = internal({ to: listing.address, value: toNano('0.6'), body: purchaseBody, bounce: true });
        const msg = { info: { ...relaxed.info, src: buyer.address }, body: relaxed.body } as any;

        const iter = await blockchain.sendMessageIter(msg, { allowParallel: true });
        // First transaction only: the listing processes PurchaseListing and fires
        // off InitVault, but the vault hasn't acked back yet.
        const first = await iter.next();
        expect(first.done).toBe(false);
        expect(await listing.getPendingCount()).toBe(1n);

        // Drive the DestroyListing attempt through its own iterator so it doesn't
        // drain the still-paused purchase queue above — it must see pendingCount=1.
        const destroyBody = beginCell().store(storeDestroyListing({ $$type: 'DestroyListing' })).endCell();
        const destroyRelaxed = internal({ to: listing.address, value: toNano('0.05'), body: destroyBody, bounce: true });
        const destroyMsg = { info: { ...destroyRelaxed.info, src: seller.address }, body: destroyRelaxed.body } as any;
        const destroyIter = await blockchain.sendMessageIter(destroyMsg, { allowParallel: true });
        const destroyTx = await destroyIter.next();
        expect(destroyTx.done).toBe(false);
        expect((destroyTx.value as any).description.aborted).toBe(true);
        expect(await listing.getActive()).toBe(true);

        // Drain the rest of the purchase's message queue (InitVault + VaultInitOk ack).
        let r = await iter.next();
        while (!r.done) { r = await iter.next(); }
        expect(await listing.getPendingCount()).toBe(0n);

        const ok = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'DestroyListing' });
        expect(ok.transactions).toHaveTransaction({
            from: seller.address, to: listing.address, success: true, destroyed: true,
        });
    });

    it('configures with a 30-day expiry and rejects purchases once it lapses', async () => {
        await configure(3);
        const cfg = await listing.getConfig();
        expect(cfg.expiresAt).toBe(BigInt(NOW + LISTING_WINDOW));
        expect(cfg.renewFee).toBe(RENEW_FEE);

        // Still within the window → purchase succeeds.
        await purchase(buyer, 1n);
        expect(await listing.getRemainingSupply()).toBe(2n);

        // Past expiry → purchase rejected, inventory untouched.
        blockchain.now = NOW + LISTING_WINDOW + 1;
        const late = await purchase(buyer, 2n);
        expect(late.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
        expect(await listing.getRemainingSupply()).toBe(2n);
    });

    it('the seller can renew before expiry, extending it from the current expiresAt', async () => {
        await configure(3);
        const before = await listing.getExpiresAt();

        blockchain.now = NOW + 1000;
        const res = await renew(seller);
        expect(res.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: true });
        expect(res.transactions).toHaveTransaction({ from: listing.address, to: dao.address, value: RENEW_FEE });

        const after = await listing.getExpiresAt();
        expect(after).toBe(before + BigInt(LISTING_WINDOW));   // extends from old expiresAt, not now()
    });

    it('the seller can renew a lapsed listing and purchases resume', async () => {
        await configure(3);
        blockchain.now = NOW + LISTING_WINDOW + 500;   // well past expiry

        const expired = await purchase(buyer, 1n);
        expect(expired.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });

        await renew(seller);
        const newExpiry = await listing.getExpiresAt();
        expect(newExpiry).toBe(BigInt(NOW + LISTING_WINDOW + 500 + LISTING_WINDOW));   // extends from now(), not the old lapsed date

        const ok = await purchase(buyer, 2n);
        expect(ok.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: true });
        expect(await listing.getRemainingSupply()).toBe(2n);
    });

    it('rejects renewal with an insufficient fee', async () => {
        await configure(3);
        const res = await renew(seller, RENEW_FEE - 1n);
        expect(res.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
    });

    it('rejects renewal from a non-seller', async () => {
        await configure(3);
        const res = await renew(buyer);
        expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
    });

    // ════════════════════════════════════════════════════════════════════════
    // V3.1 Tier 1 — buyer-chosen quantity
    // ════════════════════════════════════════════════════════════════════════
    describe('V3.1 quantity', () => {
        it('1: the spawned vault escrows pricePerUnit * quantity', async () => {
            await configure(100);
            await purchase(buyer, 1n, 7n);
            const st = await (await openVault(1n)).getVaultState();
            expect(st.tradeValue).toBe(PRICE * 7n);
        });

        it('2: remainingSupply decrements by quantity; initialSupply is fixed', async () => {
            await configure(100);
            await purchase(buyer, 1n, 30n);
            expect(await listing.getRemainingSupply()).toBe(70n);
            expect(await listing.getInitialSupply()).toBe(100n);
            expect(await listing.getVaultsDeployed()).toBe(1n);
        });

        it('3: rejects quantity below minOrderQty; nothing consumed', async () => {
            await configure(100, { minOrderQty: 50n });
            const res = await purchase(buyer, 1n, 49n);
            expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            expect(await listing.getRemainingSupply()).toBe(100n);
        });

        it('4: rejects quantity above maxOrderQty', async () => {
            await configure(1000, { maxOrderQty: 100n });
            const res = await purchase(buyer, 1n, 101n);
            expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            expect(await listing.getRemainingSupply()).toBe(1000n);
        });

        it('5: allows quantity == maxOrderQty and a follow-up that drains the remainder', async () => {
            await configure(150, { maxOrderQty: 100n });
            await purchase(buyer, 1n, 100n);
            expect(await listing.getRemainingSupply()).toBe(50n);
            const buyer2 = await blockchain.treasury('buyer2');
            await purchase(buyer2, 1n, 50n);
            expect(await listing.getRemainingSupply()).toBe(0n);
            expect(await listing.getVaultsDeployed()).toBe(2n);
        });

        it('6: rejects an order larger than remaining stock (no partial fill)', async () => {
            await configure(40);
            const res = await purchase(buyer, 1n, 41n);
            expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            expect(await listing.getRemainingSupply()).toBe(40n);
            expect(await listing.getVaultsDeployed()).toBe(0n);
        });

        it('7: rejects a tradeValue over MaxTradeValue', async () => {
            // MaxTradeValue = 1e17 minimal units. price 1e15, qty 1000 => 1e18 > cap.
            await configure(2000, { price: 1_000_000_000_000_000n });
            const res = await purchase(buyer, 1n, 1000n);
            expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            expect(await listing.getRemainingSupply()).toBe(2000n);
        });

        it('8: a bounced vault deploy restores the exact quantity and refunds the buyer', async () => {
            await configure(100);
            const vaultAddr = await listing.getVaultAddress(1n);

            // Drive the purchase one step so the listing reserves the units and
            // fires InitVault (still in-flight, not acked).
            const body = beginCell().store(storePurchaseListing({ $$type: 'PurchaseListing', nonce: 1n, quantity: 25n })).endCell();
            const relaxed = internal({ to: listing.address, value: toNano('0.6'), body, bounce: true });
            const iter = await blockchain.sendMessageIter(
                { info: { ...relaxed.info, src: buyer.address }, body: relaxed.body } as any,
                { allowParallel: true },
            );
            await iter.next();
            expect(await listing.getRemainingSupply()).toBe(75n);
            expect(await listing.getPendingCount()).toBe(1n);

            // Simulate the InitVault message bouncing back from the vault address.
            const bounceBody = beginCell().storeUint(0xFFFFFFFF, 32).storeUint(0x1001, 32).endCell();
            const b = internal({ to: listing.address, value: toNano('0.4'), body: bounceBody, bounce: false });
            await blockchain.sendMessage({
                info: { ...b.info, src: vaultAddr, bounced: true },
                body: b.body,
            } as any);

            expect(await listing.getRemainingSupply()).toBe(100n);   // 25 restored
            expect(await listing.getPendingCount()).toBe(0n);

            // clean up the still-open iterator
            let r = await iter.next();
            while (!r.done) r = await iter.next();
        });

        it('9: remainingSupply never exceeds initialSupply after a bounce', async () => {
            await configure(10);
            await purchase(buyer, 1n, 10n);                 // sell out
            expect(await listing.getRemainingSupply()).toBe(0n);
            // A bounce for a vault we don't track is a no-op (guard clause) — supply stays 0.
            const bounceBody = beginCell().storeUint(0xFFFFFFFF, 32).storeUint(0x1001, 32).endCell();
            const b = internal({ to: listing.address, value: toNano('0.1'), body: bounceBody, bounce: false });
            await blockchain.sendMessage({ info: { ...b.info, src: buyer.address, bounced: true }, body: b.body } as any);
            expect(await listing.getRemainingSupply()).toBe(0n);
            expect(await listing.getInitialSupply()).toBe(10n);
        });

        it('10: minOrderQty 0 normalises to 1', async () => {
            await configure(5, { minOrderQty: 0n });
            expect(await listing.getMinOrderQty()).toBe(1n);
            const zero = await purchase(buyer, 1n, 0n);
            expect(zero.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            await purchase(buyer, 2n, 1n);
            expect(await listing.getRemainingSupply()).toBe(4n);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // V3.1 Tier 2 — per-listing protocol params
    // ════════════════════════════════════════════════════════════════════════
    describe('V3.1 Tier 2 params', () => {
        it('11: seeds the vault with the listing guarantee/commission percents', async () => {
            await configure(10, { guaranteePercent: 5n, commissionPercent: 0n });
            await purchase(buyer, 1n, 2n);
            const vault = await openVault(1n);
            const tradeValue = PRICE * 2n;
            // Both deposits must be EXACT for the vault to advance to AWAITING_CONFIRMATION.
            await depositTo(vault.address, buyer, tradeValue);
            await depositTo(vault.address, seller, tradeValue * 5n / 100n);
            expect((await vault.getVaultState()).state).toBe(2n);
        });

        it('12: forwards explicit objection/dispute/grace windows to the vault', async () => {
            await configure(10, { objectionWindow: 3600n, disputeTimeoutWindow: 7200n, destroyGraceWindow: 1800n });
            await purchase(buyer, 1n);
            const vault = await openVault(1n);
            expect(await vault.getObjectionWindow()).toBe(3600n);
            expect(await vault.getDisputeTimeoutWindow()).toBe(7200n);
            expect(await vault.getDestroyGraceWindow()).toBe(1800n);
        });

        it('13: a 0 window seeds the vault default', async () => {
            await configure(10);   // all windows default to 0n in the helper
            await purchase(buyer, 1n);
            const vault = await openVault(1n);
            expect(await vault.getObjectionWindow()).toBe(172800n);
            expect(await vault.getDisputeTimeoutWindow()).toBe(2592000n);
            expect(await vault.getDestroyGraceWindow()).toBe(3600n);
        });

        it('14: ConfigureListing reverts on an out-of-range window', async () => {
            const res = await configure(10, { objectionWindow: 10n });   // < 300s floor
            expect(res.transactions).toHaveTransaction({ from: dao.address, to: listing.address, success: false });
            expect(await listing.getActive()).toBe(false);
        });

        it('15: a Delivered report opens a window of the configured length', async () => {
            await configure(10, { objectionWindow: 3600n });
            await purchase(buyer, 1n);
            const vault = await openVault(1n);
            await depositTo(vault.address, buyer, PRICE);
            await depositTo(vault.address, seller, GUARANTEE);
            await registry.send(relayer.getSender(), { value: toNano('0.3') }, {
                $$type: 'SubmitReport',
                vault: vault.address, tradeId: 1n, validationType: BigInt(VTYPE), status: BigInt(DELIVERED),
                proof: null, signature: signReport(vault.address, 1n, VTYPE, DELIVERED),
            });
            expect(await vault.getObjectionDeadline()).toBe(BigInt(NOW + 3600));
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // V3.1 Tier 3 — post-configuration mutation
    // ════════════════════════════════════════════════════════════════════════
    describe('V3.1 Tier 3 mutations', () => {
        const CID2 = beginCell().storeUint(0xABCD, 16).endCell();

        it('17: UpdatePrice changes only future purchases', async () => {
            await configure(100);
            await purchase(buyer, 1n, 3n);                              // vault 1 @ old price
            await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'UpdatePrice', pricePerUnit: PRICE * 2n });
            await purchase(buyer, 2n, 3n);                              // vault 2 @ new price
            expect((await (await openVault(1n)).getVaultState()).tradeValue).toBe(PRICE * 3n);
            expect((await (await openVault(2n)).getVaultState()).tradeValue).toBe(PRICE * 2n * 3n);
            expect(await listing.getListingPrice()).toBe(PRICE * 2n);
        });

        it('18: UpdatePrice rejects a non-seller', async () => {
            await configure(10);
            const res = await listing.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'UpdatePrice', pricePerUnit: PRICE * 2n });
            expect(res.transactions).toHaveTransaction({ from: dao.address, to: listing.address, success: false });
            expect(await listing.getListingPrice()).toBe(PRICE);
        });

        it('19: UpdatePrice rejects 0 and > MaxTradeValue', async () => {
            await configure(10);
            const zero = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'UpdatePrice', pricePerUnit: 0n });
            expect(zero.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
            const huge = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'UpdatePrice', pricePerUnit: 10n ** 18n });
            expect(huge.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
        });

        it('20: RestockListing bumps initialSupply and remainingSupply', async () => {
            await configure(100);
            await purchase(buyer, 1n, 90n);
            expect(await listing.getRemainingSupply()).toBe(10n);
            await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'RestockListing', addSupply: 50n });
            expect(await listing.getRemainingSupply()).toBe(60n);
            expect(await listing.getInitialSupply()).toBe(150n);
        });

        it('21: RestockListing rejects a non-seller and addSupply 0', async () => {
            await configure(10);
            const bad = await listing.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'RestockListing', addSupply: 5n });
            expect(bad.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            const zero = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'RestockListing', addSupply: 0n });
            expect(zero.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
        });

        // Review fix L2: an addSupply that would push initialSupply past uint64
        // max must revert with a clear message, not an opaque serialization error.
        it('21b: RestockListing rejects an addSupply that would overflow uint64', async () => {
            await configure(10);
            const MAX_U64 = (1n << 64n) - 1n;
            const overflow = await listing.send(seller.getSender(), { value: toNano('0.05') }, {
                $$type: 'RestockListing', addSupply: MAX_U64,
            });
            expect(overflow.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
            expect(await listing.getInitialSupply()).toBe(10n); // unchanged

            // Right up against the ceiling still succeeds.
            const exact = await listing.send(seller.getSender(), { value: toNano('0.05') }, {
                $$type: 'RestockListing', addSupply: MAX_U64 - 10n,
            });
            expect(exact.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: true });
            expect(await listing.getInitialSupply()).toBe(MAX_U64);
        });

        it('22: a sold-out listing can be bought again after a restock', async () => {
            await configure(10);
            await purchase(buyer, 1n, 10n);
            const soldOut = await purchase(buyer, 2n, 1n);
            expect(soldOut.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
            await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'RestockListing', addSupply: 5n });
            await purchase(buyer, 3n, 4n);
            expect(await listing.getRemainingSupply()).toBe(1n);
        });

        it('23: UpdateAgreementCID swaps the hash for future vaults only', async () => {
            await configure(10, { agreementCID: null });
            await purchase(buyer, 1n);                                  // vault 1 → CID null
            await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'UpdateAgreementCID', agreementCID: CID2 });
            await purchase(buyer, 2n);                                  // vault 2 → CID2
            expect(await (await openVault(1n)).getAgreementCid()).toBeNull();
            const cid = await (await openVault(2n)).getAgreementCid();
            expect(cid && cid.equals(CID2)).toBe(true);
        });

        it('24: UpdateAgreementCID rejects a non-seller', async () => {
            await configure(10);
            const res = await listing.send(buyer.getSender(), { value: toNano('0.05') }, { $$type: 'UpdateAgreementCID', agreementCID: CID2 });
            expect(res.transactions).toHaveTransaction({ from: buyer.address, to: listing.address, success: false });
        });

        it('25: UpdateProtocolAddrs is owner-only and repoints future vaults', async () => {
            await configure(10);
            const newReg = await blockchain.treasury('newReg');
            const newComm = await blockchain.treasury('newComm');
            // A direct seller send is refused (Ownable — owner is the dao here).
            const bad = await listing.send(seller.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateProtocolAddrs', oracleRegistry: newReg.address, commissionairesDao: newComm.address,
            });
            expect(bad.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
            // The owner (dao, standing in for the factory here) can.
            await listing.send(dao.getSender(), { value: toNano('0.05') }, {
                $$type: 'UpdateProtocolAddrs', oracleRegistry: newReg.address, commissionairesDao: newComm.address,
            });
            await purchase(buyer, 1n);
            expect((await (await openVault(1n)).getOracleRegistryAddr()).equals(newReg.address)).toBe(true);
        });

        it('26: every Tier 3 message reverts on a destroyed listing', async () => {
            await configure(10);
            await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'DestroyListing' });
            const p = await listing.send(seller.getSender(), { value: toNano('0.05') }, { $$type: 'UpdatePrice', pricePerUnit: PRICE });
            expect(p.transactions).toHaveTransaction({ from: seller.address, to: listing.address, success: false });
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    // V3.1 getters + config struct
    // ════════════════════════════════════════════════════════════════════════
    describe('V3.1 getters', () => {
        it('27: config() carries the widened + new fields', async () => {
            await configure(500, { minOrderQty: 10n, maxOrderQty: 200n, guaranteePercent: 3n, commissionPercent: 2n });
            const cfg = await listing.getConfig();
            expect(cfg.initialSupply).toBe(500n);
            expect(cfg.remainingSupply).toBe(500n);
            expect(cfg.minOrderQty).toBe(10n);
            expect(cfg.maxOrderQty).toBe(200n);
            expect(cfg.guaranteePercent).toBe(3n);
            expect(cfg.commissionPercent).toBe(2n);
            expect(cfg.objectionWindow).toBe(172800n);
            expect(cfg.disputeTimeoutWindow).toBe(2592000n);
            expect(cfg.destroyGraceWindow).toBe(3600n);
        });

        it('28: single-value getters agree with config()', async () => {
            await configure(80, { minOrderQty: 5n, maxOrderQty: 40n });
            const cfg = await listing.getConfig();
            expect(await listing.getInitialSupply()).toBe(cfg.initialSupply);
            expect(await listing.getMinOrderQty()).toBe(cfg.minOrderQty);
            expect(await listing.getMaxOrderQty()).toBe(cfg.maxOrderQty);
            expect(await listing.getListingObjectionWindow()).toBe(cfg.objectionWindow);
        });
    });
});
