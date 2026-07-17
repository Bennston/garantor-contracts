import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell, Cell } from '@ton/core';
import { keyPairFromSeed, sign, KeyPair } from '@ton/crypto';
import { MarketplaceFactory } from '../build/MarketplaceFactory/tact_MarketplaceFactory';
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
    const createListing = async (who: SandboxContract<TreasuryContract>, supply: number, nonce: bigint) =>
        factory.send(who.getSender(), { value: toNano('4.3') }, {
            $$type: 'CreateListing',
            pricePerUnit: PRICE,
            initialSupply: BigInt(supply),
            validationType: BigInt(VTYPE),
            settlementMode: 0n,   // oracle-only
            agreementCID: null,
            nonce,
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
            factory.address, dao.address, master.address, registry.address, commissionaires.address, 1n,
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
            factory.address, dao.address, master.address, registry.address, commissionaires.address, 1n,
        ));

        // Buyer purchases a unit → listing deploys a seeded oracle vault.
        await listing.send(buyer.getSender(), { value: toNano('0.6') }, { $$type: 'PurchaseListing', nonce: 1n });
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
            factory.address, dao.address, master.address, registry.address, commissionaires.address, 2n,
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
            pricePerUnit: PRICE, initialSupply: 3n, validationType: BigInt(VTYPE),
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
            pricePerUnit: PRICE, initialSupply: 3n, validationType: BigInt(VTYPE),
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
});
