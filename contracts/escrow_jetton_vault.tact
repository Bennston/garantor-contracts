import "@stdlib/ownable";

// ============================================================
// EscrowJettonVault (V2) — jetton-bearing escrow
// ============================================================
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
    creator: Address;                   // whoever paid the create fee + gas budget
    owner: Address;                     // DAO arbitrator (factory's owner); becomes vault.owner
    jettonMaster: Address;              // the asset this vault escrows
    tradeValue: Int as coins;          // in jetton minimal units
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    commissionairesDao: Address;
    tradeId: Int as uint64;
    deadline: Int as uint32;
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

contract EscrowJettonVault with Ownable {

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

    // Grace period between reaching a fully-settled terminal state and actually
    // self-destructing. See _checkAllWithdrawn — this exists to stop the vault
    // vanishing while a jetton deposit is still in flight to its jetton wallet.
    const DestroyGraceWindow: Int = 3600; // 1 hour

    // === Jetton gas constants ===
    // TON attached to an outbound jetton transfer (paid separately from balance).
    // Tested only against a lightweight mock wallet in sandbox — real jetton
    // wallets (incl. mainnet USDT) may cost more; margin here plus the
    // permissionless gas-rescue receive() are the safety net if it doesn't.
    const JettonFwdGas: Int = ton("0.15");
    // TON attached to the wallet-discovery request to the master.
    const WalletDiscoveryGas: Int = ton("0.05");

    owner: Address;

    state: Int as uint8;
    tradeId: Int as uint64;

    buyer: Address;
    seller: Address;
    // Whoever sent CreateJettonEscrow and therefore funded the vault's TON gas
    // budget. Not necessarily the buyer — the residual gas sweep must go back to
    // the party who actually paid it.
    creator: Address;
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

    // Unix time this vault first entered a terminal state (0 = not terminal yet).
    // Gates self-destruct via DestroyGraceWindow.
    terminalAt: Int as uint32;

    // Pending jetton payout tracking (M-1 fix): each Withdraw gets a unique
    // queryId; the pending maps let bounced() restore claimable if the send fails.
    withdrawNonce: Int as uint64;
    pendingPayoutType:   map<Int, Int as uint8>;    // qid → 1=buyer 2=seller 3=comm
    pendingPayoutAmount: map<Int, Int as coins>;    // qid → amount

    // === V2: jetton asset + discovered wallet ===
    jettonMaster:   Address;
    myJettonWallet: Address;
    jwResolved:     Bool;

    init(factory: Address, seqno: Int) {
        self.owner = newAddress(0, 0);
        self.factory = factory;
        self.state = self.StateCreated;
        self.tradeId = 0;

        self.buyer = newAddress(0, 0);
        self.seller = newAddress(0, 0);
        self.creator = newAddress(0, 0);   // placeholder; set by InitVault
        self.commissionairesDao = newAddress(0, 0);
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
        self.settleProposer = newAddress(0, 0);

        self.disputeDeadline = 0;
        self.terminalAt      = 0;
        self.withdrawNonce   = 0;

        self.jettonMaster   = newAddress(0, 0);   // placeholder; set by InitVault
        self.myJettonWallet = newAddress(0, 0);   // placeholder; set by TakeWalletAddress
        self.jwResolved     = false;
    }

    // ========================================
    // InitVault — from factory, once. Also kicks off jetton-wallet discovery.
    // ========================================

    // Gas top-up (rescue): permissionless, accept a plain empty-body TON transfer
    // so anyone can refill the vault's gas if the fixed deployment budget is ever
    // exhausted (e.g. repeated wrong-sender deposit refunds, each costing
    // JettonFwdGas). Without this, a depleted vault could fail a payout send
    // after state already advanced, stranding jettons with no recovery path.
    // Mirrors EscrowJettonVaultMilestone's identical rescue receiver.
    receive() {}

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
        self.creator = msg.creator;
        self.tradeValue = msg.tradeValue;
        self.guaranteePercent = msg.guaranteePercent;
        self.commissionPercent = msg.commissionPercent;
        self.commissionairesDao = msg.commissionairesDao;
        self.owner = msg.owner;
        self.tradeId = msg.tradeId;
        self.jettonMaster = msg.jettonMaster;

        self.buyerDepositAmount = msg.tradeValue;
        self.sellerDepositAmount = msg.tradeValue * msg.guaranteePercent / 100;
        // L-2: if the computed guarantee rounds to zero, auto-credit the deposit
        // so the vault doesn't stall waiting for a zero transfer.
        if (self.sellerDepositAmount == 0) { self.sellerDeposited = true; }
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

    // L-1: if TakeWalletAddress is never delivered (e.g. master was busy at deploy
    // time), the UI or backend can retry discovery without a DAO intervention.
    receive("RetryWalletDiscovery") {
        require(!self.jwResolved, "Wallet already resolved");
        self._requestJettonWallet();
    }

    // ========================================
    // Deposit — TEP-74 transfer notification from OUR jetton wallet.
    // ========================================
    // Once we hold real jettons we MUST NOT throw — an invalid deposit is
    // refunded to the sender instead, so jettons can never be trapped.

    receive(msg: JettonTransferNotification) {
        // Reject hard rather than refund. Anyone can cheaply forge a
        // notification, and refunding one would cost us JettonFwdGas each time —
        // a handful of forgeries would drain the vault's fixed TON budget and
        // block real payouts. Throwing costs the forger and costs us nothing.
        //
        // Accepted trade-off: this also rejects a GENUINE transfer of some OTHER
        // jetton (someone sending, say, USDC to a USDT vault). Those coins are
        // already sitting in this vault's wallet for that jetton, and we never
        // command that wallet — `_sendJettons` only ever addresses
        // myJettonWallet — so they are stranded permanently. Deliberate: the
        // alternative (an owner-only sweep of foreign wallets) hands the DAO a
        // jetton-moving power over vault funds, guarded only by an address
        // comparison that is itself unsafe before jwResolved. Keeping the vault
        // unable to move anything but its one escrowed asset is worth more than
        // recovering mis-sent tokens. The UI only ever builds transfers of the
        // configured jetton; see V2_JETTON_ESCROW_DESIGN.md §6.3.
        require(self.jwResolved, "Jetton wallet not resolved yet");
        require(sender() == self.myJettonWallet, "Not from our jetton wallet");

        let from: Address = msg.sender;
        let amt: Int = msg.amount;

        // Wrong phase → refund the whole amount.
        if (self.state != self.StateAwaitingDeposits) {
            self._sendJettons(from, amt, 0);
            return;
        }

        if (from == self.buyer) {
            if (self.buyerDeposited) { self._sendJettons(from, amt, 0); return; }
            let required: Int = self.buyerDepositAmount;
            if (amt < required) { self._sendJettons(from, amt, 0); return; }
            if (amt > required) { self._sendJettons(from, amt - required, 0); }
            self.buyerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.buyer, amount: required, isBuyer: true }.toCell());
            self._checkBothDeposited();
        } else if (from == self.seller) {
            if (self.sellerDeposited) { self._sendJettons(from, amt, 0); return; }
            let required: Int = self.sellerDepositAmount;
            if (amt < required) { self._sendJettons(from, amt, 0); return; }
            if (amt > required) { self._sendJettons(from, amt - required, 0); }
            self.sellerDeposited = true;
            emit(EvtDeposit{ tradeId: self.tradeId, depositor: self.seller, amount: required, isBuyer: false }.toCell());
            self._checkBothDeposited();
        } else {
            // Not a trade party → refund.
            self._sendJettons(from, amt, 0);
        }
    }

    // ========================================
    // ConfirmTrade (two-phase) — identical to V1
    // ========================================

    receive(msg: ConfirmTrade) {
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
        if (partyType == 1)      { self.buyerClaimable           = self.buyerClaimable           + amt; }
        else if (partyType == 2) { self.sellerClaimable          = self.sellerClaimable          + amt; }
        else                     { self.commissionairesClaimable = self.commissionairesClaimable + amt; }
    }

    // Clean up the pending-payout entry once the jetton wallet confirms delivery.
    // Only accepted from our own jetton wallet — a forged JettonExcesses cannot
    // delete a real pending entry and thereby block bounced() from restoring.
    receive(msg: JettonExcesses) {
        if (sender() != self.myJettonWallet) { return; }
        self.pendingPayoutType.del(msg.queryId);
        self.pendingPayoutAmount.del(msg.queryId);
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

    // Permissionless: perform the destroy that _checkAllWithdrawn deferred during
    // the grace window, reclaiming the vault's leftover gas. Anyone may call it
    // (either party, or a backend cron) — it can only act in a terminal state
    // with every claimable already at zero, so it grants no privilege and cannot
    // take anything from anyone. A call made too early simply does nothing.
    receive("Reap") {
        self._checkAllWithdrawn();
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
    fun _sendJettons(to: Address, amount: Int, queryId: Int) {
        if (amount <= 0) { return; }
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

    // Self-destruct once all claimables are zero in a terminal state AND the
    // grace window has elapsed. Withdraw's jetton transfers drain the jetton
    // wallet, so by then only residual TON gas remains — sweep it to the buyer
    // and destroy.
    //
    // Why the grace window: destroying is irreversible and, unlike V1, unsafe to
    // do eagerly. A jetton deposit reaches us over several hops (depositor →
    // their jetton wallet → OUR jetton wallet → notification to us), so one can
    // be in flight when the vault settles. V1 was safe here: its deposits are
    // bounceable TON messages to the vault itself, which a dead vault bounces
    // straight back. V2's jettons instead land in our jetton wallet — a SEPARATE
    // contract that outlives us — and only we can order it to pay out. Destroy
    // early and those jettons are stranded permanently.
    //
    // The window keeps the vault alive long enough to receive such a late
    // deposit and refund it (the wrong-phase branch of the notification
    // handler). Nothing is claimable during it, so nothing is withheld; only
    // reclaiming the leftover gas is deferred. `Reap` performs the delayed
    // destroy — the settling call itself is always inside the window.
    fun _checkAllWithdrawn() {
        let terminal: Bool =
            self.state == self.StateSuccessful ||
            self.state == self.StateResolved   ||
            self.state == self.StateCancelled;
        if (!terminal) { return; }

        if (self.buyerClaimable           == 0 &&
            self.sellerClaimable          == 0 &&
            self.commissionairesClaimable == 0) {
            if (self.terminalAt != 0 && now() < self.terminalAt + self.DestroyGraceWindow) {
                return; // still inside the grace window — a late deposit can arrive
            }
            send(SendParameters{
                // To the CREATOR, not the buyer: the creator paid the gas budget
                // via CreateJettonEscrow, and unspent gas is their prepayment
                // coming back. They are usually the buyer, but need not be.
                to:    self.creator,
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

    // 0 until the vault settles; afterwards, the time it did. A reaper can call
    // "Reap" once now() >= terminalAt + 3600 to reclaim the residual gas.
    get fun terminalAt(): Int         { return self.terminalAt; }

    get fun settleProposed(): Bool    { return self.settleProposed; }
    get fun settleBuyerPct(): Int     { return self.settleBuyerPct; }
    get fun settleProposer(): Address { return self.settleProposer; }
    get fun disputeDeadline(): Int    { return self.disputeDeadline; }
}
