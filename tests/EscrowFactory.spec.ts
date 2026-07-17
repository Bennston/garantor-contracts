import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano, Address } from '@ton/core';
import { EscrowFactory } from '../build/EscrowFactory/tact_EscrowFactory';
import { EscrowVault } from '../build/EscrowVault/tact_EscrowVault';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('EscrowFactory', () => {
    let blockchain: Blockchain;
    let dao: SandboxContract<TreasuryContract>;
    let commissionairesDao: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let factory: SandboxContract<EscrowFactory>;

    // Minimum value for CreateEscrow: deploymentFee (0.5) + gas buffer (0.35) + extra headroom
    const CREATE_VALUE = toNano('1.0');

    beforeAll(async () => {
        await compile('EscrowVault');   // vault code needed for factory's initOf
        await compile('EscrowFactory');
    }, 60_000);

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        dao = await blockchain.treasury('dao');
        commissionairesDao = await blockchain.treasury('commissionaires');
        buyer = await blockchain.treasury('buyer');
        seller = await blockchain.treasury('seller');

        factory = blockchain.openContract(
            await EscrowFactory.fromInit(
                dao.address,
                commissionairesDao.address,
            )
        );

        // Deploy factory with a no-op admin message (UpdateArbitratorFee still instant)
        await factory.send(
            dao.getSender(),
            { value: toNano('0.05') },
            { $$type: 'UpdateArbitratorFee', newArbitratorFee: toNano('0.1') },
        );

        // Top up factory balance above operationalReserve (2 TON) so WithdrawFees works.
        // cashback() in admin messages returns the send value, so we fund separately
        // via a plain transfer accepted by receive() {}.
        const topup = await blockchain.treasury('topup');
        await topup.send({ to: factory.address, value: toNano('3'), bounce: false });
    });

    it('should deploy factory correctly', async () => {
        const config = await factory.getFactoryConfig();
        expect(config.owner.equals(dao.address)).toBe(true);
        expect(config.commissionairesDao.equals(commissionairesDao.address)).toBe(true);
        expect(config.deploymentFee).toBe(toNano('0.5'));
        expect(config.guaranteePercent).toBe(2n);
        expect(config.commissionPercent).toBe(1n);
        expect(config.totalVaultsDeployed).toBe(0n);
        expect(config.totalFeesCollected).toBe(0n);
    });

    it('should create an escrow vault', async () => {
        const result = await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('10'),
                tradeId: 0n,  // will be overridden by factory
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        expect(result.transactions).toHaveTransaction({
            from: buyer.address,
            to: factory.address,
            success: true,
        });

        // Factory should have deployed a vault
        const config = await factory.getFactoryConfig();
        expect(config.totalVaultsDeployed).toBe(1n);
        expect(config.totalFeesCollected).toBe(toNano('0.5')); // deploymentFee

        // Check vault was deployed via the computed address
        const vaultAddr = await factory.getVaultAddress(1n); // tradeId starts at 1
        expect(result.transactions).toHaveTransaction({
            from: factory.address,
            to: vaultAddr,
            deploy: true,
            success: true,
        });
    });

    it('should create multiple vaults with unique addresses', async () => {
        // Create first escrow
        await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('10'),
                tradeId: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        // Create second escrow
        await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('20'),
                tradeId: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        const config = await factory.getFactoryConfig();
        expect(config.totalVaultsDeployed).toBe(2n);
        expect(config.totalFeesCollected).toBe(toNano('0.5') * 2n); // deploymentFee * 2

        // Addresses should be different
        const vault1Addr = await factory.getVaultAddress(1n);
        const vault2Addr = await factory.getVaultAddress(2n);
        expect(vault1Addr.equals(vault2Addr)).toBe(false);
    });

    it('should reject escrow creation with insufficient fee', async () => {
        const result = await factory.send(
            buyer.getSender(),
            { value: toNano('0.05') }, // below minimum (0.65)
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('10'),
                tradeId: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        expect(result.transactions).toHaveTransaction({
            from: buyer.address,
            to: factory.address,
            success: false,
        });
    });

    it('should reject same buyer and seller', async () => {
        const result = await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: buyer.address, // same as buyer!
                tradeValue: toNano('10'),
                tradeId: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        expect(result.transactions).toHaveTransaction({
            from: buyer.address,
            to: factory.address,
            success: false,
        });
    });

    it('should reject CreateEscrow with a zero/past deadline (#4)', async () => {
        const result = await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('10'),
                tradeId: 0n,
                deadline: 0n,   // rejected: must be >1h in the future
            }
        );
        expect(result.transactions).toHaveTransaction({
            from: buyer.address, to: factory.address, success: false,
        });
        // No vault should have been deployed
        const config = await factory.getFactoryConfig();
        expect(config.totalVaultsDeployed).toBe(0n);
    });

    it('should allow owner to update deployment fee via time-lock', async () => {
        const newFee = toNano('0.75');

        // Step 1: schedule
        const schedule = await factory.send(
            dao.getSender(),
            { value: toNano('0.05') },
            { $$type: 'ScheduleParamChange', param: 1n, value: newFee }
        );
        expect(schedule.transactions).toHaveTransaction({
            from: dao.address, to: factory.address, success: true,
        });
        // Fee must not change yet
        expect(await factory.getDeploymentFeeAmount()).toBe(toNano('0.5'));

        // Step 2: advance blockchain time past the 24-hour delay
        blockchain.now = (blockchain.now ?? Math.floor(Date.now() / 1000)) + 86401;

        // Step 3: apply
        const apply = await factory.send(
            dao.getSender(),
            { value: toNano('0.05') },
            { $$type: 'ApplyParamChange' }
        );
        expect(apply.transactions).toHaveTransaction({
            from: dao.address, to: factory.address, success: true,
        });
        expect(await factory.getDeploymentFeeAmount()).toBe(newFee);
    });

    it('should reject ScheduleParamChange from non-owner', async () => {
        const result = await factory.send(
            buyer.getSender(),
            { value: toNano('0.05') },
            { $$type: 'ScheduleParamChange', param: 1n, value: toNano('999') }
        );
        expect(result.transactions).toHaveTransaction({
            from: buyer.address, to: factory.address, success: false,
        });
    });

    it('should reject ApplyParamChange before timelock expires', async () => {
        // Schedule a change
        await factory.send(dao.getSender(), { value: toNano('0.05') },
            { $$type: 'ScheduleParamChange', param: 1n, value: toNano('0.75') });

        // Try to apply immediately — must fail
        const result = await factory.send(dao.getSender(), { value: toNano('0.05') },
            { $$type: 'ApplyParamChange' });
        expect(result.transactions).toHaveTransaction({
            from: dao.address, to: factory.address, success: false,
        });
        // Fee unchanged
        expect(await factory.getDeploymentFeeAmount()).toBe(toNano('0.5'));
    });

    it('should allow owner to withdraw collected fees', async () => {
        // Create an escrow to generate fees
        await factory.send(
            buyer.getSender(),
            { value: CREATE_VALUE },
            {
                $$type: 'CreateEscrow',
                buyer: buyer.address,
                seller: seller.address,
                tradeValue: toNano('10'),
                tradeId: 0n,
                deadline: BigInt(Math.floor(Date.now() / 1000) + 86400),
            }
        );

        const configBefore = await factory.getFactoryConfig();
        expect(configBefore.totalFeesCollected).toBe(toNano('0.5')); // deploymentFee

        const result = await factory.send(
            dao.getSender(),
            { value: toNano('0.05') },
            { $$type: 'WithdrawFees' }
        );

        expect(result.transactions).toHaveTransaction({
            from: dao.address,
            to: factory.address,
            success: true,
        });

        // Should send TON back to dao
        expect(result.transactions).toHaveTransaction({
            from: factory.address,
            to: dao.address,
            success: true,
        });

        const configAfter = await factory.getFactoryConfig();
        expect(configAfter.totalFeesCollected).toBe(0n);
    });
});
