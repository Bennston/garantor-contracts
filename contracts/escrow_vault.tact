import "@stdlib/ownable";

// ============================================================
// Messages
// ============================================================

message(0x1001) InitVault {
    buyer: Address;
    seller: Address;
    tradeValue: Int as coins;
    guaranteePercent: Int as uint8;     // seller guarantee % (e.g. 2)
    commissionPercent: Int as uint8;    // platform fee % (e.g. 1)
    commissionairesDao: Address;
    tradeId: Int as uint64;
    deadline: Int as uint32;            // unix timestamp; REQUIRED, must be in the future
}

message(0x100C) VaultInitOk {
    tradeId: Int as uint64;
}

message(0x1002) BuyerDeposit {}

message(0x1003) SellerDeposit {}

message(0x1004) ConfirmTrade {}

message(0x1005) RaiseDispute {}

message(0x1006) ResolveDispute {
    buyerShare: Int as coins;
    sellerShare: Int as coins;
    daoFee: Int as coins;
}

message(0x1007) Withdraw {}

message(0x1008) CancelTrade {}

// ─── Doc-hash confirmation flow ───────────────────────────────────────────────
// Seller uploads a document hash to prove delivery.
// Buyer must re-submit the same hash to confirm receipt — proving they hold the
// same document. Hash mismatch blocks confirmation and protects against spoofing.

message(0x1009) SellerConfirmDelivery {
    docHash: Int as uint256;            // SHA-256 of delivery document
}

message(0x100A) BuyerConfirmReceipt {
    docHash: Int as uint256;            // must equal seller's docHash exactly
}

// Dispute with on-chain evidence — for expired or unresolved vaults.
// Submitting a doc hash creates an immutable claim record for the DAO.
message(0x100B) RaiseDisputeWithClaim {
    docHash: Int as uint256;
    reason:  String;
}

// Buyer and seller mutually settle a dispute on an agreed % split of the pool,
// resolving without the DAO. One party proposes a buyer percentage (0-100);
// the other approves by echoing the exact same value. Requires the counterparty
// to match, so neither can settle unilaterally. No DAO fee on a self-settlement.
message(0x100D) ProposeSettlement {
    buyerPct: Int as uint8;   // 0-100 of the total pool; seller gets the remainder
}

// ============================================================
// Events (emitted as external messages for off-chain indexing)
// ============================================================

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

// ============================================================
// Return struct for getter
// ============================================================
//
// CANONICAL VaultState — 12 fields:
//   [0]  state                      (uint8)
//   [1]  tradeId                    (uint64)
//   [2]  buyer                      (Address)
//   [3]  seller                     (Address)
//   [4]  tradeValue                 (coins)
//   [5]  buyerDeposited             (Bool)
//   [6]  sellerDeposited            (Bool)
//   [7]  sellerConfirmed            (Bool)    ← NEW
//   [8]  buyerConfirmed             (Bool)    ← NEW
//   [9]  buyerClaimable             (coins)
//   [10] sellerClaimable            (coins)
//   [11] commissionairesClaimable   (coins)
// ============================================================

struct VaultState {
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
    // [12] onward — new fields; frontend reads [0-11] by index so these don't break existing code
    deadline:       Int as uint32;
    sellerDocHash:  Int as uint256;
    buyerDocHash:   Int as uint256;
    disputeDocHash: Int as uint256;
}

// ============================================================
// EscrowVault Contract
// ============================================================
//
// State machine:
//   0 = CREATED (waiting for InitVault from factory)
//   1 = AWAITING_DEPOSITS
//   2 = AWAITING_CONFIRMATION (both deposited)
//   3 = SUCCESSFUL (both confirmed, funds allocated)
//   4 = DISPUTED
//   5 = RESOLVED (dispute resolved, funds allocated)
//   6 = CANCELLED
//
// Two-phase confirmation:
//   In state 2, seller confirms delivery first, then buyer confirms receipt.
//   Either party can call ConfirmTrade — it sets their flag.
//   Only when BOTH sellerConfirmed AND buyerConfirmed are true
//   does the vault allocate funds and move to state 3.
//   Either party can raise a dispute at any time in state 2.
//
// Pull pattern: funds are marked as "claimable" and parties
// withdraw separately, preventing reentrancy.
// ============================================================

