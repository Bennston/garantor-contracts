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

    const MinTonForStorage: Int = ton("0.01");
    const DisputeTimeoutWindow: Int = 2592000; // 30 days

    // === V3 oracle settlement ===
    const ObjectionWindow: Int = 172800;   // 48h window after a Delivered/Failed report; EITHER party may dispute (buyer can release early)
    const OracleDelivered: Int = 0;
    const OracleFailed: Int = 1;
    const OraclePartial: Int = 2;

    // Settlement rail this vault is pinned to (seeded from the listing).
    const SettleModeOracle: Int = 0;       // only oracle reports may settle; manual confirm disabled
    const SettleModeManual: Int = 1;       // only two-phase doc-hash may settle; oracle path disabled

    // === Jetton gas constants ===
    // TON attached to an outbound jetton transfer (paid separately from balance).
    const JettonFwdGas: Int = ton("0.05");
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

        self.jettonMaster   = dao;   // placeholder; set by InitVault
        self.myJettonWallet = dao;   // placeholder; set by TakeWalletAddress
        self.jwResolved     = false;

        self.oracleRegistry    = dao;   // placeholder; set by InitVault
        self.validationType    = 0;
        self.agreementCID      = null;
        self.settlementMode    = 0;
        self.objectionDeadline = 0;
        self.reportedStatus    = 0;
    }

    // ========================================
    // InitVault — from factory, once. Also kicks off jetton-wallet discovery.
    // ========================================

    receive(msg: InitVault) {
        require(sender() == self.factory, "Only factory can initialize");
        require(self.state == self.StateCreated, "Already initialized");
        require(msg.tradeValue > 0, "Trade value must be positive");
        require(msg.buyer != msg.seller, "Buyer and seller must differ");
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

        self.buyerDepositAmount = msg.tradeValue;
        self.sellerDepositAmount = msg.tradeValue * msg.guaranteePercent / 100;
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
            self._sendJettons(from, amt);
            return;
        }

        if (from == self.buyer) {
            if (self.buyerDeposited) { self._sendJettons(from, amt); return; }
            let required: Int = self.buyerDepositAmount;
            if (amt < required) { self._sendJettons(from, amt); return; }
            if (amt > required) { self._sendJettons(from, amt - required); }
            self.buyerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.buyer, amount: required, isBuyer: true }.toCell());
            self._checkBothDeposited();
        } else if (from == self.seller) {
            if (self.sellerDeposited) { self._sendJettons(from, amt); return; }
            let required: Int = self.sellerDepositAmount;
            if (amt < required) { self._sendJettons(from, amt); return; }
            if (amt > required) { self._sendJettons(from, amt - required); }
            self.sellerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.seller, amount: required, isBuyer: false }.toCell());
            self._checkBothDeposited();
        } else {
            // Not a trade party → refund.
            self._sendJettons(from, amt);
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
    // RaiseDispute — identical to V1
    // ========================================

    receive(msg: RaiseDispute) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(
            self.state == self.StateAwaitingConfirmation ||
            self.state == self.StateExpired,
            "Not in disputable state"
        );
        self.disputeDeadline = now() + self.DisputeTimeoutWindow;
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

        if (s == self.buyer) {
            claimable = self.buyerClaimable;
            self.buyerClaimable = 0;
        } else if (s == self.seller) {
            claimable = self.sellerClaimable;
            self.sellerClaimable = 0;
        } else if (s == self.commissionairesDao) {
            claimable = self.commissionairesClaimable;
            self.commissionairesClaimable = 0;
        } else {
            require(false, "Not authorized to withdraw");
        }

        require(claimable > 0, "Nothing to withdraw");

        self._sendJettons(s, claimable);
        self._checkAllWithdrawn();
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

        self._changeState(self.StateExpired);
        emit(EvtDeadlinePassed{ tradeId: self.tradeId }.toCell());
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
        self.disputeDeadline = now() + self.DisputeTimeoutWindow;
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
        require(msg.validationType == self.validationType,     "Validation type mismatch");
        require(self.deadline == 0 || now() <= self.deadline,  "Deadline has passed — call CheckExpiry first");

        if (msg.status == self.OraclePartial) {
            // Oracle itself reports a contested outcome → straight to dispute.
            self.disputeDeadline = now() + self.DisputeTimeoutWindow;
            self._changeState(self.StateDisputed);
            emit(EvtOracleReport{ tradeId: self.tradeId, status: self.OraclePartial, objectionDeadline: 0 }.toCell());
        } else {
            // Delivered OR Failed → open a 72h objection window. EITHER party may
            // RaiseDispute before it elapses; otherwise anyone may FinalizeDelivery
            // to apply the reported outcome. Fund movement is never unilateral.
            require(msg.status == self.OracleDelivered || msg.status == self.OracleFailed, "Unknown status");
            self.reportedStatus    = msg.status;
            self.objectionDeadline = now() + self.ObjectionWindow;
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
    receive(msg: BuyerAcceptDelivery) {
        require(sender() == self.buyer,                        "Only the buyer can release funds");
        require(self.state == self.StateAwaitingConfirmation,  "Only from the active/confirmation state");
        self._allocateOnSuccess();
    }

    // ========================================
    // Internal helpers
    // ========================================

    // Allocate the pool to seller + commission on a successful two-phase confirm.
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
    // an empty inline payload without throwing.
    fun _sendJettons(to: Address, amount: Int) {
        if (amount <= 0) { return; }
        send(SendParameters{
            to:     self.myJettonWallet,
            value:  self.JettonFwdGas,
            mode:   SendPayGasSeparately,
            bounce: false,
            body:   JettonTransfer{
                queryId:             0,
                amount:              amount,
                destination:         to,
                responseDestination: myAddress(),   // recoup leftover gas to the vault
                customPayload:       null,
                forwardTonAmount:    0,
                forwardPayload:      beginCell().storeUint(0, 1).endCell().asSlice()
            }.toCell()
        });
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
}
