import "@stdlib/ownable";

// ============================================================
// OracleRegistry (V3) — DON-signature report gateway
// ============================================================
//
// Chainlink CRE hybrid model (see V3_ORACLE_MARKETPLACE_DESIGN.md §4.1):
//   1. A Chainlink CRE workflow fetches the supply-chain / IoT / API data.
//   2. The Chainlink DON reaches consensus on the data.
//   3. Our CRE bridge service re-signs a CANONICAL report with an Ed25519 key
//      (the "DON attestation key") after consensus.
//   4. ANY relayer pushes { report, signature } here as SubmitReport.
//
// Trust anchor is the SIGNATURE, not the sender: the registry verifies the
// Ed25519 signature over the canonical report against the DAO-registered
// donPublicKey, then forwards an authenticated OracleReport to the vault. A
// compromised relayer cannot forge a report — it can only relay DON-signed ones.
//
// The vault trusts only `sender() == oracleRegistry`, so this registry is the
// single choke point where DON authenticity is checked. The key is stored here
// (not per-vault) so the DAO can rotate it in one place.
//
// A valid { report, signature } is public forever once relayed once (any TON
// tx is public), and SubmitReport is intentionally permissionless — so the
// registry rejects a repeat of an already-processed report hash, and requires
// the submitter to attach at least ReportGas rather than letting a resubmit
// spend the registry's own balance. Without both, anyone could replay an old
// signed report to drain the registry's TON, blocking every future report for
// every vault that trusts it.
//
// Canonical report preimage (MUST match the off-chain signer byte-for-byte):
//   cell = beginCell()
//            .storeAddress(vault)
//            .storeUint(tradeId, 64)
//            .storeUint(validationType, 8)
//            .storeUint(status, 8)
//            .storeUint(proofHash, 256)   // proof.hash() or 0
//          .endCell();
//   signed message = cell.hash()          // 256-bit representation hash
// ============================================================

// ─── Owner-only key management (DAO multisig), time-locked ──────────────────
// Key rotation is a two-step time-lock (mirrors EscrowJettonFactory param changes)
// so a compromised owner key cannot instantly swap in a rogue DON key: schedule,
// wait timelockDelay, then apply. The INITIAL key is set at deploy (init), so the
// bootstrap does not wait.
message(0x5210) ScheduleDonKey {
    newKey: Int as uint256;   // Ed25519 public key of the DON attestation bridge
}
message(0x5211) ApplyDonKey {}
message(0x5212) CancelDonKey {}
message(0x5213) UpdateTimelockDelay {
    newDelay: Int as uint32;
}
// V3-M3: owner sweep for the RelayReserve buffer that SubmitReport now
// requires each submission attach on top of ReportGas.
message(0x5214) WithdrawReserve {}

// ─── Relayer → registry (permissionless; authenticity is by signature) ──────
message(0x5201) SubmitReport {
    vault: Address;
    tradeId: Int as uint64;
    validationType: Int as uint8;
    status: Int as uint8;         // 0 Delivered · 1 Failed · 2 Partial/dispute
    proof: Cell?;                 // opaque payload (GPS / temp log / API code); forwarded to the vault
    signature: Cell;              // 64-byte Ed25519 signature over the canonical report hash
}

// ─── Registry → vault (authenticated). Field layout MUST match the identical
//     `message(0x5202) OracleReport` declared in escrow_oracle_vault.tact. ─────
message(0x5202) OracleReport {
    tradeId: Int as uint64;
    validationType: Int as uint8;
    status: Int as uint8;
    proof: Cell?;
}