contract EscrowVault with Ownable {

    // === State constants ===
    const StateCreated: Int = 0;
    const StateAwaitingDeposits: Int = 1;
    const StateAwaitingConfirmation: Int = 2;
    const StateSuccessful: Int = 3;
    const StateDisputed: Int = 4;
    const StateResolved: Int = 5;
    const StateCancelled: Int = 6;
    const StateExpired: Int = 7;   // deadline passed before seller confirmed

    // === Gas reserve ===
    const MinTonForStorage: Int = ton("0.01");

    // === Dispute liveness backstop ===
    // If the DAO never resolves a dispute AND the parties never mutually settle,
    // anyone may force a 50/50 split after this window, so funds can never be
    // permanently locked. Mirrors EscrowVaultMilestone.DisputeTimeoutWindow.
    const DisputeTimeoutWindow: Int = 2592000; // 30 days

    // === Ownable trait field (owner = factory initially, transferred to DAO) ===
    owner: Address;

    // === Vault state ===
    state: Int as uint8;
    tradeId: Int as uint64;

    // === Trade parties ===
    buyer: Address;
    seller: Address;
    commissionairesDao: Address;
    factory: Address;

    // === Trade terms ===
    tradeValue: Int as coins;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;

    // === Deposit tracking ===
    buyerDeposited: Bool;
    sellerDeposited: Bool;
    buyerDepositAmount: Int as coins;
    sellerDepositAmount: Int as coins;

    // === Two-phase confirmation tracking ===
    sellerConfirmed: Bool;
    buyerConfirmed: Bool;

    // === Claimable balances (pull pattern) ===
    buyerClaimable: Int as coins;
    sellerClaimable: Int as coins;
    commissionairesClaimable: Int as coins;

    // === Deadline + doc-hash tracking ===
    deadline:       Int as uint32;   // unix timestamp; 0 = no deadline
    sellerDocHash:  Int as uint256;  // set by SellerConfirmDelivery
    buyerDocHash:   Int as uint256;  // set by BuyerConfirmReceipt (must match seller)
    disputeDocHash: Int as uint256;  // set by RaiseDisputeWithClaim

    // === Mutual dispute settlement — pending %-split proposal ===
    settleProposed: Bool;
    settleBuyerPct: Int as uint8;
    settleProposer: Address;

    // Set when the vault enters DISPUTED; after this, CheckDisputeTimeout is callable.
    disputeDeadline: Int as uint32;

    // ========================================
    // Constructor
    // ========================================

    init(factory: Address, dao: Address, seqno: Int) {
        self.owner = dao;
        self.factory = factory;
        self.state = self.StateCreated;
        self.tradeId = 0;

        // Placeholders — set properly by InitVault
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
    }

    // ========================================
    // Receiver: InitVault (only from factory, only once)
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

        self.buyerDepositAmount = msg.tradeValue;
        self.sellerDepositAmount = msg.tradeValue * msg.guaranteePercent / 100;
        self.deadline = msg.deadline;

        // Initialization should stay to a single essential outbound ack.
        // Emitting a state-change event here can starve the factory ack path.
        self.state = self.StateAwaitingDeposits;

        send(SendParameters{
            to: self.factory,
            value: ton("0.05"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: VaultInitOk{ tradeId: msg.tradeId }.toCell()
        });
    }

    // ========================================
    // Receiver: BuyerDeposit
    // ========================================

    receive(msg: BuyerDeposit) {
        require(sender() == self.buyer, "Only buyer can deposit");
        require(self.state == self.StateAwaitingDeposits, "Not accepting deposits");
        require(!self.buyerDeposited, "Buyer already deposited");

        let msgValue: Int = context().value;
        let required: Int = self.buyerDepositAmount;

        require(msgValue >= required, "Insufficient deposit");

        // Refund any excess above the required deposit immediately
        let excess: Int = msgValue - required;
        if (excess > 0) {
            send(SendParameters{
                to:     self.buyer,
                value:  excess,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Buyer deposit excess refund".asComment()
            });
        }

        self.buyerDeposited = true;

        emit(EvtDeposit{
            tradeId: self.tradeId,
            depositor: self.buyer,
            amount: required,
            isBuyer: true
        }.toCell());

        self._checkBothDeposited();
    }

    // ========================================
    // Receiver: SellerDeposit
    // ========================================

    receive(msg: SellerDeposit) {
        require(sender() == self.seller, "Only seller can deposit");
        require(self.state == self.StateAwaitingDeposits, "Not accepting deposits");
        require(!self.sellerDeposited, "Seller already deposited");

        let msgValue: Int = context().value;
        let required: Int = self.sellerDepositAmount;

        require(msgValue >= required, "Insufficient deposit");

        // Refund any excess above the required deposit immediately
        let excess: Int = msgValue - required;
        if (excess > 0) {
            send(SendParameters{
                to:     self.seller,
                value:  excess,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Seller deposit excess refund".asComment()
            });
        }

        self.sellerDeposited = true;

        emit(EvtDeposit{
            tradeId: self.tradeId,
            depositor: self.seller,
            amount: required,
            isBuyer: false
        }.toCell());

        self._checkBothDeposited();
    }

    // ========================================
    // Receiver: ConfirmTrade (TWO-PHASE)
    // ========================================
    //
    // Phase 1: Seller confirms delivery/service
    // Phase 2: Buyer confirms receipt/satisfaction
    // Only when both have confirmed: funds are allocated.
    // ========================================

    receive(msg: ConfirmTrade) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Not a trade party");
        require(self.state == self.StateAwaitingConfirmation, "Not in confirmation state");
        require(self.deadline == 0 || now() <= self.deadline, "Deadline has passed — call CheckExpiry first");

        // Set the caller's confirmation flag
        if (s == self.seller) {
            require(!self.sellerConfirmed, "Seller already confirmed");
            // Sellers must submit delivery evidence before this flag can be set.
            // SellerConfirmDelivery sets sellerDocHash AND sellerConfirmed, making
            // this branch unreachable in practice — which is the intent: all deliveries
            // must carry on-chain document proof via the SellerConfirmDelivery path.
            require(self.sellerDocHash != 0, "Use SellerConfirmDelivery with document hash proof");
            self.sellerConfirmed = true;

            emit(EvtConfirmation{
                tradeId: self.tradeId,
                party: self.seller,
                isSeller: true
            }.toCell());
        } else {
            require(!self.buyerConfirmed, "Buyer already confirmed");
            require(self.sellerConfirmed, "Seller must confirm delivery first");
            // sellerDocHash will always be set when sellerConfirmed is true (enforced above),
            // so buyers must always use BuyerConfirmReceipt — the plain ConfirmTrade buyer
            // path is intentionally unreachable as a second layer of enforcement.
            require(self.sellerDocHash == 0, "Use BuyerConfirmReceipt for doc-hash flow");
            self.buyerConfirmed = true;

            emit(EvtConfirmation{
                tradeId: self.tradeId,
                party: self.buyer,
                isSeller: false
            }.toCell());
        }

        // Only allocate funds when BOTH have confirmed
        if (self.sellerConfirmed && self.buyerConfirmed) {
            let totalPool: Int = self.buyerDepositAmount + self.sellerDepositAmount;
            let commissionAmount: Int = self.tradeValue * self.commissionPercent / 100;
            let sellerPayout: Int = totalPool - commissionAmount;

            self.sellerClaimable = sellerPayout;
            self.commissionairesClaimable = commissionAmount;
            self.buyerClaimable = 0;

            self._changeState(self.StateSuccessful);

            emit(EvtTradeComplete{
                tradeId: self.tradeId,
                sellerPayout: sellerPayout,
                commissionPayout: commissionAmount
            }.toCell());
        }
    }

    // ========================================
    // Receiver: RaiseDispute (buyer or seller)
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
    // Receiver: ResolveDispute (only DAO owner)
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
    // Receiver: ProposeSettlement (mutual dispute settlement, no DAO)
    // ========================================
    //
    // In a dispute, buyer and seller agree on a % split of the pool and resolve
    // it themselves. One party proposes a buyerPct; the other approves by
    // echoing the exact same value. A different value overwrites the pending
    // proposal (counter-offer). Execution requires the *other* party to match,
    // so neither can settle unilaterally. No DAO fee is taken on a self-settled
    // dispute — the whole pool goes to buyer + seller. Seller gets the exact
    // remainder so conservation holds.

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
    // Receiver: Withdraw (pull pattern)
    // ========================================
    //
    // After each withdrawal, _checkAllWithdrawn() tests whether all
    // claimable balances have reached zero. Once they do, the contract
    // sweeps the remaining gas residue back to the buyer and self-destructs
    // (mode 128 + 32), eliminating storage rent entirely.
    //
    // mode 1 (SendPayGasSeparately) — gas deducted from contract balance,
    // exact claimable amount forwarded to recipient.

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

        send(SendParameters{
            to:    s,
            value: claimable,
            mode:  SendPayGasSeparately,
            bounce: false,
            body:  "Escrow withdrawal".asComment()
        });

        self._checkAllWithdrawn();
    }

    // ========================================
    // Receiver: CancelTrade
    // ========================================
    //
    // Allowed in two states:
    //   AWAITING_DEPOSITS (1) — cancel before full deposit; if neither deposited,
    //     all claimables are 0 and vault self-destructs immediately.
    //   EXPIRED (7)           — deadline passed without seller confirming; both
    //     parties deposited so both get their deposits returned.

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

        // Handles the case where no one had deposited yet — claimables are
        // already all zero so the vault can self-destruct immediately.
        self._checkAllWithdrawn();
    }

    // ========================================
    // Receiver: ForceExpiredCancel (DAO only)
    // ========================================
    //
    // Safety escape hatch: if both trade parties ghost on an EXPIRED vault,
    // the DAO can force a cancellation so funds are never permanently locked.
    // Each party may still call Withdraw to claim their deposit back.

    receive("ForceExpiredCancel") {
        self.requireOwner();
        require(self.state == self.StateExpired, "Only from Expired state");
        if (self.buyerDeposited)  { self.buyerClaimable  = self.buyerDepositAmount;  }
        if (self.sellerDeposited) { self.sellerClaimable = self.sellerDepositAmount; }
        self._changeState(self.StateCancelled);
        self._checkAllWithdrawn();
    }

    // ========================================
    // Receiver: SellerConfirmDelivery (doc-hash flow)
    // ========================================
    // Seller uploads a document hash proving delivery. Sets sellerConfirmed.
    // Blocked after deadline if one is set.

    receive(msg: SellerConfirmDelivery) {
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

    // ========================================
    // Receiver: BuyerConfirmReceipt (doc-hash flow)
    // ========================================
    // Buyer re-submits the same hash the seller uploaded, proving both parties
    // hold the same document. Hash mismatch blocks release and protects against
    // spoofing. Triggers fund allocation on success.

    receive(msg: BuyerConfirmReceipt) {
        require(sender() == self.buyer,                          "Only buyer");
        require(self.state == self.StateAwaitingConfirmation,    "Not in confirmation state");
        require(!self.buyerConfirmed,                            "Already confirmed");
        require(self.sellerDocHash != 0,                        "Seller must confirm with doc hash first");
        require(msg.docHash == self.sellerDocHash,              "Document hash mismatch");

        self.buyerDocHash   = msg.docHash;
        self.buyerConfirmed = true;

        emit(EvtDocHashSubmitted{ tradeId: self.tradeId, isSeller: false, docHash: msg.docHash }.toCell());

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

    // ========================================
    // Receiver: CheckExpiry (permissionless)
    // ========================================
    // Anyone can call once the deadline has passed and the seller has not yet
    // confirmed. Transitions to EXPIRED, enabling CancelTrade or
    // RaiseDisputeWithClaim from either party.

    receive("CheckExpiry") {
        require(self.state == self.StateAwaitingConfirmation,  "Not in confirmation state");
        require(self.deadline > 0,                             "No deadline set for this vault");
        require(now() > self.deadline,                         "Deadline has not passed yet");
        require(!self.sellerConfirmed,                         "Seller already confirmed");

        self._changeState(self.StateExpired);
        emit(EvtDeadlinePassed{ tradeId: self.tradeId }.toCell());
    }

    // ========================================
    // Receiver: RaiseDisputeWithClaim
    // ========================================
    // Dispute with on-chain doc hash evidence — can be raised from
    // AWAITING_CONFIRMATION or EXPIRED. Creates an immutable record for DAO review.

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

    // ========================================
    // Receiver: CheckDisputeTimeout (permissionless backstop)
    // ========================================
    // Liveness guarantee: if a dispute is never resolved by the DAO and the parties
    // never mutually settle, anyone may trigger a 50/50 split once DisputeTimeoutWindow
    // has elapsed. No DAO fee is taken. Removes the only path to a permanent lock
    // (DAO unresponsive + a party refusing to settle). Seller gets the exact remainder
    // so the pool is fully conserved. Funds land in the pull-pattern claimables, so the
    // existing Withdraw + self-destruct path handles payout.

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
    // Internal helpers
    // ========================================

    fun _checkBothDeposited() {
        if (self.buyerDeposited && self.sellerDeposited) {
            self._changeState(self.StateAwaitingConfirmation);
        }
    }

    // ─── Internal: self-destruct once all claimables are zero ─────────────────
    //
    // Only fires in terminal states (SUCCESSFUL, RESOLVED, CANCELLED).
    // Guards against premature destruction during intermediate states where
    // claimables happen to be zero (e.g. before any deposits).
    //
    // On destruction: sweeps all remaining balance (gas residue from the
    // deploy buffer) back to the buyer, then self-destructs. The contract
    // ceases to exist on-chain — no further storage rent accrues.
    //
    // mode 128 (SendRemainingBalance) — forward entire remaining balance
    // mode  32 (SendDestroyIfZero)    — destroy contract after send
    fun _checkAllWithdrawn() {
        // NOTE: StateExpired is deliberately NOT terminal here. An expired vault
        // still holds both deposits (claimables are 0 until a Cancel path moves
        // them), so treating Expired as terminal could self-destruct a vault with
        // funds inside. Legitimate expired exits transition to Cancelled first.
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

    get fun vaultState(): VaultState {
        return VaultState{
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
            disputeDocHash:           self.disputeDocHash
        };
    }

    get fun tradeState(): Int {
        return self.state;
    }

    get fun totalPool(): Int {
        return self.buyerDepositAmount + self.sellerDepositAmount;
    }

    get fun requiredBuyerDeposit(): Int {
        return self.buyerDepositAmount;
    }

    get fun requiredSellerDeposit(): Int {
        return self.sellerDepositAmount;
    }

    // Pending dispute-settlement proposal — frontend shows the offered split
    // and which party still needs to approve.
    get fun settleProposed(): Bool    { return self.settleProposed; }
    get fun settleBuyerPct(): Int     { return self.settleBuyerPct; }
    get fun settleProposer(): Address { return self.settleProposer; }

    // Dispute backstop deadline — 0 unless DISPUTED. After this timestamp anyone may
    // call CheckDisputeTimeout to force a 50/50 split. Frontend shows the countdown.
    get fun disputeDeadline(): Int    { return self.disputeDeadline; }
}
