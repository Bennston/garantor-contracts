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

    // TON forwarded with each authenticated OracleReport (covers the vault's
    // handling gas). The submitting relayer must attach at least this much.
    const ReportGas: Int = ton("0.1");

    init(owner: Address, donPublicKey: Int) {
        self.owner = owner;
        self.donPublicKey = donPublicKey;
        self.timelockDelay = 86400;       // 24h default (min 1h; set via UpdateTimelockDelay)
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
        self.pendingEffectiveAt = 0;
    }

    receive(msg: CancelDonKey) {
        self.requireOwner();
        self.pendingEffectiveAt = 0;
    }

    receive(msg: UpdateTimelockDelay) {
        self.requireOwner();
        require(msg.newDelay >= 3600, "Timelock delay minimum is 1 hour");
        self.timelockDelay = msg.newDelay;
    }

    // ========================================
    // Report submission (authenticity by DON signature)
    // ========================================
    receive(msg: SubmitReport) {
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

        require(
            checkSignature(canonical.hash(), msg.signature.beginParse(), self.donPublicKey),
            "Invalid DON signature"
        );

        // Signature valid → forward an authenticated report to the vault. The
        // vault verifies sender() == this registry and that the type matches its own.
        send(SendParameters{
            to:     msg.vault,
            value:  self.ReportGas,
            mode:   SendPayGasSeparately,
            bounce: false,
            body:   OracleReport{
                tradeId:        msg.tradeId,
                validationType: msg.validationType,
                status:         msg.status,
                proof:          msg.proof
            }.toCell()
        });
    }

    // ========================================
    // Getters
    // ========================================
    get fun donPublicKey(): Int { return self.donPublicKey; }
    get fun pendingDonKey(): Int { return self.pendingDonKey; }
    get fun pendingEffectiveAt(): Int { return self.pendingEffectiveAt; }
    get fun timelockDelay(): Int { return self.timelockDelay; }
}
