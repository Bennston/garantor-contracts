import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell } from '@ton/core';
import { EscrowJettonFactory } from '../build/EscrowJettonFactory/tact_EscrowJettonFactory';
import { EscrowJettonVault } from '../build/EscrowJettonVault/tact_EscrowJettonVault';
import { MockJettonMaster } from '../build/MockJettonMaster/tact_MockJettonMaster';
import { MockJettonWallet } from '../build/MockJettonMaster/tact_MockJettonWallet';
import '@ton/test-utils';

// USDT has 6 decimals.
const USDT = (n: number) => BigInt(Math.round(n * 1_000_000));
const TRADE = USDT(10);          // 10 USDT trade
const GUARANTEE = USDT(0.2);     // 2% seller guarantee
const COMMISSION = USDT(0.1);    // 1% platform commission
const SELLER_PAYOUT = TRADE + GUARANTEE - COMMISSION; // pool minus commission
const DOC_HASH = 0x1234567890abcdefn;

// Empty forward payload carrying the single Either=0 bit (inline, empty).
const EMPTY_FWD = beginCell().storeUint(0, 1).endCell().asSlice();

describe('EscrowJettonVault (V2 / USDT)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;      // jetton master owner / minter
    let dao: SandboxContract<TreasuryContract>;
    let commissionaires: SandboxContract<TreasuryContract>;
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let creator: SandboxContract<TreasuryContract>;
    let stranger: SandboxContract<TreasuryContract>;

    let master: SandboxContract<MockJettonMaster>;
    let factory: SandboxContract<EscrowJettonFactory>;
    let vault: SandboxContract<EscrowJettonVault>;

    let NOW: number;

    const mint = async (to: Address, amount: bigint) => {
        await master.send(deployer.getSender(), { value: toNano('0.1') }, {
            $$type: 'MockMint', to, amount,
        });
    };

    const walletOf = async (owner: Address) =>
        blockchain.openContract(await MockJettonWallet.fromInit(owner, master.address));

    const balanceOf = async (owner: Address): Promise<bigint> => {
        const w = await walletOf(owner);
        const state = await blockchain.getContract(w.address);
        if (state.accountState?.type !== 'active') return 0n;
        return await w.getBalance();
    };

    // Send `amount` jettons from `owner`'s wallet to the vault, with a positive
    // forward TON so the vault's wallet emits a transfer_notification.
    const depositJettons = async (owner: SandboxContract<TreasuryContract>, amount: bigint) => {
        const w = await walletOf(owner.address);
        return await w.send(owner.getSender(), { value: toNano('0.3') }, {
            $$type: 'JettonTransfer',
            queryId: 0n,
            amount,
            destination: vault.address,
            responseDestination: owner.address,
            customPayload: null,
            forwardTonAmount: toNano('0.1'),
            forwardPayload: EMPTY_FWD,
        });
    };

    // Bring the vault to AWAITING_CONFIRMATION (both sides funded).
    const fundBoth = async () => {
        await depositJettons(buyer, TRADE);
        await depositJettons(seller, GUARANTEE);
    };

    const withdraw = async (who: SandboxContract<TreasuryContract>) =>
        vault.send(who.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        NOW = Math.floor(Date.now() / 1000);
        blockchain.now = NOW;

        deployer = await blockchain.treasury('deployer');
        dao = await blockchain.treasury('dao');
        commissionaires = await blockchain.treasury('commissionaires');
        buyer = await blockchain.treasury('buyer');
        seller = await blockchain.treasury('seller');
        creator = await blockchain.treasury('creator');
        stranger = await blockchain.treasury('stranger');

        // Deploy the mock USDT master (first mint also deploys it).
        const content = beginCell().storeUint(0, 8).storeBit(false).endCell(); // minimal TEP-64 on-chain (empty)
        master = blockchain.openContract(await MockJettonMaster.fromInit(deployer.address, content));
        await mint(buyer.address, USDT(100));
        await mint(seller.address, USDT(100));

        // Deploy the factory (no-op admin msg deploys it), then top it up.
        factory = blockchain.openContract(
            await EscrowJettonFactory.fromInit(dao.address, commissionaires.address, master.address),
        );
        // Deploy the factory with a no-op admin message — it has no plain
        // receive(), so a bodyless send would bounce. Re-setting the reserve to
        // its existing default changes nothing.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'UpdateOperationalReserve', newOperationalReserve: toNano('2'),
        });
        const topup = await blockchain.treasury('topup');
        await topup.send({ to: factory.address, value: toNano('3'), bounce: false });

        // Create the escrow (tradeId 1).
        await factory.send(creator.getSender(), { value: toNano('2.1') }, {
            $$type: 'CreateJettonEscrow',
            buyer: buyer.address,
            seller: seller.address,
            jettonMaster: master.address,
            tradeValue: TRADE,
            tradeId: 0n,
            deadline: BigInt(NOW + 30 * 86400),
            nonce: 1n,
        });

        vault = blockchain.openContract(
            await EscrowJettonVault.fromInit(factory.address, 1n),
        );
    });

    it('resolves its own jetton wallet via ProvideWalletAddress on creation', async () => {
        expect(await vault.getWalletResolved()).toBe(true);
        const expected = await master.getGetWalletAddress(vault.address);
        const resolved = await vault.getJettonWallet();
        expect(resolved.equals(expected)).toBe(true);

        const st = await vault.getVaultState();
        expect(st.state).toBe(1n);           // AWAITING_DEPOSITS
        expect(st.buyerDeposited).toBe(false);
        expect(st.sellerDeposited).toBe(false);
        expect(st.tradeValue).toBe(TRADE);
    });

    it('happy path: deposits → doc-hash confirm → withdraw moves USDT correctly', async () => {
        await depositJettons(buyer, TRADE);
        let st = await vault.getVaultState();
        expect(st.buyerDeposited).toBe(true);
        expect(st.sellerDeposited).toBe(false);
        expect(st.state).toBe(1n);

        await depositJettons(seller, GUARANTEE);
        st = await vault.getVaultState();
        expect(st.sellerDeposited).toBe(true);
        expect(st.state).toBe(2n);           // AWAITING_CONFIRMATION

        // The vault's jetton wallet now holds the whole pool.
        expect(await balanceOf(vault.address)).toBe(TRADE + GUARANTEE);

        // Two-phase doc-hash confirmation.
        await vault.send(seller.getSender(), { value: toNano('0.1') }, {
            $$type: 'SellerConfirmDelivery', docHash: DOC_HASH,
        });
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, {
            $$type: 'BuyerConfirmReceipt', docHash: DOC_HASH,
        });

        st = await vault.getVaultState();
        expect(st.state).toBe(3n);           // SUCCESSFUL
        expect(st.sellerClaimable).toBe(SELLER_PAYOUT);
        expect(st.commissionairesClaimable).toBe(COMMISSION);
        expect(st.buyerClaimable).toBe(0n);

        // Seller + commission DAO pull their jettons.
        await vault.send(seller.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });
        await vault.send(commissionaires.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });

        // Seller started 100, deposited 0.2, received payout. Commission DAO got the fee.
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + SELLER_PAYOUT);
        expect(await balanceOf(commissionaires.address)).toBe(COMMISSION);
        expect(await balanceOf(buyer.address)).toBe(USDT(100) - TRADE);
        // Vault's jetton wallet fully drained.
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('refunds the excess on an over-deposit', async () => {
        await depositJettons(buyer, USDT(12));   // required is 10
        const st = await vault.getVaultState();
        expect(st.buyerDeposited).toBe(true);
        // Buyer: 100 - 12 sent + 2 refunded = 90.
        expect(await balanceOf(buyer.address)).toBe(USDT(90));
        // Vault holds exactly the required trade value.
        expect(await balanceOf(vault.address)).toBe(TRADE);
    });

    it('refunds a deposit from a non-party and credits nothing', async () => {
        await mint(stranger.address, USDT(5));
        await depositJettons(stranger, USDT(5));

        const st = await vault.getVaultState();
        expect(st.buyerDeposited).toBe(false);
        expect(st.sellerDeposited).toBe(false);
        expect(st.state).toBe(1n);
        // Stranger's jettons came straight back.
        expect(await balanceOf(stranger.address)).toBe(USDT(5));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('cancels cleanly before any deposit, deferring self-destruct until the grace window elapses', async () => {
        const res = await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'CancelTrade' });
        expect(res.transactions).toHaveTransaction({ from: buyer.address, to: vault.address, success: true });
        expect((await vault.getVaultState()).state).toBe(6n);   // CANCELLED

        // Must NOT destroy yet: a jetton deposit can still be in flight, and a
        // dead vault can never order its jetton wallet to refund it.
        let acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type).toBe('active');

        // Reaping inside the window is a no-op.
        await vault.send(stranger.getSender(), { value: toNano('0.05') }, 'Reap');
        acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type).toBe('active');

        // Once the window passes, anyone may reap it and reclaim the gas.
        blockchain.now = NOW + 3601;
        await vault.send(stranger.getSender(), { value: toNano('0.05') }, 'Reap');
        acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type === 'active').toBe(false);
    });

    // The vault's TON gas budget is paid by whoever sent CreateJettonEscrow —
    // `creator` in this suite, who is deliberately NOT the buyer. The unspent
    // remainder is their prepayment coming back, so it must return to them.
    it('sweeps the residual gas to the creator who funded it, not the buyer', async () => {
        expect(creator.address.equals(buyer.address)).toBe(false);

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'CancelTrade' });
        blockchain.now = NOW + 3601;   // past the destroy grace window

        const creatorBefore = await creator.getBalance();
        const res = await vault.send(stranger.getSender(), { value: toNano('0.05') }, 'Reap');

        expect(res.transactions).toHaveTransaction({
            from: vault.address, to: creator.address, success: true,
        });
        // The buyer must not receive it just for being the buyer.
        expect(res.transactions).not.toHaveTransaction({
            from: vault.address, to: buyer.address,
        });
        expect(await creator.getBalance()).toBeGreaterThan(creatorBefore);

        const acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type === 'active').toBe(false);
    });

    // The factory hard-requires msgValue >= deploymentFee + VaultGasBudget, so
    // the fee is coupled to the frontend's JETTON_CREATE_TON. Raising one without
    // the other silently breaks every create, which no other test would catch.
    it('charges a 1.5 TON deployment fee and rejects an under-funded create', async () => {
        expect((await factory.getFactoryConfig()).deploymentFee).toBe(toNano('1.5'));

        // 1.9 < deploymentFee (1.5) + VaultGasBudget (0.5) → must be rejected.
        const short = await factory.send(creator.getSender(), { value: toNano('1.9') }, {
            $$type: 'CreateJettonEscrow',
            buyer: buyer.address, seller: seller.address,
            jettonMaster: master.address, tradeValue: TRADE,
            tradeId: 0n, deadline: BigInt(NOW + 30 * 86400), nonce: 99n,
        });
        expect(short.transactions).toHaveTransaction({
            from: creator.address, to: factory.address, success: false,
        });

        // JETTON_CREATE_TON (2.1) must clear the floor with headroom to spare.
        expect(toNano('2.1')).toBeGreaterThanOrEqual(toNano('1.5') + toNano('0.5'));
    });

    // Regression: jettonMaster decides which asset the factory escrows, yet it
    // used to be instantly settable by the owner while every lesser numeric param
    // sat behind the 24h timelock. A compromised owner could silently repoint new
    // vaults at a master it controls (design doc §6.7).
    it('gates a jetton-master change behind the timelock', async () => {
        const newMaster = stranger.address;   // stand-in for another master
        const cfg = async () => (await factory.getFactoryConfig()).jettonMaster;

        // Non-owner cannot even schedule.
        const bad = await factory.send(stranger.getSender(), { value: toNano('0.05') }, {
            $$type: 'ScheduleJettonMaster', newJettonMaster: newMaster,
        });
        expect(bad.transactions).toHaveTransaction({ from: stranger.address, to: factory.address, success: false });

        // Owner schedules — the active master must NOT move yet.
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'ScheduleJettonMaster', newJettonMaster: newMaster,
        });
        expect((await cfg()).equals(master.address)).toBe(true);

        // Applying before the delay elapses is rejected.
        const early = await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ApplyJettonMaster' });
        expect(early.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
        expect((await cfg()).equals(master.address)).toBe(true);

        // Only after the 24h window does it take effect.
        blockchain.now = NOW + 86400 + 1;
        await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ApplyJettonMaster' });
        expect((await cfg()).equals(newMaster)).toBe(true);
    });

    it('lets the owner cancel a scheduled jetton-master change', async () => {
        await factory.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'ScheduleJettonMaster', newJettonMaster: stranger.address,
        });
        await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'CancelJettonMaster' });

        // Even past the window, a cancelled change must never land.
        blockchain.now = NOW + 86400 + 1;
        const res = await factory.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ApplyJettonMaster' });
        expect(res.transactions).toHaveTransaction({ from: dao.address, to: factory.address, success: false });
        expect((await factory.getFactoryConfig()).jettonMaster.equals(master.address)).toBe(true);
    });

    // Regression: the vault used to self-destruct the instant a no-deposit cancel
    // landed. A deposit already in flight would then arrive at the vault's jetton
    // wallet with no owner left to move it — stranded permanently. (V1 is immune:
    // its TON deposits simply bounce off a dead vault.)
    it('refunds a deposit that lands after cancellation instead of stranding it', async () => {
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'CancelTrade' });
        expect((await vault.getVaultState()).state).toBe(6n);

        // The in-flight deposit finally arrives.
        await depositJettons(buyer, TRADE);

        // Refunded in full: not credited, not trapped in the vault's wallet.
        expect((await vault.getVaultState()).buyerDeposited).toBe(false);
        expect(await balanceOf(buyer.address)).toBe(USDT(100));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('DAO dispute resolution splits the pooled USDT', async () => {
        await fundBoth();
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'RaiseDispute' });
        expect((await vault.getVaultState()).state).toBe(4n);   // DISPUTED

        // pool = 10.2 USDT → 6 / 4 / 0.2 fee (≤ 10% of pool).
        await vault.send(dao.getSender(), { value: toNano('0.1') }, {
            $$type: 'ResolveDispute',
            buyerShare: USDT(6),
            sellerShare: USDT(4),
            daoFee: USDT(0.2),
        });
        expect((await vault.getVaultState()).state).toBe(5n);   // RESOLVED

        await withdraw(buyer);
        await withdraw(seller);
        await withdraw(commissionaires);

        expect(await balanceOf(buyer.address)).toBe(USDT(100) - TRADE + USDT(6));
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + USDT(4));
        expect(await balanceOf(commissionaires.address)).toBe(USDT(0.2));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('mutual settlement splits the pool with no DAO fee', async () => {
        await fundBoth();
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'RaiseDispute' });

        // Buyer proposes 30%, seller approves by echoing the same value.
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'ProposeSettlement', buyerPct: 30n });
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'ProposeSettlement', buyerPct: 30n });
        expect((await vault.getVaultState()).state).toBe(5n);   // RESOLVED

        await withdraw(buyer);
        await withdraw(seller);

        // pool 10.2 → buyer 30% = 3.06, seller 7.14.
        expect(await balanceOf(buyer.address)).toBe(USDT(100) - TRADE + USDT(3.06));
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + USDT(7.14));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('expiry → cancel returns both deposits in full', async () => {
        await fundBoth();
        blockchain.now = NOW + 31 * 86400;                      // past the 30-day deadline

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, 'CheckExpiry');
        expect((await vault.getVaultState()).state).toBe(7n);   // EXPIRED

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'CancelTrade' });
        await withdraw(buyer);
        await withdraw(seller);

        expect(await balanceOf(buyer.address)).toBe(USDT(100));   // got the 10 back
        expect(await balanceOf(seller.address)).toBe(USDT(100));  // got the 0.2 back
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('dispute-timeout backstop forces a 50/50 split', async () => {
        await fundBoth();
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'RaiseDispute' });
        blockchain.now = NOW + 31 * 86400;                      // past the 30-day dispute window

        await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'CheckDisputeTimeout');
        expect((await vault.getVaultState()).state).toBe(5n);   // RESOLVED

        await withdraw(buyer);
        await withdraw(seller);

        // pool 10.2 split 50/50 = 5.1 each.
        expect(await balanceOf(buyer.address)).toBe(USDT(100) - TRADE + USDT(5.1));
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + USDT(5.1));
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('accepts a hand-built CreateJettonEscrow payload (frontend cell layout)', async () => {
        // Replicates buildCreateJettonEscrowPayload EXACTLY (deadline + nonce in a ref).
        // If the layout were wrong (deadline inline) the factory would bounce and
        // totalVaults would stay at 1 (the beforeEach create).
        const before = (await factory.getFactoryConfig()).totalVaultsDeployed;
        const body = beginCell()
            .storeUint(0x2002, 32)
            .storeAddress(buyer.address)
            .storeAddress(seller.address)
            .storeAddress(master.address)
            .storeCoins(TRADE)
            .storeUint(0n, 64)
            .storeRef(beginCell()
                .storeUint(NOW + 30 * 86400, 32)
                .storeUint(2n, 256)   // distinct nonce — beforeEach used nonce 1 from this creator
                .endCell())
            .endCell();

        await creator.send({ to: factory.address, value: toNano('2.1'), body, bounce: true });

        const after = (await factory.getFactoryConfig()).totalVaultsDeployed;
        expect(after).toBe(before + 1n); // vault deployed + acked → payload parsed correctly
    });

    it('rejects a duplicate create (same nonce from same wallet) and deploys no 2nd vault', async () => {
        // First create with a fresh nonce succeeds (vault #2 after the beforeEach).
        await factory.send(creator.getSender(), { value: toNano('2.1') }, {
            $$type: 'CreateJettonEscrow',
            buyer: buyer.address,
            seller: seller.address,
            jettonMaster: master.address,
            tradeValue: TRADE,
            tradeId: 0n,
            deadline: BigInt(NOW + 30 * 86400),
            nonce: 77n,
        });
        const afterFirst = (await factory.getFactoryConfig()).totalVaultsDeployed;

        // Re-submitting the SAME form (same nonce, same creator) must bounce — a
        // double-click / wallet rebroadcast must not spawn a second vault.
        const dup = await factory.send(creator.getSender(), { value: toNano('2.1') }, {
            $$type: 'CreateJettonEscrow',
            buyer: buyer.address,
            seller: seller.address,
            jettonMaster: master.address,
            tradeValue: TRADE,
            tradeId: 0n,
            deadline: BigInt(NOW + 30 * 86400),
            nonce: 77n,
        });
        expect(dup.transactions).toHaveTransaction({
            from: creator.address,
            to: factory.address,
            success: false,            // require(!seenTradeNonce) throws → bounces
        });

        const afterDup = (await factory.getFactoryConfig()).totalVaultsDeployed;
        expect(afterDup).toBe(afterFirst); // no second vault from the duplicate
    });

    it('allows a new create with a different nonce (genuinely new trade)', async () => {
        const before = (await factory.getFactoryConfig()).totalVaultsDeployed;
        await factory.send(creator.getSender(), { value: toNano('2.1') }, {
            $$type: 'CreateJettonEscrow',
            buyer: buyer.address,
            seller: seller.address,
            jettonMaster: master.address,
            tradeValue: TRADE,
            tradeId: 0n,
            deadline: BigInt(NOW + 30 * 86400),
            nonce: 88n,
        });
        const after = (await factory.getFactoryConfig()).totalVaultsDeployed;
        expect(after).toBe(before + 1n);
    });

    it('rejects a spoofed deposit notification not from the vault jetton wallet', async () => {
        // stranger forges a notification claiming buyer deposited — must be rejected.
        const res = await vault.send(stranger.getSender(), { value: toNano('0.1') }, {
            $$type: 'JettonTransferNotification',
            queryId: 0n,
            amount: USDT(1000),
            sender: buyer.address,
            forwardPayload: EMPTY_FWD,
        });
        expect(res.transactions).toHaveTransaction({
            from: stranger.address,
            to: vault.address,
            success: false,            // require(sender == myJettonWallet) fails
        });
        const st = await vault.getVaultState();
        expect(st.buyerDeposited).toBe(false);
        expect(st.sellerDeposited).toBe(false);
    });
});
