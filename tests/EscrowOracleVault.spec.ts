import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, Address, beginCell, Cell } from '@ton/core';
import { keyPairFromSeed, sign, KeyPair } from '@ton/crypto';
import { EscrowOracleVault } from '../build/EscrowOracleVault/tact_EscrowOracleVault';
import { OracleRegistry } from '../build/OracleRegistry/tact_OracleRegistry';
import { MockJettonMaster } from '../build/MockJettonMaster/tact_MockJettonMaster';
import { MockJettonWallet } from '../build/MockJettonMaster/tact_MockJettonWallet';
import '@ton/test-utils';

// USDT has 6 decimals.
const USDT = (n: number) => BigInt(Math.round(n * 1_000_000));
const TRADE = USDT(10);
const GUARANTEE = USDT(0.2);          // 2% seller guarantee
const COMMISSION = USDT(0.1);         // 1% platform commission
const SELLER_PAYOUT = TRADE + GUARANTEE - COMMISSION;
const POOL = TRADE + GUARANTEE;

const VTYPE = 1;                       // this vault's expected validation type (e.g. "API check")
const OBJECTION_WINDOW = 172800;       // 48h, the DefaultObjectionWindow const
const DISPUTE_TIMEOUT_WINDOW = 2592000; // 30d, the DefaultDisputeTimeoutWindow const
const DESTROY_GRACE_WINDOW = 3600;     // 1h, the DefaultDestroyGraceWindow const

// V3.1: InitVault now carries three timing windows. `0n` => the Default* const.
const DEFAULT_WINDOWS = { objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n };

const DELIVERED = 0;
const FAILED = 1;
const PARTIAL = 2;

const EMPTY_FWD = beginCell().storeUint(0, 1).endCell().asSlice();

const bufToBigInt = (b: Buffer) => BigInt('0x' + b.toString('hex'));

