import "@stdlib/ownable";

// ============================================================
// EscrowOracleVault (V3) — oracle-settled jetton escrow
// ============================================================
//
// A V3 variant of EscrowJettonVault: the entire V2 jetton value layer and the
// V1 state machine / dispute / settlement / timeout / doc-hash logic are reused
// VERBATIM. V3 ADDS an oracle-driven settlement path alongside (never replacing)
// the two-phase doc-hash confirm:
//   • A whitelisted oracle report arrives via OracleRegistry (sender-gated).
//   • "Delivered" opens a buyer-objection window; it does NOT pay out directly.
//   • After the window with no buyer objection, anyone may FinalizeDelivery →
//     the standard success allocation runs. A buyer dispute during the window
//     pre-empts finalization (RaiseDispute → DISPUTED), preserving the existing
//     "no unilateral fund movement" invariant.
// See V3_ORACLE_MARKETPLACE_DESIGN.md §4.3.
//
// Mirrors EscrowVault (V1) state machine and dispute/settlement/timeout/doc-hash
// logic VERBATIM. The ONLY differences are the value layer:
//   • Deposits arrive as TEP-74 `transfer_notification` from the vault's OWN
//     jetton wallet (not as op-coded TON sends).
//   • Payouts/refunds are jetton `transfer`s sent through that wallet.
//   • The vault discovers its jetton wallet via `ProvideWalletAddress`.
//
// CRITICAL invariants (see V2_JETTON_ESCROW_DESIGN.md §6):
//   1. A deposit notification is credited iff sender() == myJettonWallet AND jwResolved.
//   2. myJettonWallet is set ONLY from a TakeWalletAddress sent by the stored jettonMaster.
//   3. Once real jettons are held, an invalid deposit is REFUNDED, never reverted
//      (a revert would strand the jettons in the vault's wallet).
//   4. Native TON is gas only; trade amounts are in the jetton's minimal units.
// ============================================================

// ─── TEP-74 / TEP-89 standard jetton messages ────────────────────────────────

message(0x0f8a7ea5) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;   // Either bit + payload
}

message(0x7362d09c) JettonTransferNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;                      // the original depositor
    forwardPayload: Slice as remaining;
}

message(0x2c76b973) ProvideWalletAddress {
    queryId: Int as uint64;
    ownerAddress: Address;
    includeAddress: Bool;
}

message(0xd1735400) TakeWalletAddress {
    queryId: Int as uint64;
    walletAddress: Address;
    ownerAddress: Slice as remaining;     // Maybe ^MsgAddress — ignored
}

message(0xd53276db) JettonExcesses {
    queryId: Int as uint64;
}

// ============================================================
// Vault control messages (same op-codes as V1, minus Buyer/SellerDeposit
// which are replaced by jetton notifications)
// ============================================================

message(0x1001) InitVault {
    buyer: Address;
    seller: Address;
    jettonMaster: Address;              // the asset this vault escrows
    tradeValue: Int as coins;          // in jetton minimal units
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    commissionairesDao: Address;
    tradeId: Int as uint64;
    deadline: Int as uint32;
    // ── V3 oracle fields ──
    oracleRegistry: Address;            // sole authority allowed to submit OracleReport
    validationType: Int as uint8;       // report kind this vault accepts (0 = any)
    agreementCID: Cell?;                // IPFS CID of the signed terms (informational anchor)
    settlementMode: Int as uint8;       // 0 = oracle-only, 1 = manual-only (doc-hash)
    // ── V3.1 Tier 2: dispute-timing windows seeded from the listing (0 => vault default) ──
    objectionWindow: Int as uint32;      // post-report window for either party to dispute
    disputeTimeoutWindow: Int as uint32; // dispute auto-timeout
    destroyGraceWindow: Int as uint32;   // grace before a terminal vault self-destructs
}

// Authenticated report forwarded by OracleRegistry. Field layout MUST match the
// identical `message(0x5202) OracleReport` declared in oracle_registry.tact.
message(0x5202) OracleReport {
    tradeId: Int as uint64;
    validationType: Int as uint8;
    status: Int as uint8;               // 0 Delivered · 1 Failed · 2 Partial/dispute
    proof: Cell?;
}

message(0x100C) VaultInitOk {
    tradeId: Int as uint64;
}

message(0x1004) ConfirmTrade {}
message(0x1005) RaiseDispute {}

message(0x1006) ResolveDispute {
    buyerShare: Int as coins;
    sellerShare: Int as coins;
    daoFee: Int as coins;
}

message(0x1007) Withdraw {}
message(0x1008) CancelTrade {}

message(0x1009) SellerConfirmDelivery {
    docHash: Int as uint256;
}

message(0x100A) BuyerConfirmReceipt {
    docHash: Int as uint256;
}

message(0x100B) RaiseDisputeWithClaim {
    docHash: Int as uint256;
    reason:  String;
}

message(0x100D) ProposeSettlement {
    buyerPct: Int as uint8;
}

// Buyer voluntarily confirms receipt and releases funds to the seller NOW,
// waiving any remaining objection window. Always the buyer's prerogative.
message(0x100E) BuyerAcceptDelivery {}

// ─── Events ───────────────────────────────────────────────────────────────────

message(0xE001) EvtStateChanged {
    tradeId: Int as uint64;
    oldState: Int as uint8;
    newState: Int as uint8;
}

message(0xE002) EvtDeposit {
    tradeId: Int as uint64;
    depositor: Address;
    amount: Int as coins;
    isBuyer: Bool;
}

message(0xE003) EvtTradeComplete {
    tradeId: Int as uint64;
    sellerPayout: Int as coins;
    commissionPayout: Int as coins;
}

message(0xE004) EvtDisputeResolved {
    tradeId: Int as uint64;
    buyerShare: Int as coins;
    sellerShare: Int as coins;
    daoFee: Int as coins;
}

message(0xE005) EvtConfirmation {
    tradeId: Int as uint64;
    party: Address;
    isSeller: Bool;
}

message(0xE006) EvtDeadlinePassed {
    tradeId: Int as uint64;
}