contract OracleRegistry with Ownable {

    owner: Address;

    // Ed25519 public key of the trusted DON attestation bridge. DAO-rotatable
    // via the time-locked schedule/apply flow below.
    donPublicKey: Int as uint256;

    // Time-lock for key rotation.
    timelockDelay:      Int as uint32;
    pendingDonKey:      Int as uint256;
    pendingEffectiveAt: Int as uint32;   // 0 = no pending rotation

    // A signed report is public forever once submitted once (any TON tx is
    // public), so without this, anyone could replay an old valid {report,
    // signature} indefinitely — and since forwarding always pays ReportGas out
    // of THIS contract's own balance regardless of the submitter's attached
    // value, unbounded replay drains the registry until it can no longer
    // afford to relay ANY report, for ANY vault. Keyed on the canonical
    // report's hash (vault+tradeId+validationType+status+proofHash), so a
    // genuinely new report (different status, new proof, etc.) is unaffected.
    processedReports: map<Int, Bool>;

    // V3-M4 fix: keyed by the vault we just relayed to, so a bounced report
    // (wrong state/type/deadline, manual-mode, another report already pending)
    // can be un-marked in processedReports instead of burning that exact
    // {report, signature} forever. One vault has at most one relay in flight
    // at a time (each SubmitReport is its own sequential transaction; a bounce
    // from a failed one resolves before the next could be submitted), so
    // keying on vault address alone is unambiguous.
    pendingRelay: map<Address, Int>;

    // TON forwarded with each authenticated OracleReport (covers the vault's
    // handling gas). The submitting relayer must attach at least this much —
    // enforced below so a submission can never be subsidized from the
    // registry's own balance.
    const ReportGas: Int = ton("0.1");

    // V3-M3: SendPayGasSeparately pays THIS transaction's own forward/network
    // fee out of the registry's remaining balance, on top of the ReportGas
    // value forwarded — a submitter attaching exactly ReportGas was a net
    // drain on the registry every single relay, the sole gas rail for every
    // vault using this registry. Requiring this small buffer on top makes
    // ordinary operation self-funding instead; WithdrawReserve lets the owner
    // sweep whatever accumulates above the operating float.
    const RelayReserve: Int = ton("0.02");

    init(owner: Address, donPublicKey: Int) {
        self.owner = owner;
        self.donPublicKey = donPublicKey;
        self.timelockDelay = 86400;       // 24h default (min 24h; set via UpdateTimelockDelay)
        self.pendingDonKey = 0;
        self.pendingEffectiveAt = 0;
    }

    // Empty-body deploy handler (Blueprint sends an empty body on deploy).
    receive() {}

    // ========================================
    // Owner: rotate the DON attestation key (time-locked)
    // ========================================
    receive(msg: ScheduleDonKey) {
        self.requireOwner();
        self.pendingDonKey = msg.newKey;
        self.pendingEffectiveAt = now() + self.timelockDelay;
    }

    receive(msg: ApplyDonKey) {
        self.requireOwner();
        require(self.pendingEffectiveAt != 0, "No pending key rotation");
        require(now() >= self.pendingEffectiveAt, "Timelock not yet expired");
        self.donPublicKey = self.pendingDonKey;
        // Clear the pending slot too (not just pendingEffectiveAt) so a monitor
        // reading pendingDonKey doesn't see the now-live key still shown as
        // "pending" — same observability hygiene as CancelDonKey.
        self.pendingDonKey = 0;
        self.pendingEffectiveAt = 0;
    }

    receive(msg: CancelDonKey) {
        self.requireOwner();
        // pendingEffectiveAt = 0 already blocks ApplyDonKey from using the
        // stale pendingDonKey — clearing it too is pure off-chain-observability
        // hygiene, so a cancelled rotation doesn't look "still scheduled" to a
        // monitor reading pendingDonKey directly.
        self.pendingDonKey = 0;
        self.pendingEffectiveAt = 0;
    }

    receive(msg: UpdateTimelockDelay) {
        self.requireOwner();
        // Floored at 24h (V3-M1): a 1h floor let a compromised owner shrink the
        // DON-key rotation timelock's advertised 24h guarantee down to ~1h right
        // before scheduling a rogue key via ScheduleDonKey.
        require(msg.newDelay >= 86400, "Timelock delay minimum is 24h");
        self.timelockDelay = msg.newDelay;
    }

    // V3-M3: sweep accumulated RelayReserve above the float needed to keep
    // relaying — never below 2x ReportGas, so a sweep can't itself starve the
    // very next SubmitReport's forward.
    receive(msg: WithdrawReserve) {
        self.requireOwner();
        let minOperatingFloat: Int = self.ReportGas * 2;
        let withdrawable: Int = myBalance() - minOperatingFloat;
        require(withdrawable > 0, "Nothing to withdraw");
        send(SendParameters{
            to: sender(),
            value: withdrawable,
            mode: 0,
            bounce: false,
            body: "Oracle registry reserve withdrawal".asComment()
        });
    }

    // ========================================
    // Report submission (authenticity by DON signature)
    // ========================================
    receive(msg: SubmitReport) {
        // The submitter must cover the gas we forward — never subsidize a
        // relay from the registry's own balance (that's what makes replay
        // spam free for an attacker; see processedReports above).
        require(context().value >= self.ReportGas + self.RelayReserve,
            "Attach at least ReportGas + RelayReserve to cover forwarding");

        // Bind the (optional) proof payload to the signature.
        let proofHash: Int = 0;
        if (msg.proof != null) {
            proofHash = (msg.proof!!).hash();
        }

        let canonical: Cell = beginCell()
            .storeAddress(msg.vault)
            .storeUint(msg.tradeId, 64)
            .storeUint(msg.validationType, 8)
            .storeUint(msg.status, 8)
            .storeUint(proofHash, 256)
            .endCell();
        let reportHash: Int = canonical.hash();

        // Reject a replay before spending gas on signature verification.
        require(!self.processedReports.exists(reportHash), "Report already processed");

        require(
            checkSignature(reportHash, msg.signature.beginParse(), self.donPublicKey),
            "Invalid DON signature"
        );

        self.processedReports.set(reportHash, true);
        self.pendingRelay.set(msg.vault, reportHash); // V3-M4: let a bounce un-mark this below

        // Signature valid → forward an authenticated report to the vault. The
        // vault verifies sender() == this registry and that the type matches its own.
        // bounce: true (V3-M4) — a vault-side rejection (wrong state/type/
        // deadline, manual-mode, another report pending) now returns here
        // instead of silently burning this exact {report, signature} forever.
        send(SendParameters{
            to:     msg.vault,
            value:  self.ReportGas,
            mode:   SendPayGasSeparately,
            bounce: true,
            body:   OracleReport{
                tradeId:        msg.tradeId,
                validationType: msg.validationType,
                status:         msg.status,
                proof:          msg.proof
            }.toCell()
        });
    }

    // V3-M4: the vault rejected the report we just relayed (wrong state/type/
    // deadline, manual-mode, or another report already pending) — un-mark it
    // in processedReports so the identical {report, signature} can be relayed
    // again once the rejecting condition clears, instead of being burned
    // forever. sender() here is TVM-guaranteed to be the vault we sent to (a
    // bounce can only arrive from the original destination), so this needs no
    // further authentication.
    bounced(msg: Slice) {
        let vaultAddr: Address = sender();
        if (!self.pendingRelay.exists(vaultAddr)) { return; }
        let reportHash: Int = self.pendingRelay.get(vaultAddr)!!;
        self.pendingRelay.del(vaultAddr);
        self.processedReports.del(reportHash);
    }

    // ========================================
    // Getters
    // ========================================
    get fun donPublicKey(): Int { return self.donPublicKey; }
    get fun pendingDonKey(): Int { return self.pendingDonKey; }
    get fun pendingEffectiveAt(): Int { return self.pendingEffectiveAt; }
    get fun timelockDelay(): Int { return self.timelockDelay; }

    // Lets an off-chain relayer check before submitting, so it doesn't burn
    // gas on a report it (or someone else) already relayed successfully.
    get fun isReportProcessed(reportHash: Int): Bool {
        return self.processedReports.exists(reportHash);
    }
}