describe('EscrowOracleVault (V3 / DON-signed oracle settlement)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;   // jetton minter
    let dao: SandboxContract<TreasuryContract>;         // registry owner + vault owner
    let commissionaires: SandboxContract<TreasuryContract>;
    let factory: SandboxContract<TreasuryContract>;     // stands in for the listing/factory
    let buyer: SandboxContract<TreasuryContract>;
    let seller: SandboxContract<TreasuryContract>;
    let relayer: SandboxContract<TreasuryContract>;     // untrusted — anyone may relay a signed report
    let stranger: SandboxContract<TreasuryContract>;

    let master: SandboxContract<MockJettonMaster>;
    let registry: SandboxContract<OracleRegistry>;
    let vault: SandboxContract<EscrowOracleVault>;

    let donKey: KeyPair;      // trusted DON attestation bridge key
    let wrongKey: KeyPair;    // an untrusted key
    let NOW: number;

    // Canonical report preimage — MUST match OracleRegistry.SubmitReport byte-for-byte.
    const reportHash = (vaultAddr: Address, tradeId: bigint, vt: number, status: number, proof: Cell | null): Buffer => {
        const proofHash = proof ? bufToBigInt(proof.hash()) : 0n;
        return beginCell()
            .storeAddress(vaultAddr)
            .storeUint(tradeId, 64)
            .storeUint(vt, 8)
            .storeUint(status, 8)
            .storeUint(proofHash, 256)
            .endCell()
            .hash();
    };

    const signWith = (kp: KeyPair, vaultAddr: Address, tradeId: bigint, vt: number, status: number, proof: Cell | null): Cell =>
        beginCell().storeBuffer(sign(reportHash(vaultAddr, tradeId, vt, status, proof), kp.secretKey)).endCell();

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

    const depositJettons = async (owner: SandboxContract<TreasuryContract>, amount: bigint, target: Address = vault.address) => {
        const w = await walletOf(owner.address);
        return w.send(owner.getSender(), { value: toNano('0.3') }, {
            $$type: 'JettonTransfer',
            queryId: 0n,
            amount,
            destination: target,
            responseDestination: owner.address,
            customPayload: null,
            forwardTonAmount: toNano('0.1'),
            forwardPayload: EMPTY_FWD,
        });
    };

    const fundBoth = async (target: Address = vault.address) => {
        await depositJettons(buyer, TRADE, target);
        await depositJettons(seller, GUARANTEE, target);
    };

    // Deploy + init a second vault pinned to a given settlement mode (0 oracle, 1 manual).
    const initVaultWithMode = async (seqno: bigint, mode: number) => {
        const v = blockchain.openContract(await EscrowOracleVault.fromInit(factory.address, dao.address, seqno));
        await v.send(factory.getSender(), { value: toNano('0.7') }, {
            $$type: 'InitVault',
            buyer: buyer.address, seller: seller.address, jettonMaster: master.address,
            tradeValue: TRADE, guaranteePercent: 2n, commissionPercent: 1n,
            commissionairesDao: commissionaires.address, tradeId: seqno,
            deadline: BigInt(NOW + 30 * 86400),
            oracleRegistry: registry.address, validationType: BigInt(VTYPE),
            agreementCID: null, settlementMode: BigInt(mode),
            ...DEFAULT_WINDOWS,
        });
        return v;
    };

    // Relay a DON-signed report through the registry. `signature` defaults to a
    // valid DON signature over the same report; override to forge/tamper.
    const submitReport = async (
        who: SandboxContract<TreasuryContract>,
        status: number,
        validationType: number = VTYPE,
        signature?: Cell,
        proof: Cell | null = null,
        target: Address = vault.address,
        tradeId: bigint = 1n,
    ) =>
        registry.send(who.getSender(), { value: toNano('0.3') }, {
            $$type: 'SubmitReport',
            vault: target,
            tradeId,
            validationType: BigInt(validationType),
            status: BigInt(status),
            proof,
            signature: signature ?? signWith(donKey, target, tradeId, validationType, status, proof),
        });

    const withdraw = async (who: SandboxContract<TreasuryContract>) =>
        vault.send(who.getSender(), { value: toNano('0.15') }, { $$type: 'Withdraw' });

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        NOW = Math.floor(Date.now() / 1000);
        blockchain.now = NOW;

        donKey = keyPairFromSeed(Buffer.alloc(32, 7));
        wrongKey = keyPairFromSeed(Buffer.alloc(32, 9));

        deployer = await blockchain.treasury('deployer');
        dao = await blockchain.treasury('dao');
        commissionaires = await blockchain.treasury('commissionaires');
        factory = await blockchain.treasury('factory');
        buyer = await blockchain.treasury('buyer');
        seller = await blockchain.treasury('seller');
        relayer = await blockchain.treasury('relayer');
        stranger = await blockchain.treasury('stranger');

        const content = beginCell().storeUint(0, 8).storeBit(false).endCell();
        master = blockchain.openContract(await MockJettonMaster.fromInit(deployer.address, content));
        await mint(buyer.address, USDT(100));
        await mint(seller.address, USDT(100));

        // Registry holds the trusted DON attestation key; owner = dao.
        registry = blockchain.openContract(await OracleRegistry.fromInit(dao.address, bufToBigInt(donKey.publicKey)));
        await registry.send(dao.getSender(), { value: toNano('0.1') }, null);   // deploy (key set at init)

        // Deploy + initialize the vault (test plays the listing/factory).
        vault = blockchain.openContract(await EscrowOracleVault.fromInit(factory.address, dao.address, 1n));
        await vault.send(factory.getSender(), { value: toNano('0.7') }, {
            $$type: 'InitVault',
            buyer: buyer.address,
            seller: seller.address,
            jettonMaster: master.address,
            tradeValue: TRADE,
            guaranteePercent: 2n,
            commissionPercent: 1n,
            commissionairesDao: commissionaires.address,
            tradeId: 1n,
            deadline: BigInt(NOW + 30 * 86400),
            oracleRegistry: registry.address,
            validationType: BigInt(VTYPE),
            agreementCID: null,
            settlementMode: 0n,   // oracle-only
            ...DEFAULT_WINDOWS,
        });
    });

    it('initializes, resolves its jetton wallet, and records the oracle config', async () => {
        expect(await vault.getWalletResolved()).toBe(true);
        expect(await vault.getValidationType()).toBe(BigInt(VTYPE));
        expect(await vault.getSettlementMode()).toBe(0n);   // oracle-only
        expect((await vault.getOracleRegistryAddr()).equals(registry.address)).toBe(true);
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect((await vault.getVaultState()).state).toBe(1n);   // AWAITING_DEPOSITS
        expect(await registry.getDonPublicKey()).toBe(bufToBigInt(donKey.publicKey));
    });

    it('rejects an OracleReport that does not come from the registry', async () => {
        await fundBoth();
        const res = await vault.send(stranger.getSender(), { value: toNano('0.1') }, {
            $$type: 'OracleReport',
            tradeId: 1n,
            validationType: BigInt(VTYPE),
            status: BigInt(DELIVERED),
            proof: null,
        });
        expect(res.transactions).toHaveTransaction({
            from: stranger.address, to: vault.address, success: false,   // sender() != oracleRegistry
        });
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect((await vault.getVaultState()).state).toBe(2n);
    });

    it('registry rejects a report signed by the wrong key', async () => {
        await fundBoth();
        const forged = signWith(wrongKey, vault.address, 1n, VTYPE, DELIVERED, null);
        const res = await submitReport(relayer, DELIVERED, VTYPE, forged);
        expect(res.transactions).toHaveTransaction({
            from: relayer.address, to: registry.address, success: false,   // Invalid DON signature
        });
        expect(await vault.getObjectionDeadline()).toBe(0n);
    });

    it('registry rejects a report whose status was tampered after signing', async () => {
        await fundBoth();
        // Legit signature for DELIVERED, but the submitted status is FAILED → hash mismatch.
        const deliveredSig = signWith(donKey, vault.address, 1n, VTYPE, DELIVERED, null);
        const res = await submitReport(relayer, FAILED, VTYPE, deliveredSig);
        expect(res.transactions).toHaveTransaction({
            from: relayer.address, to: registry.address, success: false,
        });
        expect((await vault.getVaultState()).state).toBe(2n);   // unchanged
    });

    it('registry rejects SubmitReport with less than ReportGas attached', async () => {
        await fundBoth();
        const res = await registry.send(relayer.getSender(), { value: toNano('0.05') }, {
            $$type: 'SubmitReport',
            vault: vault.address,
            tradeId: 1n,
            validationType: BigInt(VTYPE),
            status: BigInt(DELIVERED),
            proof: null,
            signature: signWith(donKey, vault.address, 1n, VTYPE, DELIVERED, null),
        });
        expect(res.transactions).toHaveTransaction({
            from: relayer.address, to: registry.address, success: false,   // Attach at least ReportGas
        });
        expect(await vault.getObjectionDeadline()).toBe(0n);   // never reached the vault
        expect(
            await registry.getIsReportProcessed(bufToBigInt(reportHash(vault.address, 1n, VTYPE, DELIVERED, null))),
        ).toBe(false);
    });

    it('registry rejects a replayed report — the exact same signed message cannot be resubmitted', async () => {
        await fundBoth();
        const hash = bufToBigInt(reportHash(vault.address, 1n, VTYPE, DELIVERED, null));
        expect(await registry.getIsReportProcessed(hash)).toBe(false);

        const first = await submitReport(relayer, DELIVERED);
        expect(first.transactions).toHaveTransaction({ from: registry.address, to: vault.address, success: true });
        expect(await vault.getObjectionDeadline()).toBeGreaterThan(0n);
        expect(await registry.getIsReportProcessed(hash)).toBe(true);

        // Anyone (not just the original relayer) resubmitting the identical
        // {report, signature} must be rejected at the registry, before it ever
        // reaches the vault again.
        const replay = await submitReport(stranger, DELIVERED);
        expect(replay.transactions).toHaveTransaction({
            from: stranger.address, to: registry.address, success: false,   // Report already processed
        });
        expect(replay.transactions).not.toHaveTransaction({ from: registry.address, to: vault.address });
    });

    it('vault rejects a validly-signed report whose type does not match its own', async () => {
        await fundBoth();
        // Signature is valid for type 2, but this vault expects VTYPE (1): registry
        // forwards, the vault rejects on the type check.
        const res = await submitReport(relayer, DELIVERED, 2);
        expect(res.transactions).toHaveTransaction({
            from: registry.address, to: vault.address, success: false,   // Validation type mismatch
        });
        expect(await vault.getObjectionDeadline()).toBe(0n);
    });

    it('[V3-M4] a vault-side rejection bounces back and un-marks the report — not burned forever', async () => {
        await fundBoth();
        // Same rejection as above (type mismatch): the registry forwards, the
        // vault throws, and — pre-fix — that exact {report, signature} could
        // never be relayed again ("Report already processed" at the registry,
        // permanently, even though the vault itself never accepted it).
        const first = await submitReport(relayer, DELIVERED, 2);
        expect(first.transactions).toHaveTransaction({
            from: registry.address, to: vault.address, success: false,
        });
        // The rejection must actually bounce back to the registry (not just
        // fail silently) — that's what lets bounced() run and clear
        // processedReports.
        expect(first.transactions).toHaveTransaction({
            from: vault.address, to: registry.address, success: true,
        });

        // Resubmitting the IDENTICAL {report, signature} must reach the vault
        // again — not be rejected at the registry with "Report already
        // processed". It fails for the same reason as before (registry-level
        // burn is what's under test here, not the vault's own type check).
        const second = await submitReport(relayer, DELIVERED, 2);
        expect(second.transactions).toHaveTransaction({
            from: relayer.address, to: registry.address, success: true, // passes the replay guard
        });
        expect(second.transactions).toHaveTransaction({
            from: registry.address, to: vault.address, success: false, // rejected by the vault itself, same as before
        });
        expect(await vault.getObjectionDeadline()).toBe(0n);
    });

    it('any relayer can push a valid DON-signed Delivered report; it opens the window without paying out', async () => {
        await fundBoth();
        expect((await vault.getVaultState()).state).toBe(2n);

        await submitReport(relayer, DELIVERED);   // relayer is NOT whitelisted — signature is the trust anchor

        const st = await vault.getVaultState();
        expect(st.state).toBe(2n);                 // still awaiting — no payout yet
        expect(st.sellerClaimable).toBe(0n);
        expect(st.commissionairesClaimable).toBe(0n);
        expect(await vault.getObjectionDeadline()).toBe(BigInt(NOW + OBJECTION_WINDOW));
        expect(await balanceOf(vault.address)).toBe(POOL);
    });

    it('FinalizeDelivery is blocked during the window and settles after it', async () => {
        await fundBoth();
        await submitReport(relayer, DELIVERED);

        const early = await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect(early.transactions).toHaveTransaction({ from: stranger.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).state).toBe(2n);

        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');

        const st = await vault.getVaultState();
        expect(st.state).toBe(3n);                 // SUCCESSFUL
        expect(st.sellerClaimable).toBe(SELLER_PAYOUT);
        expect(st.commissionairesClaimable).toBe(COMMISSION);
        expect(st.buyerClaimable).toBe(0n);
        // Finalize clears the now-stale report fields instead of leaving them set forever.
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect(await vault.getReportedStatus()).toBe(0n);

        await withdraw(seller);
        await withdraw(commissionaires);
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + SELLER_PAYOUT);
        expect(await balanceOf(commissionaires.address)).toBe(COMMISSION);
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('a buyer objection during the window pre-empts finalization', async () => {
        await fundBoth();
        await submitReport(relayer, DELIVERED);
        expect(await vault.getObjectionDeadline()).toBeGreaterThan(0n);

        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'RaiseDispute' });
        expect((await vault.getVaultState()).state).toBe(4n);   // DISPUTED
        // RaiseDispute clears the pending oracle report so getters stay accurate
        // through StateDisputed/StateResolved, even though FinalizeDelivery/
        // OracleReport are already independently blocked by the state check below.
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect(await vault.getReportedStatus()).toBe(0n);

        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        const res = await vault.send(stranger.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect(res.transactions).toHaveTransaction({ from: stranger.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).state).toBe(4n);
    });

    it('a Failed report opens a window; after it, finalize slashes the bond to the buyer', async () => {
        await fundBoth();
        await submitReport(relayer, FAILED);

        // Not instant — a 48h window opens (either party may still object).
        let st = await vault.getVaultState();
        expect(st.state).toBe(2n);                 // still AWAITING_CONFIRMATION
        expect(await vault.getObjectionDeadline()).toBe(BigInt(NOW + OBJECTION_WINDOW));
        expect(await vault.getReportedStatus()).toBe(BigInt(FAILED));

        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');

        st = await vault.getVaultState();
        expect(st.state).toBe(6n);                 // CANCELLED
        expect(st.buyerClaimable).toBe(POOL);      // trade value + slashed bond
        expect(st.sellerClaimable).toBe(0n);
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect(await vault.getReportedStatus()).toBe(0n);

        await withdraw(buyer);
        expect(await balanceOf(buyer.address)).toBe(USDT(100) + GUARANTEE);   // recovered trade + bond
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE);  // lost the bond
        expect(await balanceOf(vault.address)).toBe(0n);
    });

    it('the SELLER can object a Failed report within the window (→ dispute, no slash)', async () => {
        await fundBoth();
        await submitReport(relayer, FAILED);

        // Seller contests the wrong Failed → DISPUTED, pre-empting the slash.
        await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'RaiseDispute' });
        expect((await vault.getVaultState()).state).toBe(4n);   // DISPUTED

        blockchain.now = NOW + OBJECTION_WINDOW + 1;
        const res = await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect(res.transactions).toHaveTransaction({ from: relayer.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).state).toBe(4n);   // still disputed — DAO/mutual/timeout decides
    });

    it('oracle-only vault: manual doc-hash confirm is rejected', async () => {
        await fundBoth();
        const res = await vault.send(seller.getSender(), { value: toNano('0.1') }, {
            $$type: 'SellerConfirmDelivery', docHash: 0x99n,
        });
        expect(res.transactions).toHaveTransaction({ from: seller.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).sellerConfirmed).toBe(false);
    });

    it('manual-only vault: oracle report rejected, doc-hash path settles', async () => {
        const mv = await initVaultWithMode(2n, 1);   // settlementMode = manual
        expect(await mv.getSettlementMode()).toBe(1n);
        await fundBoth(mv.address);

        // A validly-signed report is forwarded by the registry but the vault refuses it.
        const res = await submitReport(relayer, DELIVERED, VTYPE, undefined, null, mv.address, 2n);
        expect(res.transactions).toHaveTransaction({ from: registry.address, to: mv.address, success: false });
        expect(await mv.getObjectionDeadline()).toBe(0n);

        // Two-phase doc-hash confirm works and settles.
        await mv.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'SellerConfirmDelivery', docHash: 0x42n });
        await mv.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerConfirmReceipt', docHash: 0x42n });
        expect((await mv.getVaultState()).state).toBe(3n);   // SUCCESSFUL
    });

    it('DON-key rotation is time-locked (schedule → wait → apply)', async () => {
        const newKp = keyPairFromSeed(Buffer.alloc(32, 3));
        const newPub = bufToBigInt(newKp.publicKey);

        await registry.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ScheduleDonKey', newKey: newPub });
        expect(await registry.getDonPublicKey()).toBe(bufToBigInt(donKey.publicKey));   // unchanged yet

        const early = await registry.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ApplyDonKey' });
        expect(early.transactions).toHaveTransaction({ from: dao.address, to: registry.address, success: false });
        expect(await registry.getDonPublicKey()).toBe(bufToBigInt(donKey.publicKey));

        blockchain.now = NOW + 86400 + 1;   // past the 24h timelock
        await registry.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'ApplyDonKey' });
        expect(await registry.getDonPublicKey()).toBe(newPub);

        // Old key now rejected; new key accepted.
        await fundBoth();
        const oldSig = signWith(donKey, vault.address, 1n, VTYPE, DELIVERED, null);
        const rejected = await submitReport(relayer, DELIVERED, VTYPE, oldSig);
        expect(rejected.transactions).toHaveTransaction({ from: relayer.address, to: registry.address, success: false });

        await submitReport(relayer, DELIVERED, VTYPE, signWith(newKp, vault.address, 1n, VTYPE, DELIVERED, null));
        expect(await vault.getObjectionDeadline()).toBe(BigInt(NOW + 86400 + 1 + OBJECTION_WINDOW));
    });

    it('CancelDonKey clears the pending key, not just the timelock', async () => {
        const badKp = keyPairFromSeed(Buffer.alloc(32, 5));
        await registry.send(dao.getSender(), { value: toNano('0.05') }, {
            $$type: 'ScheduleDonKey', newKey: bufToBigInt(badKp.publicKey),
        });
        expect(await registry.getPendingDonKey()).toBe(bufToBigInt(badKp.publicKey));

        await registry.send(dao.getSender(), { value: toNano('0.05') }, { $$type: 'CancelDonKey' });
        expect(await registry.getPendingEffectiveAt()).toBe(0n);
        expect(await registry.getPendingDonKey()).toBe(0n);
    });

    it('a Partial report routes to the dispute machinery', async () => {
        await fundBoth();
        await submitReport(relayer, PARTIAL);
        expect((await vault.getVaultState()).state).toBe(4n);   // DISPUTED
        expect(await vault.getDisputeDeadline()).toBe(BigInt(NOW + 2592000));
    });

    it('the buyer can confirm receipt and release funds early, waiving the window', async () => {
        await fundBoth();
        await submitReport(relayer, DELIVERED);   // 48h window open…
        // …but the happy buyer releases immediately.
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerAcceptDelivery' });

        const st = await vault.getVaultState();
        expect(st.state).toBe(3n);                 // SUCCESSFUL now, no wait
        expect(st.sellerClaimable).toBe(SELLER_PAYOUT);
        expect(st.commissionairesClaimable).toBe(COMMISSION);
        // BuyerAcceptDelivery clears the pending report too, so a completed
        // trade doesn't keep reporting a stale open objection window.
        expect(await vault.getObjectionDeadline()).toBe(0n);
        expect(await vault.getReportedStatus()).toBe(0n);

        await withdraw(seller);
        await withdraw(commissionaires);
        expect(await balanceOf(seller.address)).toBe(USDT(100) - GUARANTEE + SELLER_PAYOUT);
        expect(await balanceOf(commissionaires.address)).toBe(COMMISSION);
    });

    it('the buyer can release even before any oracle report', async () => {
        await fundBoth();
        await vault.send(buyer.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerAcceptDelivery' });
        expect((await vault.getVaultState()).state).toBe(3n);   // SUCCESSFUL
    });

    it('only the buyer can release funds (seller is rejected)', async () => {
        await fundBoth();
        const res = await vault.send(seller.getSender(), { value: toNano('0.1') }, { $$type: 'BuyerAcceptDelivery' });
        expect(res.transactions).toHaveTransaction({ from: seller.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).state).toBe(2n);   // unchanged
    });

    // ── Regression tests for the pre-mainnet audit fixes ──────────────────────

    it('H2: CheckExpiry cannot void a pending Delivered report (buyer cannot grief-expire a delivered trade)', async () => {
        await fundBoth();
        const deadline = NOW + 30 * 86400;
        // Report lands 1h before the deadline, so its 48h objection window extends past it.
        blockchain.now = deadline - 3600;
        await submitReport(relayer, DELIVERED);
        expect(await vault.getObjectionDeadline()).toBeGreaterThan(0n);
        // Deadline passes while the window is still open — the exact exploit window.
        blockchain.now = deadline + 60;
        const res = await vault.send(buyer.getSender(), { value: toNano('0.1') }, 'CheckExpiry');
        expect(res.transactions).toHaveTransaction({ from: buyer.address, to: vault.address, success: false });
        expect((await vault.getVaultState()).state).toBe(2n);   // still AwaitingConfirmation, NOT Expired
        // After the window the delivered outcome finalizes to the seller, as intended.
        blockchain.now = Number(await vault.getObjectionDeadline()) + 1;
        await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect((await vault.getVaultState()).state).toBe(3n);   // Successful
    });

    it('H3: InitVault rejects a trade party equal to the commissionaires DAO', async () => {
        const v = blockchain.openContract(await EscrowOracleVault.fromInit(factory.address, dao.address, 42n));
        const res = await v.send(factory.getSender(), { value: toNano('0.7') }, {
            $$type: 'InitVault',
            buyer: buyer.address, seller: seller.address, jettonMaster: master.address,
            tradeValue: TRADE, guaranteePercent: 2n, commissionPercent: 1n,
            commissionairesDao: buyer.address,   // collision: buyer == commissionaires
            tradeId: 42n, deadline: BigInt(NOW + 30 * 86400),
            oracleRegistry: registry.address, validationType: BigInt(VTYPE),
            agreementCID: null, settlementMode: 0n,
            ...DEFAULT_WINDOWS,
        });
        expect(res.transactions).toHaveTransaction({ from: factory.address, to: v.address, success: false });
        expect((await v.getVaultState()).state).toBe(0n);   // still Created — never initialized
    });

    it('M3: a validationType-0 vault accepts a report of any validation type (documented wildcard)', async () => {
        const v = blockchain.openContract(await EscrowOracleVault.fromInit(factory.address, dao.address, 7n));
        await v.send(factory.getSender(), { value: toNano('0.7') }, {
            $$type: 'InitVault',
            buyer: buyer.address, seller: seller.address, jettonMaster: master.address,
            tradeValue: TRADE, guaranteePercent: 2n, commissionPercent: 1n,
            commissionairesDao: commissionaires.address, tradeId: 7n,
            deadline: BigInt(NOW + 30 * 86400),
            oracleRegistry: registry.address, validationType: 0n,   // 0 = accept any
            agreementCID: null, settlementMode: 0n,
            ...DEFAULT_WINDOWS,
        });
        await fundBoth(v.address);
        expect((await v.getVaultState()).state).toBe(2n);
        // A report carrying a DIFFERENT validation type (5) is still accepted.
        await submitReport(relayer, DELIVERED, 5, undefined, null, v.address, 7n);
        expect(await v.getObjectionDeadline()).toBeGreaterThan(0n);
    });

    it('H1: the vault defers self-destruct through the grace window after the final withdrawal, then Reap cleans up', async () => {
        await fundBoth();
        blockchain.now = NOW + 1000;
        await submitReport(relayer, DELIVERED);
        blockchain.now = Number(await vault.getObjectionDeadline()) + 1;
        await vault.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
        expect((await vault.getVaultState()).state).toBe(3n);   // Successful — terminalAt stamped now

        // Drain every claimable (delivered → seller + commission; buyer has none).
        await withdraw(seller);
        await withdraw(commissionaires);

        // Within the grace window the vault must NOT have self-destructed: a bounced
        // payout could still return and need its claimable restored by bounced().
        let acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type).toBe('active');

        // After the grace window, anyone may Reap to reclaim leftover gas + destroy.
        blockchain.now = blockchain.now + 3601;
        await vault.send(relayer.getSender(), { value: toNano('0.05') }, 'Reap');
        acct = await blockchain.getContract(vault.address);
        expect(acct.accountState?.type).not.toBe('active');
    });

    // ── V3.1: dispute-timing windows are now seeded per vault via InitVault ────
    describe('V3.1 seeded timing windows', () => {
        // Deploy + init a fresh vault with explicit windows (0n => Default* const).
        const initWith = async (
            seqno: bigint,
            windows: { objectionWindow: bigint; disputeTimeoutWindow: bigint; destroyGraceWindow: bigint },
        ) => {
            const v = blockchain.openContract(await EscrowOracleVault.fromInit(factory.address, dao.address, seqno));
            const res = await v.send(factory.getSender(), { value: toNano('0.7') }, {
                $$type: 'InitVault',
                buyer: buyer.address, seller: seller.address, jettonMaster: master.address,
                tradeValue: TRADE, guaranteePercent: 2n, commissionPercent: 1n,
                commissionairesDao: commissionaires.address, tradeId: seqno,
                deadline: BigInt(NOW + 30 * 86400),
                oracleRegistry: registry.address, validationType: BigInt(VTYPE),
                agreementCID: null, settlementMode: 0n,
                ...windows,
            });
            return { v, res };
        };

        it('38: InitVault stores explicit windows and clamps an out-of-range one', async () => {
            // 10s is below the 5-minute floor → InitVault reverts, vault stays Created.
            const bad = await initWith(101n, { objectionWindow: 10n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n });
            expect(bad.res.transactions).toHaveTransaction({ from: factory.address, to: bad.v.address, success: false });
            expect((await bad.v.getVaultState()).state).toBe(0n);

            const { v } = await initWith(102n, { objectionWindow: 3600n, disputeTimeoutWindow: 7200n, destroyGraceWindow: 1800n });
            expect(await v.getObjectionWindow()).toBe(3600n);
            expect(await v.getDisputeTimeoutWindow()).toBe(7200n);
            expect(await v.getDestroyGraceWindow()).toBe(1800n);
        });

        it('39: 0 windows fall back to the Default* consts', async () => {
            const { v } = await initWith(103n, { objectionWindow: 0n, disputeTimeoutWindow: 0n, destroyGraceWindow: 0n });
            expect(await v.getObjectionWindow()).toBe(BigInt(OBJECTION_WINDOW));
            expect(await v.getDisputeTimeoutWindow()).toBe(BigInt(DISPUTE_TIMEOUT_WINDOW));
            expect(await v.getDestroyGraceWindow()).toBe(BigInt(DESTROY_GRACE_WINDOW));
        });

        it('40: settlement timing end-to-end uses the seeded windows', async () => {
            const { v } = await initWith(104n, { objectionWindow: 3600n, disputeTimeoutWindow: 7200n, destroyGraceWindow: 1800n });
            await fundBoth(v.address);
            blockchain.now = NOW + 500;
            await submitReport(relayer, DELIVERED, VTYPE, undefined, null, v.address, 104n);
            // Objection window is the seeded 3600s, not the 48h default.
            expect(await v.getObjectionDeadline()).toBe(BigInt(NOW + 500 + 3600));

            // FinalizeDelivery is refused until the seeded window elapses…
            blockchain.now = NOW + 500 + 3599;
            const early = await v.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
            expect(early.transactions).toHaveTransaction({ from: relayer.address, to: v.address, success: false });
            // …then succeeds.
            blockchain.now = NOW + 500 + 3601;
            await v.send(relayer.getSender(), { value: toNano('0.1') }, 'FinalizeDelivery');
            expect((await v.getVaultState()).state).toBe(3n);
        });

        it('41: a Partial report opens the dispute using the seeded disputeTimeoutWindow', async () => {
            const { v } = await initWith(105n, { objectionWindow: 0n, disputeTimeoutWindow: 7200n, destroyGraceWindow: 0n });
            await fundBoth(v.address);
            blockchain.now = NOW + 100;
            await submitReport(relayer, PARTIAL, VTYPE, undefined, null, v.address, 105n);
            expect((await v.getVaultState()).state).toBe(4n);   // DISPUTED
            expect(await v.getDisputeDeadline()).toBe(BigInt(NOW + 100 + 7200));
        });
    });
});