message(0xE007) EvtDocHashSubmitted {
    tradeId:  Int as uint64;
    isSeller: Bool;
    docHash:  Int as uint256;
}

message(0xE008) EvtJettonWalletResolved {
    tradeId:      Int as uint64;
    jettonWallet: Address;
}

message(0xE009) EvtOracleReport {
    tradeId:           Int as uint64;
    status:            Int as uint8;
    objectionDeadline: Int as uint32;   // 0 unless a Delivered report opened the window
}

// ============================================================
// Getter struct — V1 fields [0-11] kept by index; V2 fields appended
// ============================================================

struct JettonVaultState {
    state: Int as uint8;
    tradeId: Int as uint64;
    buyer: Address;
    seller: Address;
    tradeValue: Int as coins;
    buyerDeposited: Bool;
    sellerDeposited: Bool;
    sellerConfirmed: Bool;
    buyerConfirmed: Bool;
    buyerClaimable: Int as coins;
    sellerClaimable: Int as coins;
    commissionairesClaimable: Int as coins;
    deadline:       Int as uint32;
    sellerDocHash:  Int as uint256;
    buyerDocHash:   Int as uint256;
    disputeDocHash: Int as uint256;
    // ── V2 jetton fields ──
    jettonMaster:   Address;
    jettonWallet:   Address;
    jwResolved:     Bool;
}

