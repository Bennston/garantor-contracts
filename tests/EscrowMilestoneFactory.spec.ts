import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano } from '@ton/core';
import { EscrowMilestoneFactory } from '../build/EscrowMilestoneFactory/tact_EscrowMilestoneFactory';
import { EscrowVaultMilestone } from '../build/EscrowVaultMilestone/tact_EscrowVaultMilestone';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('EscrowMilestoneFactory', () => {
    let blockchain: Blockchain;
    let dao: SandboxContract<TreasuryContract>;
    let creator: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let arbitrator: SandboxContract<TreasuryContract>;
    let referrer: SandboxContract<TreasuryContract>;
    let factory: SandboxContract<EscrowMilestoneFactory>;

    const CREATE_VALUE = toNano('2.1');

    beforeAll(async () => {
        await compile('EscrowVaultMilestone');
        await compile('EscrowMilestoneFactory');
    }, 60_000);

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        dao = await blockchain.treasury('dao');
        creator = await blockchain.treasury('creator');
        buyer = await blockchain.treasury('buyer');
        seller = await blockchain.treasury('seller');
        arbitrator = await blockchain.treasury('arbitrator');
        referrer = await blockchain.treasury('referrer');

        factory = blockchain.openContract(
            await EscrowMilestoneFactory.fromInit(dao.address, 1n),
        );

        await factory.send(
            dao.getSender(),
            { value: toNano('0.05') },
            { $$type: 'UpdateArbitratorFee', newArbitratorFee: toNano('0.1') },
        );
    });

    it('registers a milestone vault only after init acknowledgement succeeds', async () => {
        const result = await factory.send(
            creator.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateMilestoneVault',
                buyer: buyer.address,
                seller: seller.address,
                arbitrator: arbitrator.address,
                referrer: referrer.address,
                referrerFeeBps: 100n,
                milestoneCount: 2n,
                m0Value: toNano('400'),
                m1Value: toNano('1600'),
                m0Window: 259_200n,
                m1Window: 172_800n,
                m0DeliveryWindow: 2_592_000n,
                m1DeliveryWindow: 3_888_000n,
                performanceBond: toNano('40'),
                tradeRef: 'Factory happy path',
            },
        );

        expect(result.transactions).toHaveTransaction({ from: creator.address, to: factory.address, success: true });

        const config = await factory.getConfig();
        expect(config.totalVaultsDeployed).toBe(1n);
        expect(config.totalFeesCollected).toBe(toNano('1.77'));
        expect(await factory.getWalletVaultCount(buyer.address, true)).toBe(1n);
        expect(await factory.getWalletVaultCount(seller.address, false)).toBe(1n);
        expect(await factory.getReferrerVaultCount(referrer.address)).toBe(1n);

        const vaultAddress = await factory.getVaultAddress(1n);
        expect(result.transactions).toHaveTransaction({ from: factory.address, to: vaultAddress, deploy: true, success: true });
    });

    it('refunds the creator and keeps registries clean when milestone vault init bounces', async () => {
        const result = await factory.send(
            creator.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateMilestoneVault',
                buyer: buyer.address,
                seller: seller.address,
                arbitrator: arbitrator.address,
                referrer: referrer.address,
                referrerFeeBps: 100n,
                milestoneCount: 2n,
                m0Value: toNano('400'),
                m1Value: toNano('1600'),
                m0Window: 10n,
                m1Window: 172_800n,
                m0DeliveryWindow: 2_592_000n,
                m1DeliveryWindow: 3_888_000n,
                performanceBond: toNano('40'),
                tradeRef: 'Factory bounce path',
            },
        );

        expect(result.transactions).toHaveTransaction({ from: creator.address, to: factory.address, success: true });
        expect(result.transactions).toHaveTransaction({ from: factory.address, to: creator.address, success: true });

        const config = await factory.getConfig();
        expect(config.totalVaultsDeployed).toBe(0n);
        expect(config.totalFeesCollected).toBe(0n);
        expect(await factory.getWalletVaultCount(buyer.address, true)).toBe(0n);
        expect(await factory.getWalletVaultCount(seller.address, false)).toBe(0n);
        expect(await factory.getReferrerVaultCount(referrer.address)).toBe(0n);
    });

    it('pins the vault arbitrator to the factory owner, ignoring the caller value (#2)', async () => {
        await factory.send(
            creator.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateMilestoneVault',
                buyer: buyer.address,
                seller: seller.address,
                arbitrator: arbitrator.address,   // attacker-supplied — must be IGNORED
                referrer: referrer.address,
                referrerFeeBps: 100n,
                milestoneCount: 2n,
                m0Value: toNano('400'),
                m1Value: toNano('1600'),
                m0Window: 259_200n,
                m1Window: 172_800n,
                m0DeliveryWindow: 2_592_000n,
                m1DeliveryWindow: 3_888_000n,
                performanceBond: toNano('40'),
                tradeRef: 'arbitrator pin test',
            },
        );

        const vaultAddress = await factory.getVaultAddress(1n);
        const vault = blockchain.openContract(EscrowVaultMilestone.fromAddress(vaultAddress));
        const arb = await vault.getArbitrator();
        expect(arb.equals(dao.address)).toBe(true);          // pinned to factory owner (DAO)
        expect(arb.equals(arbitrator.address)).toBe(false);  // NOT the caller-supplied value
    });
});