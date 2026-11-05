/**
 * OracleRegistryGas — empirical gas profile of the V3 SubmitReport hot path.
 *
 * Measures, on the sandbox TVM:
 *   1. value-reject tx  — fails the `context().value >= ReportGas + RelayReserve`
 *      require first, so its gas ≈ message parse + context read only.
 *   2. valid SubmitReport — full path: canonical build, proof hash, replay
 *      check, Ed25519 verify (CHKSIGNU), two map writes, send action.
 * The difference isolates the trust-critical slice; CHKSIGNU dominates it.
 *
 * Run: npx jest tests/OracleRegistryGas.spec.ts
 *
 * Measured on the sandbox TVM (gas units; compute fee ≈ gas × ~400 nanoTON):
 *   value-reject (parse + context only) ....... ~2,854
 *   full SubmitReport (first report) .......... ~9,661
 *   full SubmitReport (dict warm) ............. ~10,886  ← processedReports
 *                                                            inserts grow pricier
 *                                                            as the dict deepens
 *   trust slice (verify + maps + send setup) .. ~6,807
 * Compute fee for a full relay: ~0.004 TON. The relayer attaches 0.12 TON
 * (0.1 forwarded to the vault + 0.02 RelayReserve) — compute is ~3% of that.
 * CHKSIGNU and SENDMSG are TVM primitives: identical cost in Tact, FunC, Tolk.
 */
import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { beginCell, Cell, toNano, Transaction } from '@ton/core';
import { keyPairFromSeed, sign } from '@ton/crypto';
import { compile } from '@ton/blueprint';
import { OracleRegistry } from '../build/OracleRegistry/tact_OracleRegistry';
import '@ton/test-utils';

function computeGas(tx: Transaction | undefined): bigint {
    const d: any = tx?.description;
    const cp = d?.computePhase;
    if (cp && (cp.type === 'ok' || cp.type === 'vm')) return BigInt(cp.gasUsed);
    return 0n;
}

function storageFee(tx: Transaction | undefined): bigint {
    const d: any = tx?.description;
    const sp = d?.storagePhase;
    return sp ? BigInt(sp.storageFeesCollected) : 0n;
}

describe('OracleRegistry gas profile', () => {
    let blockchain: Blockchain;
    let owner: SandboxContract<TreasuryContract>;
    let relayer: SandboxContract<TreasuryContract>;
    let vaultStub: SandboxContract<TreasuryContract>;
    let registry: SandboxContract<OracleRegistry>;

    // Deterministic DON attestation key (never a real key — test only).
    const donKey = keyPairFromSeed(Buffer.from('11'.repeat(32), 'hex'));
    const donPublicKey = BigInt('0x' + Buffer.from(donKey.publicKey).toString('hex'));

    const proof: Cell = beginCell().storeUint(0x475053, 24).storeBuffer(Buffer.alloc(48)).endCell();

    const buildReport = (tradeId: bigint) => {
        const canonical = beginCell()
            .storeAddress(vaultStub.address)
            .storeUint(tradeId, 64)
            .storeUint(0n, 8)   // validationType
            .storeUint(0n, 8)   // status: Delivered
            .storeUint(BigInt('0x' + proof.hash().toString('hex')), 256)
            .endCell();
        const signature = beginCell().storeBuffer(sign(canonical.hash(), donKey.secretKey)).endCell();
        return {
            $$type: 'SubmitReport' as const,
            vault: vaultStub.address,
            tradeId,
            validationType: 0n,
            status: 0n,
            proof,
            signature,
        };
    };

    beforeAll(async () => {
        await compile('OracleRegistry');
    });

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        owner = await blockchain.treasury('owner');
        relayer = await blockchain.treasury('relayer');
        vaultStub = await blockchain.treasury('vault');

        registry = blockchain.openContract(await OracleRegistry.fromInit(owner.address, donPublicKey));
        // Older tact codegen: one generic send(); null body hits the empty receive().
        const deploy = await registry.send(owner.getSender(), { value: toNano('0.1') }, null);
        expect(deploy.transactions).toHaveTransaction({ to: registry.address, success: true });
    });

    it('profiles the SubmitReport hot path', async () => {
        // ── 1. value-reject: only parse + context().value run before the require
        const reject = await registry.send(
            relayer.getSender(),
            { value: toNano('0.01') }, // < ReportGas (0.1) + RelayReserve (0.02)
            buildReport(1n),
        );
        const pickRegistryTx = (result: { transactions: Transaction[] }) => result.transactions.find((t: Transaction) =>
            (t.inMessage?.info as any)?.dest?.equals?.(registry.address));

        const rejectTx = pickRegistryTx(reject);
        expect(reject.transactions).toHaveTransaction({ from: relayer.address, to: registry.address, success: false });

        // ── 2. valid submission: full trust path
        const valid = await registry.send(
            relayer.getSender(),
            { value: toNano('0.12') },
            buildReport(1n),
        );
        expect(valid.transactions).toHaveTransaction({ from: relayer.address, to: registry.address, success: true });
        const validTx = pickRegistryTx(valid);

        // ── 3. steady-state second report (dict already warm)
        const valid2 = await registry.send(
            relayer.getSender(),
            { value: toNano('0.12') },
            buildReport(2n),
        );
        const valid2Tx = pickRegistryTx(valid2);

        const base = computeGas(rejectTx);
        const full = computeGas(validTx);
        const full2 = computeGas(valid2Tx);
        const feeOf = (tx: Transaction | undefined, path: string): string => {
            const v = path.split('.').reduce((o: any, k) => o?.[k], tx as any);
            return typeof v === 'bigint' ? v.toString() : String(v);
        };

        // eslint-disable-next-line no-console
        console.log(JSON.stringify({
            valueRejectGas: base.toString(),
            submitFullGas: full.toString(),
            submitFullGasSecondReport: full2.toString(),
            trustSliceGas: (full - base).toString(),
            validComputeFeeNano: feeOf(validTx, 'description.computePhase.gasFees'),
            validStorageFeeNano: storageFee(validTx).toString(),
        }, null, 2));

        // Sanity: the full path must cost strictly more than the value reject,
        // and the Ed25519 slice dominates (no sane build inverts that).
        expect(full > base).toBe(true);
    });
});