contract EscrowOracleVault with Ownable {

    // === State constants (identical to V1) ===
    const StateCreated: Int = 0;
    const StateAwaitingDeposits: Int = 1;
    const StateAwaitingConfirmation: Int = 2;
    const StateSuccessful: Int = 3;
    const StateDisputed: Int = 4;
    const StateResolved: Int = 5;
    const StateCancelled: Int = 6;
    const StateExpired: Int = 7;

    // V3.1: these three timing windows are now SEEDED PER VAULT via InitVault
    // (previously hard-coded consts here). The consts below are the protocol
    // defaults the listing/factory fall back to when they pass 0. Runtime values
    // live in self.disputeTimeoutWindow / self.destroyGraceWindow / self.objectionWindow.
    const DefaultDisputeTimeoutWindow: Int = 2592000; // 30 days

    // Grace window before a terminal vault self-destructs (M-1 companion fix,
    // ported from EscrowJettonVault). A payout jetton transfer is sent with
    // bounce:true and only confirmed later (JettonExcesses) or bounced back — so
    // the vault must NOT vanish the instant claimables hit zero, or a bounce
    // would land on a destroyed contract and strand the returning jettons. We
    // defer the destroy for this long after first entering a terminal state.
    const DefaultDestroyGraceWindow: Int = 3600; // 1 hour

    // === V3 oracle settlement ===
    const DefaultObjectionWindow: Int = 172800;   // 48h window after a Delivered/Failed report; EITHER party may dispute (buyer can release early)
    const OracleDelivered: Int = 0;
    const OracleFailed: Int = 1;
    const OraclePartial: Int = 2;

    // Settlement rail this vault is pinned to (seeded from the listing).
    const SettleModeOracle: Int = 0;       // only oracle reports may settle; manual confirm disabled
    const SettleModeManual: Int = 1;       // only two-phase doc-hash may settle; oracle path disabled

    // === Jetton gas constants ===
    // TON attached to an outbound jetton transfer (paid separately from balance).
    // 0.15 TON, matching EscrowJettonVault's post-audit value (~82x the worst
    // observed jetton-wallet-deploy cost) — see V2_JETTON_ESCROW_DESIGN.md M-1.
    const JettonFwdGas: Int = ton("0.15");
    // TON attached to the wallet-discovery request to the master.
    const WalletDiscoveryGas: Int = ton("0.05");

    owner: Address;

    state: Int as uint8;
    tradeId: Int as uint64;

    buyer: Address;
    seller: Address;
    commissionairesDao: Address;
    factory: Address;

    tradeValue: Int as coins;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;

    buyerDeposited: Bool;
    sellerDeposited: Bool;
    buyerDepositAmount: Int as coins;
    sellerDepositAmount: Int as coins;

    sellerConfirmed: Bool;
    buyerConfirmed: Bool;

    buyerClaimable: Int as coins;
    sellerClaimable: Int as coins;
    commissionairesClaimable: Int as coins;

    deadline:       Int as uint32;
    sellerDocHash:  Int as uint256;
    buyerDocHash:   Int as uint256;
    disputeDocHash: Int as uint256;

    settleProposed: Bool;
    settleBuyerPct: Int as uint8;
    settleProposer: Address;

    disputeDeadline: Int as uint32;

    // Timestamp of first entry into a terminal state; 0 until then. Starts the
    // DestroyGraceWindow so _checkAllWithdrawn defers self-destruct while a
    // payout may still bounce back. Written once (terminal states are never left).
    terminalAt: Int as uint32;

    // Pending jetton payout tracking (M-1 fix, ported from EscrowJettonVault):
    // each Withdraw gets a unique queryId; bounced() restores claimable if the
    // send fails, instead of irrecoverably zeroing it while the jettons return
    // to our own wallet. See V2_JETTON_ESCROW_DESIGN.md M-1.
    withdrawNonce: Int as uint64;
    pendingPayoutType:   map<Int, Int as uint8>;    // qid → 1=buyer 2=seller 3=comm 4=refund

    pendingPayoutAmount: map<Int, Int as coins>;    // qid → amount

    // V3-L1 fix (V2-N2 ported): deposit refunds previously all shared
    // queryId=0 with no pending-map entry, so a bounce (recipient frozen or
    // destroyed between deposit and refund) returned to our own wallet with no
    // claimable, no record, no recovery. Mirrors the milestone vault's
    // failedPayout scheme: unique qid, accumulate on bounce, reclaim
    // permissionlessly. Only used when pendingPayoutType[qid] == 4.
    pendingRefundTo:   map<Int, Address>;
    failedPayout:      map<Address, Int as coins>;
    failedPayoutCount: Int as uint16;

    // V2-N1 fix (ported — this vault had the same gap, just never separately
    // flagged): counts payouts sent but not yet resolved. _checkAllWithdrawn
    // must not destroy the vault in the SAME transaction that just queued a
    // send whose outcome isn't known yet. Decremented by bounced(), which TVM
    // itself authenticates — never by JettonExcesses: per TEP-74 that message
    // is sent by the RECIPIENT's own jetton wallet (an arbitrary address we
    // can't cheaply verify), so trusting it as confirmation would let a forger
    // who guesses the next sequential queryId suppress a genuine later
    // bounce-restore. Gated by lastPayoutAt below, not held open indefinitely —
    // a real failure bounces back promptly, so there's nothing unbounded to
    // wait for.
    inFlightPayouts: Int as uint16;
    // Timestamp of the most recent tracked send — see _checkAllWithdrawn.
    lastPayoutAt: Int as uint32;

    // === V2: jetton asset + discovered wallet ===
    jettonMaster:   Address;
    myJettonWallet: Address;
    jwResolved:     Bool;

    // === V3: oracle-settled path ===
    oracleRegistry:    Address;
    validationType:    Int as uint8;
    agreementCID:      Cell?;
    settlementMode:    Int as uint8;    // SettleModeOracle | SettleModeManual (seeded by the listing)
    objectionDeadline: Int as uint32;   // 0 until a Delivered/Failed report opens the window
    reportedStatus:    Int as uint8;    // the pending report's status, valid while objectionDeadline != 0
    // V3.1 Tier 2: per-vault timing windows (seeded by InitVault; see Default* consts)
    objectionWindow:      Int as uint32;
    disputeTimeoutWindow: Int as uint32;
    destroyGraceWindow:   Int as uint32;

    init(factory: Address, dao: Address, seqno: Int) {
        self.owner = dao;
        self.factory = factory;
        self.state = self.StateCreated;
        self.tradeId = 0;

        self.buyer = dao;
        self.seller = dao;
        self.commissionairesDao = dao;
        self.tradeValue = 0;
        self.guaranteePercent = 2;
        self.commissionPercent = 1;

        self.buyerDeposited = false;
        self.sellerDeposited = false;
        self.buyerDepositAmount = 0;
        self.sellerDepositAmount = 0;

        self.sellerConfirmed = false;
        self.buyerConfirmed = false;

        self.buyerClaimable = 0;
        self.sellerClaimable = 0;
        self.commissionairesClaimable = 0;

        self.deadline       = 0;
        self.sellerDocHash  = 0;
        self.buyerDocHash   = 0;
        self.disputeDocHash = 0;

        self.settleProposed = false;
        self.settleBuyerPct = 0;
        self.settleProposer = dao;

        self.disputeDeadline = 0;
        self.terminalAt      = 0;
        self.withdrawNonce   = 0;
        self.failedPayoutCount = 0;
        self.inFlightPayouts   = 0;
        self.lastPayoutAt      = 0;

        self.jettonMaster   = dao;   // placeholder; set by InitVault
        self.myJettonWallet = dao;   // placeholder; set by TakeWalletAddress
        self.jwResolved     = false;

        self.oracleRegistry    = dao;   // placeholder; set by InitVault
        self.validationType    = 0;
        self.agreementCID      = null;
        self.settlementMode    = 0;
        self.objectionDeadline = 0;
        self.reportedStatus    = 0;
        self.objectionWindow      = self.DefaultObjectionWindow;      // placeholder; set by InitVault
        self.disputeTimeoutWindow = self.DefaultDisputeTimeoutWindow;
        self.destroyGraceWindow   = self.DefaultDestroyGraceWindow;
    }

    // ========================================
    // InitVault — from factory, once. Also kicks off jetton-wallet discovery.
    // ========================================

    // Gas top-up (rescue): permissionless, accept a plain empty-body TON transfer
    // so anyone can refill the vault's gas if the fixed deployment budget is ever
    // exhausted (e.g. repeated wrong-sender deposit refunds, each costing
    // JettonFwdGas). Without this, a depleted vault could fail a payout send
    // after state already advanced, stranding jettons with no recovery path.
    // Mirrors EscrowJettonVault's identical rescue receiver.
    receive() {}

    receive(msg: InitVault) {
        require(sender() == self.factory, "Only factory can initialize");
        require(self.state == self.StateCreated, "Already initialized");
        require(msg.tradeValue > 0, "Trade value must be positive");
        require(msg.buyer != msg.seller, "Buyer and seller must differ");
        // Neither trade party may be the commissionaires DAO. Withdraw resolves a
        // caller by identity (buyer branch first); if a party collided with the
        // commissionaires address its commission claimable could never be pulled,
        // stranding the jettons and blocking self-destruct. (V2 audit L-3.)
        require(msg.buyer != msg.commissionairesDao && msg.seller != msg.commissionairesDao, "Trade party cannot be commissionaires DAO");
        // V3-L3: self.owner is the arbitrator (dao), baked in at deploy from the
        // listing's ConfigureListing. Fail-closed here too, in case a listing from
        // before that guard existed (or a non-marketplace caller) ever reaches this.
        require(msg.buyer != self.owner && msg.seller != self.owner, "Trade party cannot be the arbitrator");
        require(msg.guaranteePercent > 0 && msg.guaranteePercent <= 20, "Guarantee % must be 1-20");
        require(msg.commissionPercent <= 10, "Commission cannot exceed 10%");
        require(msg.deadline > now(), "Deadline must be in the future");

        self.buyer = msg.buyer;
        self.seller = msg.seller;
        self.tradeValue = msg.tradeValue;
        self.guaranteePercent = msg.guaranteePercent;
        self.commissionPercent = msg.commissionPercent;
        self.commissionairesDao = msg.commissionairesDao;
        self.tradeId = msg.tradeId;
        self.jettonMaster = msg.jettonMaster;

        require(msg.settlementMode <= 1, "Invalid settlement mode");
        self.oracleRegistry = msg.oracleRegistry;
        self.validationType = msg.validationType;
        self.agreementCID   = msg.agreementCID;
        self.settlementMode = msg.settlementMode;

        // V3.1 Tier 2: adopt the listing's dispute-timing windows. 0 => keep the
        // protocol default; clamp to a 5-minute..1-year band as a safety net
        // (the listing already validates, but a vault may be init'd directly in tests).
        self.objectionWindow      = self._windowOr(msg.objectionWindow,      self.DefaultObjectionWindow);
        self.disputeTimeoutWindow = self._windowOr(msg.disputeTimeoutWindow, self.DefaultDisputeTimeoutWindow);
        self.destroyGraceWindow   = self._windowOr(msg.destroyGraceWindow,   self.DefaultDestroyGraceWindow);

        self.buyerDepositAmount = msg.tradeValue;
        self.sellerDepositAmount = msg.tradeValue * msg.guaranteePercent / 100;
        // V3-L2 / MK-N3: integer division floors sellerDepositAmount to 0 for a
        // small enough tradeValue (e.g. < 100 at 2%). A zero requirement means
        // DepositBond's "already bonded" gate is the only thing standing between
        // the trade and activating with no seller collateral at all — reject it
        // here instead; the bounce this throw causes lets the listing/factory
        // refund the buyer cleanly through their existing bounced() handlers.
        require(self.sellerDepositAmount > 0, "Trade value too small for a non-zero guarantee deposit");
        self.deadline = msg.deadline;

        self.state = self.StateAwaitingDeposits;

        // Ack the factory.
        send(SendParameters{
            to: self.factory,
            value: ton("0.05"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: VaultInitOk{ tradeId: msg.tradeId }.toCell()
        });

        // Ask the (whitelisted) master for our jetton wallet address. Deposits
        // are rejected until the reply lands, so attribution is always safe.
        self._requestJettonWallet();
    }

    // ========================================
    // TakeWalletAddress — master's reply with our jetton wallet address.
    // ========================================

    receive(msg: TakeWalletAddress) {
        require(sender() == self.jettonMaster, "Only jetton master may resolve wallet");
        require(!self.jwResolved, "Wallet already resolved");
        self.myJettonWallet = msg.walletAddress;
        self.jwResolved = true;
        emit(EvtJettonWalletResolved{ tradeId: self.tradeId, jettonWallet: msg.walletAddress }.toCell());
    }

    // ========================================
    // Deposit — TEP-74 transfer notification from OUR jetton wallet.
    // ========================================
    // Once we hold real jettons we MUST NOT throw — an invalid deposit is
    // refunded to the sender instead, so jettons can never be trapped.

    receive(msg: JettonTransferNotification) {
        // A spoofed notification carries no real jettons → safe to reject hard.
        require(self.jwResolved, "Jetton wallet not resolved yet");
        require(sender() == self.myJettonWallet, "Not from our jetton wallet");

        let from: Address = msg.sender;
        let amt: Int = msg.amount;

        // Wrong phase → refund the whole amount.
        if (self.state != self.StateAwaitingDeposits) {
            self._refundDeposit(from, amt);
            return;
        }

        if (from == self.buyer) {
            if (self.buyerDeposited) { self._refundDeposit(from, amt); return; }
            let required: Int = self.buyerDepositAmount;
            if (amt < required) { self._refundDeposit(from, amt); return; }
            if (amt > required) { self._refundDeposit(from, amt - required); }
            self.buyerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.buyer, amount: required, isBuyer: true }.toCell());
            self._checkBothDeposited();
        } else if (from == self.seller) {
            if (self.sellerDeposited) { self._refundDeposit(from, amt); return; }
            let required: Int = self.sellerDepositAmount;
            if (amt < required) { self._refundDeposit(from, amt); return; }
            if (amt > required) { self._refundDeposit(from, amt - required); }
            self.sellerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.seller, amount: required, isBuyer: false }.toCell());
            self._checkBothDeposited();
        } else {
            // Not a trade party → refund.
            self._refundDeposit(from, amt);
        }
    }

    // ========================================
    // ConfirmTrade (two-phase) — identical to V1
    // ========================================

    receive(msg: ConfirmTrade) {
        require(self.settlementMode != self.SettleModeOracle, "Oracle-only listing: manual confirm disabled");
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(self.state == self.StateAwaitingConfirmation, "Not in confirmation state");
        require(self.deadline == 0 || now() <= self.deadline, "Deadline has passed — call CheckExpiry first");

        if (s == self.seller) {
            require(!self.sellerConfirmed, "Seller already confirmed");
            require(self.sellerDocHash != 0, "Use SellerConfirmDelivery with document hash proof");
            self.sellerConfirmed = true;
            emit(EvtConfirmation{ tradeId: self.tradeId, party: self.seller, isSeller: true }.toCell());
        } else {
            require(!self.buyerConfirmed, "Buyer already confirmed");
            require(self.sellerConfirmed, "Seller must confirm delivery first");
            require(self.sellerDocHash == 0, "Use BuyerConfirmReceipt for doc-hash flow");
            self.buyerConfirmed = true;
            emit(EvtConfirmation{ tradeId: self.tradeId, party: self.buyer, isSeller: false }.toCell());
        }

        if (self.sellerConfirmed && self.buyerConfirmed) {
            self._allocateOnSuccess();
        }
    }

    // ========================================
    // RaiseDispute — V1 logic identical; V3 additionally clears any pending
    // oracle report so a stale objectionDeadline/reportedStatus never lingers
    // into StateDisputed/StateResolved. Not fund-safety-critical on its own —
    // OracleReport and FinalizeDelivery both independently require
    // state == StateAwaitingConfirmation, which a disputed vault never returns
    // to — but leaves the getters accurate for off-chain readers.
    // ========================================

    receive(msg: RaiseDispute) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(
            self.state == self.StateAwaitingConfirmation ||
            self.state == self.StateExpired,
            "Not in disputable state"
        );
        self.objectionDeadline = 0;
        self.reportedStatus = 0;
        self.disputeDeadline = now() + self.disputeTimeoutWindow;
        self._changeState(self.StateDisputed);
    }

    // ========================================
    // ResolveDispute (DAO owner) — identical to V1
    // ========================================

    receive(msg: ResolveDispute) {
        self.requireOwner();
        require(self.state == self.StateDisputed, "Not in disputed state");

        let totalPool: Int = self.buyerDepositAmount + self.sellerDepositAmount;
        let totalAllocated: Int = msg.buyerShare + msg.sellerShare + msg.daoFee;
        require(totalAllocated == totalPool, "Must allocate entire pool");
        require(msg.daoFee <= totalPool / 10, "DAO fee cannot exceed 10% of pool");

        self.buyerClaimable = msg.buyerShare;
        self.sellerClaimable = msg.sellerShare;
        self.commissionairesClaimable = msg.daoFee;

        self._changeState(self.StateResolved);

        emit(EvtDisputeResolved{
            tradeId: self.tradeId,
            buyerShare: msg.buyerShare,
            sellerShare: msg.sellerShare,
            daoFee: msg.daoFee
        }.toCell());
    }

    // ========================================
    // ProposeSettlement (mutual) — identical to V1
    // ========================================

    receive(msg: ProposeSettlement) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(self.state == self.StateDisputed,    "Not in disputed state");
        require(msg.buyerPct <= 100,                 "Percent must be 0-100");

        if (self.settleProposed && self.settleProposer != s && self.settleBuyerPct == msg.buyerPct) {
            let totalPool: Int   = self.buyerDepositAmount + self.sellerDepositAmount;
            let buyerShare: Int  = totalPool * msg.buyerPct / 100;
            let sellerShare: Int = totalPool - buyerShare;

            self.buyerClaimable           = buyerShare;
            self.sellerClaimable          = sellerShare;
            self.commissionairesClaimable = 0;

            self._changeState(self.StateResolved);

            emit(EvtDisputeResolved{
                tradeId:     self.tradeId,
                buyerShare:  buyerShare,
                sellerShare: sellerShare,
                daoFee:      0
            }.toCell());
        } else {
            self.settleProposed = true;
            self.settleBuyerPct = msg.buyerPct;
            self.settleProposer = s;
        }
    }

    // ========================================
    // Withdraw (pull) — jetton payout instead of TON send.
    // ========================================

    receive(msg: Withdraw) {
        let s: Address = sender();
        require(
            self.state == self.StateSuccessful ||
            self.state == self.StateResolved ||
            self.state == self.StateCancelled,
            "Withdrawals not available"
        );

        let claimable: Int = 0;
        let partyType: Int = 0;   // 1=buyer 2=seller 3=commissionaires

        if (s == self.buyer) {
            claimable = self.buyerClaimable;
            partyType = 1;
        } else if (s == self.seller) {
            claimable = self.sellerClaimable;
            partyType = 2;
        } else if (s == self.commissionairesDao) {
            claimable = self.commissionairesClaimable;
            partyType = 3;
        } else {
            require(false, "Not authorized to withdraw");
        }

        require(claimable > 0, "Nothing to withdraw");

        // M-1 fix: record payout BEFORE zeroing claimable. If the jetton send
        // bounces (wallet temporarily unavailable), bounced() restores the
        // claimable so the party can retry. Without this the claimable is
        // irrecoverably zeroed while the jettons return to our wallet.
        self.withdrawNonce = self.withdrawNonce + 1;
        let qid: Int = self.withdrawNonce;
        self.pendingPayoutType.set(qid, partyType);
        self.pendingPayoutAmount.set(qid, claimable);
        self.inFlightPayouts = self.inFlightPayouts + 1; // V2-N1 (ported)

        if (partyType == 1)      { self.buyerClaimable           = 0; }
        else if (partyType == 2) { self.sellerClaimable          = 0; }
        else                     { self.commissionairesClaimable = 0; }

        self._sendJettons(s, claimable, qid);
        self._checkAllWithdrawn();
    }

    // Restore claimable if the jetton wallet bounces our payout transfer.
    bounced(msg: bounced<JettonTransfer>) {
        let qid: Int = msg.queryId;
        if (!self.pendingPayoutType.exists(qid)) { return; }
        let partyType: Int = self.pendingPayoutType.get(qid)!!;
        let amt: Int = self.pendingPayoutAmount.get(qid)!!;
        self.pendingPayoutType.del(qid);
        self.pendingPayoutAmount.del(qid);
        self.inFlightPayouts = self.inFlightPayouts - 1; // V2-N1 (ported)
        if (partyType == 1)      { self.buyerClaimable           = self.buyerClaimable           + amt; }
        else if (partyType == 2) { self.sellerClaimable          = self.sellerClaimable          + amt; }
        else if (partyType == 3) { self.commissionairesClaimable = self.commissionairesClaimable + amt; }
        else {
            // V3-L1: a bounced deposit refund — the recipient isn't necessarily a
            // trade party, so there's no claimable bucket to restore into.
            // Accumulate for permissionless reclaim instead.
            let to: Address = self.pendingRefundTo.get(qid)!!;
            self.pendingRefundTo.del(qid);
            let prior: Int = 0;
            let isNewEntry: Bool = !self.failedPayout.exists(to);
            if (!isNewEntry) { prior = self.failedPayout.get(to)!!; }
            self.failedPayout.set(to, prior + amt);
            if (isNewEntry) { self.failedPayoutCount = self.failedPayoutCount + 1; }
        }
    }

    // Best-effort cleanup only — NOT relied on for correctness. Per TEP-74,
    // `excesses` is sent by the RECIPIENT's own jetton wallet, not
    // self.myJettonWallet, so the check below means this in practice only
    // matches the narrow case where that happens to coincide. Real resolution
    // is time-based (lastPayoutAt, see _checkAllWithdrawn) plus bounced().
    receive(msg: JettonExcesses) {
        if (sender() != self.myJettonWallet) { return; }
        if (!self.pendingPayoutType.exists(msg.queryId)) { return; }
        if (self.pendingPayoutType.get(msg.queryId)!! == 4) {
            self.pendingRefundTo.del(msg.queryId);
        }
        self.pendingPayoutType.del(msg.queryId);
        self.pendingPayoutAmount.del(msg.queryId);
        self.inFlightPayouts = self.inFlightPayouts - 1; // V2-N1 (ported)
        self._checkAllWithdrawn();
    }

    // V3-L1: permissionless retry for a recipient whose deposit refund bounced.
    receive("ClaimFailedPayout") {
        let s: Address = sender();
        require(self.failedPayout.exists(s) && self.failedPayout.get(s)!! > 0, "No failed payout to claim");
        let amt: Int = self.failedPayout.get(s)!!;
        self.failedPayout.del(s);
        self.failedPayoutCount = self.failedPayoutCount - 1;
        self._refundDeposit(s, amt);
    }

    // ========================================
    // CancelTrade — identical control flow; refunds are jettons via Withdraw.
    // ========================================

    receive(msg: CancelTrade) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(
            self.state == self.StateAwaitingDeposits ||
            self.state == self.StateExpired,
            "Can only cancel before full deposit or after expiry"
        );

        if (self.buyerDeposited) {
            self.buyerClaimable = self.buyerDepositAmount;
        }
        if (self.sellerDeposited) {
            self.sellerClaimable = self.sellerDepositAmount;
        }

        self._changeState(self.StateCancelled);
        self._checkAllWithdrawn();
    }

    // ========================================
    // ForceExpiredCancel (DAO) — identical to V1
    // ========================================

    receive("ForceExpiredCancel") {
        self.requireOwner();
        require(self.state == self.StateExpired, "Only from Expired state");
        if (self.buyerDeposited)  { self.buyerClaimable  = self.buyerDepositAmount;  }
        if (self.sellerDeposited) { self.sellerClaimable = self.sellerDepositAmount; }
        self._changeState(self.StateCancelled);
        self._checkAllWithdrawn();
    }

    // ========================================
    // SellerConfirmDelivery / BuyerConfirmReceipt — identical to V1
    // ========================================

    receive(msg: SellerConfirmDelivery) {
        require(self.settlementMode != self.SettleModeOracle,   "Oracle-only listing: manual confirm disabled");
        require(sender() == self.seller,                         "Only seller");
        require(self.state == self.StateAwaitingConfirmation,    "Not in confirmation state");
        require(!self.sellerConfirmed,                           "Already confirmed");
        require(msg.docHash != 0,                               "Document hash required");
        require(self.deadline == 0 || now() <= self.deadline,   "Deadline has passed");

        self.sellerDocHash   = msg.docHash;
        self.sellerConfirmed = true;

        emit(EvtDocHashSubmitted{ tradeId: self.tradeId, isSeller: true,  docHash: msg.docHash }.toCell());
        emit(EvtConfirmation{     tradeId: self.tradeId, party: self.seller, isSeller: true }.toCell());
    }

    receive(msg: BuyerConfirmReceipt) {
        require(self.settlementMode != self.SettleModeOracle,   "Oracle-only listing: manual confirm disabled");
        require(sender() == self.buyer,                          "Only buyer");
        require(self.state == self.StateAwaitingConfirmation,    "Not in confirmation state");
        require(!self.buyerConfirmed,                            "Already confirmed");
        require(self.sellerDocHash != 0,                        "Seller must confirm with doc hash first");
        require(msg.docHash == self.sellerDocHash,              "Document hash mismatch");

        self.buyerDocHash   = msg.docHash;
        self.buyerConfirmed = true;

        emit(EvtDocHashSubmitted{ tradeId: self.tradeId, isSeller: false, docHash: msg.docHash }.toCell());
        self._allocateOnSuccess();
    }

    // ========================================
    // CheckExpiry / RaiseDisputeWithClaim / CheckDisputeTimeout — identical to V1
    // ========================================

    receive("CheckExpiry") {
        require(self.state == self.StateAwaitingConfirmation,  "Not in confirmation state");
        require(self.deadline > 0,                             "No deadline set for this vault");
        require(now() > self.deadline,                         "Deadline has not passed yet");
        require(!self.sellerConfirmed,                         "Seller already confirmed");
        // A pending oracle report (Delivered/Failed window open) must NOT be
        // voidable by expiry: in oracle mode sellerConfirmed can never be true,
        // so without this guard anyone could expire a delivered trade and let the
        // buyer reclaim full payment via CancelTrade. Once a window is open the
        // trade settles through FinalizeDelivery (or a dispute), never expiry.
        require(self.objectionDeadline == 0,                   "Oracle report pending — finalize or dispute instead");

        self._changeState(self.StateExpired);
        emit(EvtDeadlinePassed{ tradeId: self.tradeId }.toCell());
    }

    // Permissionless: perform the destroy that _checkAllWithdrawn deferred during
    // the grace window, reclaiming the vault's leftover gas. Anyone may call it —
    // it only acts in a terminal state with every claimable already at zero, so
    // it grants no privilege and can take nothing from anyone. Too-early = no-op.
    receive("Reap") {
        self._checkAllWithdrawn();
    }

    receive(msg: RaiseDisputeWithClaim) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller,           "Not a trade party");
        require(
            self.state == self.StateAwaitingConfirmation ||
            self.state == self.StateExpired,
            "Cannot raise dispute in current state"
        );
        require(msg.docHash != 0,                              "Doc hash evidence required");

        self.disputeDocHash = msg.docHash;
        self.disputeDeadline = now() + self.disputeTimeoutWindow;
        self._changeState(self.StateDisputed);
    }

    receive("CheckDisputeTimeout") {
        require(self.state == self.StateDisputed,  "Not in disputed state");
        require(self.disputeDeadline > 0,          "No dispute deadline set");
        require(now() > self.disputeDeadline,      "Dispute window not yet passed");

        let totalPool: Int   = self.buyerDepositAmount + self.sellerDepositAmount;
        let buyerShare: Int  = totalPool / 2;
        let sellerShare: Int = totalPool - buyerShare;

        self.buyerClaimable           = buyerShare;
        self.sellerClaimable          = sellerShare;
        self.commissionairesClaimable = 0;

        self._changeState(self.StateResolved);

        emit(EvtDisputeResolved{
            tradeId:     self.tradeId,
            buyerShare:  buyerShare,
            sellerShare: sellerShare,
            daoFee:      0
        }.toCell());
    }

    // ========================================
    // V3: Oracle-settled path
    // ========================================
    // An authenticated report arrives ONLY from the whitelisted OracleRegistry.
    // Delivered opens a buyer-objection window (no payout). Failed refunds both.
    // Partial routes to the standard dispute machinery. A buyer objection is just
    // a normal RaiseDispute during the window, which pre-empts FinalizeDelivery.

    receive(msg: OracleReport) {
        require(self.settlementMode != self.SettleModeManual,  "Manual-only listing: oracle path disabled");
        require(sender() == self.oracleRegistry,               "Not from oracle registry");
        require(self.state == self.StateAwaitingConfirmation,  "Not in confirmation state");
        require(self.objectionDeadline == 0,                   "An oracle report is already pending");
        require(msg.tradeId == self.tradeId,                   "Wrong trade");
        // validationType 0 = accept any report kind (the documented wildcard);
        // otherwise the report kind must match exactly.
        require(self.validationType == 0 || msg.validationType == self.validationType, "Validation type mismatch");
        require(self.deadline == 0 || now() <= self.deadline,  "Deadline has passed — call CheckExpiry first");

        if (msg.status == self.OraclePartial) {
            // Oracle itself reports a contested outcome → straight to dispute.
            self.disputeDeadline = now() + self.disputeTimeoutWindow;
            self._changeState(self.StateDisputed);
            emit(EvtOracleReport{ tradeId: self.tradeId, status: self.OraclePartial, objectionDeadline: 0 }.toCell());
        } else {
            // Delivered OR Failed → open a 48h objection window. EITHER party may
            // RaiseDispute before it elapses; otherwise anyone may FinalizeDelivery
            // to apply the reported outcome. Fund movement is never unilateral.
            require(msg.status == self.OracleDelivered || msg.status == self.OracleFailed, "Unknown status");
            self.reportedStatus    = msg.status;
            self.objectionDeadline = now() + self.objectionWindow;
            emit(EvtOracleReport{ tradeId: self.tradeId, status: msg.status, objectionDeadline: self.objectionDeadline }.toCell());
        }
    }

    // Permissionless: after the objection window elapses with no buyer dispute,
    // settle exactly as a successful two-phase confirm would.
    receive("FinalizeDelivery") {
        require(self.state == self.StateAwaitingConfirmation,  "Not in confirmation state");
        require(self.objectionDeadline != 0,                   "No oracle report to finalize");
        require(now() >= self.objectionDeadline,               "Objection window still open");

        let wasFailed: Bool = self.reportedStatus == self.OracleFailed;
        self.objectionDeadline = 0;
        self.reportedStatus    = 0;

        if (wasFailed) {
            // Confirmed non-delivery → buyer takes the whole pool (trade value + the
            // seller's slashed guarantee bond). Seller gets nothing.
            let buyerRefund: Int = 0;
            if (self.buyerDeposited)  { buyerRefund = buyerRefund + self.buyerDepositAmount;  }
            if (self.sellerDeposited) { buyerRefund = buyerRefund + self.sellerDepositAmount; }
            self.buyerClaimable  = buyerRefund;
            self.sellerClaimable = 0;
            self._changeState(self.StateCancelled);
            self._checkAllWithdrawn();
        } else {
            // Delivered → standard success allocation (seller + commission).
            self._allocateOnSuccess();
        }
    }

    // Buyer confirms receipt and releases funds to the seller immediately, waiving
    // any remaining objection window. Buyer-only + can only pay the seller, so it's
    // always safe and available in either settlement mode / with or without a report.
    // Also clears any pending oracle report (same getter-hygiene reasoning as
    // RaiseDispute above) so a stale objectionDeadline never lingers into StateSuccessful.
    receive(msg: BuyerAcceptDelivery) {
        require(sender() == self.buyer,                        "Only the buyer can release funds");
        require(self.state == self.StateAwaitingConfirmation,  "Only from the active/confirmation state");
        self.objectionDeadline = 0;
        self.reportedStatus    = 0;
        self._allocateOnSuccess();
    }

    // ========================================
    // Internal helpers
    // ========================================

    // Allocate the pool to seller + commission on a successful two-phase confirm.
    // V3.1: resolve a seeded timing window — 0 means "use the protocol default" —
    // and clamp it to a 5-minute..1-year band.
    fun _windowOr(value: Int, fallback: Int): Int {
        let v: Int = value;
        if (v == 0) { v = fallback; }
        require(v >= 300 && v <= 31536000, "Window out of range (5m..1y)");
        return v;
    }

    fun _allocateOnSuccess() {
        let totalPool: Int        = self.buyerDepositAmount + self.sellerDepositAmount;
        let commissionAmount: Int = self.tradeValue * self.commissionPercent / 100;
        let sellerPayout: Int     = totalPool - commissionAmount;

        self.sellerClaimable          = sellerPayout;
        self.commissionairesClaimable = commissionAmount;
        self.buyerClaimable           = 0;

        self._changeState(self.StateSuccessful);

        emit(EvtTradeComplete{
            tradeId:          self.tradeId,
            sellerPayout:     sellerPayout,
            commissionPayout: commissionAmount
        }.toCell());
    }

    // Send `amount` jettons to `to` through our own jetton wallet.
    // forwardPayload carries the single Either=0 bit so standard wallets parse
    // an empty inline payload without throwing. bounce: true + a queryId lets
    // bounced() restore claimable on failure (M-1 fix). Deposit refunds route
    // through _refundDeposit below, which allocates a real tracked queryId
    // instead of the old hardcoded 0 (V3-L1).
    fun _sendJettons(to: Address, amount: Int, queryId: Int) {
        if (amount <= 0) { return; }
        self.lastPayoutAt = now();
        send(SendParameters{
            to:     self.myJettonWallet,
            value:  self.JettonFwdGas,
            mode:   SendPayGasSeparately,
            bounce: true,
            body:   JettonTransfer{
                queryId:             queryId,
                amount:              amount,
                destination:         to,
                responseDestination: myAddress(),   // recoup leftover gas to the vault
                customPayload:       null,
                forwardTonAmount:    0,
                forwardPayload:      beginCell().storeUint(0, 1).endCell().asSlice()
            }.toCell()
        });
    }

    // V3-L1: refund a deposit through the same tracked, bounce-recoverable
    // path as a Withdraw payout, instead of the untracked queryId=0 sends this
    // replaces.
    fun _refundDeposit(to: Address, amount: Int) {
        if (amount <= 0) { return; }
        self.withdrawNonce = self.withdrawNonce + 1;
        let qid: Int = self.withdrawNonce;
        self.pendingPayoutType.set(qid, 4); // 4 = refund
        self.pendingRefundTo.set(qid, to);
        self.pendingPayoutAmount.set(qid, amount);
        self.inFlightPayouts = self.inFlightPayouts + 1;
        self._sendJettons(to, amount, qid);
    }

    fun _requestJettonWallet() {
        send(SendParameters{
            to:     self.jettonMaster,
            value:  self.WalletDiscoveryGas,
            mode:   SendPayGasSeparately,
            bounce: false,
            body:   ProvideWalletAddress{
                queryId:        0,
                ownerAddress:   myAddress(),
                includeAddress: false
            }.toCell()
        });
    }

    fun _checkBothDeposited() {
        if (self.buyerDeposited && self.sellerDeposited) {
            self._changeState(self.StateAwaitingConfirmation);
        }
    }

    // Self-destruct once all claimables are zero in a terminal state. By then the
    // jetton wallet has been drained by the Withdraw transfers, so only residual
    // TON gas remains — sweep it to the buyer and destroy.
    fun _checkAllWithdrawn() {
        let terminal: Bool =
            self.state == self.StateSuccessful ||
            self.state == self.StateResolved   ||
            self.state == self.StateCancelled;
        if (!terminal) { return; }

        if (self.buyerClaimable          == 0 &&
            self.sellerClaimable         == 0 &&
            self.commissionairesClaimable == 0) {
            // V2-N1 (ported): never destroy in the same transaction that just
            // queued a payout send. Bounded by lastPayoutAt rather than held
            // open indefinitely — a real failure bounces back promptly, so once
            // destroyGraceWindow has passed since the last send with no bounce,
            // it's safe to treat it as settled (see the JettonExcesses receiver).
            if (self.inFlightPayouts > 0 && now() < self.lastPayoutAt + self.destroyGraceWindow) { return; }
            // V3-L1: unlike inFlightPayouts, this stays an indefinite gate — a
            // bounce already confirmed via bounced() that this money is owed;
            // only ClaimFailedPayout should ever release it.
            if (self.failedPayoutCount > 0) { return; }
            if (self.terminalAt != 0 && now() < self.terminalAt + self.destroyGraceWindow) {
                return; // still inside the grace window — a bounced payout may
                        // yet return and need its claimable restored via bounced().
            }
            send(SendParameters{
                to:    self.buyer,
                value: 0,
                mode:  SendRemainingBalance + SendDestroyIfZero,
                bounce: false
            });
        }
    }

    fun _changeState(newState: Int) {
        let oldState: Int = self.state;
        self.state = newState;
        // Stamp the first entry into a terminal state — starts the destroy grace
        // window. Terminal states are never left, so this is written once.
        if (self.terminalAt == 0 && (
                newState == self.StateSuccessful ||
                newState == self.StateResolved   ||
                newState == self.StateCancelled)) {
            self.terminalAt = now();
        }
        emit(EvtStateChanged{
            tradeId: self.tradeId,
            oldState: oldState,
            newState: newState
        }.toCell());
    }

    // ========================================
    // Getters
    // ========================================

    get fun vaultState(): JettonVaultState {
        return JettonVaultState{
            state:                    self.state,
            tradeId:                  self.tradeId,
            buyer:                    self.buyer,
            seller:                   self.seller,
            tradeValue:               self.tradeValue,
            buyerDeposited:           self.buyerDeposited,
            sellerDeposited:          self.sellerDeposited,
            sellerConfirmed:          self.sellerConfirmed,
            buyerConfirmed:           self.buyerConfirmed,
            buyerClaimable:           self.buyerClaimable,
            sellerClaimable:          self.sellerClaimable,
            commissionairesClaimable: self.commissionairesClaimable,
            deadline:                 self.deadline,
            sellerDocHash:            self.sellerDocHash,
            buyerDocHash:             self.buyerDocHash,
            disputeDocHash:           self.disputeDocHash,
            jettonMaster:             self.jettonMaster,
            jettonWallet:             self.myJettonWallet,
            jwResolved:               self.jwResolved
        };
    }

    get fun tradeState(): Int { return self.state; }
    get fun totalPool(): Int { return self.buyerDepositAmount + self.sellerDepositAmount; }
    get fun requiredBuyerDeposit(): Int { return self.buyerDepositAmount; }
    get fun requiredSellerDeposit(): Int { return self.sellerDepositAmount; }
    get fun jettonWallet(): Address { return self.myJettonWallet; }
    get fun jettonMasterAddr(): Address { return self.jettonMaster; }
    get fun walletResolved(): Bool { return self.jwResolved; }

    get fun settleProposed(): Bool    { return self.settleProposed; }
    get fun settleBuyerPct(): Int     { return self.settleBuyerPct; }
    get fun settleProposer(): Address { return self.settleProposer; }
    get fun disputeDeadline(): Int    { return self.disputeDeadline; }

    // === V3 oracle getters ===
    get fun oracleRegistryAddr(): Address { return self.oracleRegistry; }
    get fun validationType(): Int         { return self.validationType; }
    get fun settlementMode(): Int         { return self.settlementMode; }
    get fun objectionDeadline(): Int      { return self.objectionDeadline; }
    get fun reportedStatus(): Int         { return self.reportedStatus; }
    get fun agreementCID(): Cell?         { return self.agreementCID; }
    get fun objectionWindow(): Int        { return self.objectionWindow; }        // V3.1
    get fun disputeTimeoutWindow(): Int   { return self.disputeTimeoutWindow; }   // V3.1
    get fun destroyGraceWindow(): Int     { return self.destroyGraceWindow; }     // V3.1
}
