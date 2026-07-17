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

    const purchase = async (who: SandboxContract<TreasuryContract>, nonce: bigint) =>
        listing.send(who.getSender(), { value: toNano('0.6') }, { $$type: 'PurchaseListing', nonce });

    const configure = async (supply: number) =>
        listing.send(dao.getSender(), { value: toNano('0.1') }, {
            $$type: 'ConfigureListing',
            seller: seller.address,
            pricePerUnit: PRICE,
            initialSupply: BigInt(supply),
            validationType: BigInt(VTYPE),
            settlementMode: 0n,   // oracle-only
            agreementCID: null,
        });

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
            dao.address, dao.address, master.address, registry.address, commissionaires.address, 1n,
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

        const purchaseBody = beginCell().store(storePurchaseListing({ $$type: 'PurchaseListing', nonce: 1n })).endCell();
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
});
