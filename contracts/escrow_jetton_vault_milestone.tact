import "@stdlib/deploy";

// ============================================================
// EscrowJettonVaultMilestone (V2) — jetton (USDT) milestone escrow
// ============================================================
//
// Mirrors EscrowVaultMilestone (V1) state machine VERBATIM — 2 milestones,
// performance bond, referrer fee, disputes, mutual settlement, timeouts,
// mutual cancel — and only swaps the value layer to jettons:
//   • Deposits arrive as TEP-74 transfer_notification from the vault's OWN
//     jetton wallet, routed by sender (seller → bond, buyer → payment).
//   • Payouts/refunds are jetton transfers through that wallet.
//   • The vault discovers its jetton wallet via ProvideWalletAddress.
//
// Differences from V1 (documented):
//   • All trade amounts (m0/m1 value, bond, referrer fee) are in the jetton's
//     minimal units (USDT = 6 dp), not TON.
//   • The per-dispute arbitratorFee is now a buyer-prefunded JETTON amount
//     (`disputeFee`, bps of totalValue set by the factory). V1 paid it from the
//     vault's spare TON, which has no jetton equivalent; the first port dropped
//     it outright, which silently left milestone arbitration uncompensated —
//     on the most labour-intensive product the council handles. It is charged
//     ONCE, only if a dispute is actually arbitrated, and refunded to the buyer
//     at close otherwise.
//
// CRITICAL invariants (same as escrow_jetton_vault):
//   1. A deposit notification is credited iff sender() == myJettonWallet && jwResolved.
//   2. myJettonWallet is set ONLY from a TakeWalletAddress sent by jettonMaster.
//   3. Once real jettons are held, an invalid deposit is REFUNDED, never reverted.
// ============================================================

// ─── TEP-74 / TEP-89 standard jetton messages ────────────────────────────────

message(0x0f8a7ea5) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(0x7362d09c) JettonTransferNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
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
    ownerAddress: Slice as remaining;
}

message(0xd53276db) JettonExcesses {
    queryId: Int as uint64;
}

// ─── Milestone control messages (V1 ops, minus DepositBond/DepositPayment) ────

message InitMilestoneVault {
    tradeId:            Int as uint64;
    buyer:              Address;
    seller:             Address;
    creator:            Address;   // paid the create fee + gas budget
    arbitrator:         Address;
    referrer:           Address;
    referrerFeeBps:     Int as uint16;
    milestoneCount:     Int as uint8;
    jettonMaster:       Address;          // the asset this vault escrows
    m0Value:            Int as coins;     // jetton minimal units
    m1Value:            Int as coins;
    m0Window:           Int as uint32;
    m1Window:           Int as uint32;
    m0DeliveryWindow:   Int as uint32;
    m1DeliveryWindow:   Int as uint32;
    performanceBond:    Int as coins;
    tradeRef:           String;
    disputeFeeBps:      Int as uint16;   // bps of totalValue; buyer prefunds it
}

message(0x3007) MilestoneVaultInitOk {
    tradeId: Int as uint64;
}

message SellerConfirmMilestone {
    index:   Int as uint8;
    docHash: Int as uint256;
}

message BuyerConfirmMilestone {
    index: Int as uint8;
}

message BuyerDisputeMilestone {
    index:  Int as uint8;
    reason: String;
}

message ArbitratorResolveMilestone {
    index:           Int as uint8;
    releaseToSeller: Bool;
}

message(0x4B01) BuyerClaimAbandoned {
    index: Int as uint8;
}

message(0x4B02) MutualCancelMilestone {
    index: Int as uint8;
}

message(0x4B03) ProposeMilestoneSettlement {
    index:    Int as uint8;
    buyerPct: Int as uint8;
}

message(0xE008) EvtJettonWalletResolved {
    tradeId:      Int as uint64;
    jettonWallet: Address;
}

contract EscrowJettonVaultMilestone with Deployable {

    const DisputeTimeoutWindow: Int = 2592000; // 30 days
    const PreActivationTimeoutWindow: Int = 604800; // 7 days

    // Grace period between closing and actually self-destructing — see
    // _sweepAndDestroy. Keeps a late in-flight jetton deposit refundable instead
    // of stranding it in our jetton wallet with no owner left to move it.
    const DestroyGraceWindow: Int = 3600; // 1 hour
    // Tested only against a lightweight mock wallet in sandbox — real jetton
    // wallets (incl. mainnet USDT) may cost more; margin here plus the
    // permissionless gas-rescue receive() are the safety net if it doesn't.
    const JettonFwdGas: Int = ton("0.15");
    const WalletDiscoveryGas: Int = ton("0.05");

    factory:            Address;
    tradeId:            Int as uint64;

    buyer:              Address;
    seller:             Address;
    // Whoever sent CreateJettonMilestoneEscrow and therefore funded this vault's
    // TON gas budget. Usually the buyer, but not necessarily — the residual gas
    // sweep must return to whoever actually paid it.
    creator:            Address;
    arbitrator:         Address;
    referrer:           Address;
    referrerFeeBps:     Int as uint16;

    totalValue:         Int as coins;
    performanceBond:    Int as coins;
    referrerFee:        Int as coins;
    referrerPaid:       Bool;

    // Arbitration fee, prefunded by the buyer in jettons alongside the payment.
    // Paid to the arbitrator ONCE, on the first arbitrated milestone dispute;
    // refunded to the buyer at close if arbitration never happened. Mirrors the
    // referrerFee lifecycle exactly (prefund → conditional payout → refund on
    // close), which is why it reuses that proven shape rather than a new one.
    disputeFee:         Int as coins;
    disputeFeePaid:     Bool;

    milestoneCount:     Int as uint8;
    m0Value:            Int as coins;
    m1Value:            Int as coins;
    m0Window:           Int as uint32;
    m1Window:           Int as uint32;
    m0DeliveryWindow:   Int as uint32;
    m1DeliveryWindow:   Int as uint32;
    tradeRef:           String;

    m0State:            Int as uint8;
    m1State:            Int as uint8;
    m0DocHash:          Int as uint256;
    m1DocHash:          Int as uint256;
    m0Deadline:         Int as uint32;
    m1Deadline:         Int as uint32;
    m0DeliveryDeadline: Int as uint32;
    m1DeliveryDeadline: Int as uint32;
    m0DisputeDeadline:  Int as uint32;
    m1DisputeDeadline:  Int as uint32;

    sellerBonded:       Bool;
    buyerFunded:        Bool;
    activeMilestone:    Int as uint8;
    vaultState:         Int as uint8;
    createdAt:          Int as uint32;
    // Unix time this vault first closed (vaultState → 2); 0 while still open.
    // Gates self-destruct via DestroyGraceWindow.
    closedAt:           Int as uint32;

    // Pending jetton payout tracking (M-1 fix): each outbound payout gets a
    // unique queryId; bounced() restores the recipient's claimable state.
    withdrawNonce:       Int as uint64;
    pendingPayoutAddr:   map<Int, Address>;      // qid → recipient
    pendingPayoutAmount: map<Int, Int as coins>;  // qid → amount
    failedPayout:        map<Address, Int as coins>; // recipient → accumulated bounced amount

    // V2-N1 fix: _sweepAndDestroy must not destroy the vault while either is
    // non-zero (relative to lastPayoutAt for inFlightPayouts — see
    // _sweepAndDestroy). inFlightPayouts covers a send that hasn't resolved
    // yet; failedPayoutCount covers a recipient whose ClaimFailedPayout retry
    // would otherwise have no contract left to run against. inFlightPayouts is
    // decremented by bounced() (TVM-authenticated) — not trusted from
    // JettonExcesses, which per TEP-74 is sent by the RECIPIENT's own jetton
    // wallet, an address this contract can't cheaply verify; treating it as
    // confirmation would let a forger guessing the next sequential queryId
    // suppress a genuine later bounce-restore.
    inFlightPayouts:    Int as uint16;
    failedPayoutCount:  Int as uint16;
    // Timestamp of the most recent tracked send — see _sweepAndDestroy.
    lastPayoutAt:       Int as uint32;

    m0CancelBuyer:      Bool;
    m0CancelSeller:     Bool;
    m1CancelBuyer:      Bool;
    m1CancelSeller:     Bool;

    m0SettleProposed:   Bool;
    m0SettleBuyerPct:   Int as uint8;
    m0SettleProposer:   Address;
    m1SettleProposed:   Bool;
    m1SettleBuyerPct:   Int as uint8;
    m1SettleProposer:   Address;

    // V2: jetton asset + discovered wallet
    jettonMaster:       Address;
    myJettonWallet:     Address;
    jwResolved:         Bool;

    init(factory: Address, tradeId: Int) {
        self.factory            = factory;
        self.tradeId            = tradeId;
        self.buyer              = newAddress(0, 0);
        self.seller             = newAddress(0, 0);
        self.creator            = newAddress(0, 0);
        self.arbitrator         = newAddress(0, 0);
        self.referrer           = newAddress(0, 0);
        self.referrerFeeBps     = 0;
        self.totalValue         = 0;
        self.performanceBond    = 0;
        self.referrerFee        = 0;
        self.referrerPaid       = false;
        self.disputeFee         = 0;
        self.disputeFeePaid     = false;
        self.milestoneCount     = 0;
        self.m0Value            = 0;
        self.m1Value            = 0;
        self.m0Window           = 0;
        self.m1Window           = 0;
        self.m0DeliveryWindow   = 0;
        self.m1DeliveryWindow   = 0;
        self.tradeRef           = "";
        self.m0State            = 0;
        self.m1State            = 0;
        self.m0DocHash          = 0;
        self.m1DocHash          = 0;
        self.m0Deadline         = 0;
        self.m1Deadline         = 0;
        self.m0DeliveryDeadline = 0;
        self.m1DeliveryDeadline = 0;
        self.m0DisputeDeadline  = 0;
        self.m1DisputeDeadline  = 0;
        self.sellerBonded       = false;
        self.buyerFunded        = false;
        self.activeMilestone    = 0;
        self.vaultState         = 0;
        self.createdAt          = now();
        self.closedAt           = 0;
        self.withdrawNonce      = 0;
        self.inFlightPayouts    = 0;
        self.failedPayoutCount  = 0;
        self.lastPayoutAt       = 0;
        self.m0CancelBuyer      = false;
        self.m0CancelSeller     = false;
        self.m1CancelBuyer      = false;
        self.m1CancelSeller     = false;
        self.m0SettleProposed   = false;
        self.m0SettleBuyerPct   = 0;
        self.m0SettleProposer   = newAddress(0, 0);
        self.m1SettleProposed   = false;
        self.m1SettleBuyerPct   = 0;
        self.m1SettleProposer   = newAddress(0, 0);
        self.jettonMaster       = newAddress(0, 0);
        self.myJettonWallet     = newAddress(0, 0);
        self.jwResolved         = false;
    }

    // ─── Factory funds and configures the vault ────────────────────────────────
    receive(msg: InitMilestoneVault) {
        require(sender() == self.factory,                "Only factory can init");
        require(self.vaultState == 0,                    "Already initialised");
        require(msg.milestoneCount == 2,                 "Exactly 2 milestones required");
        require(msg.m0Value > 0,                         "M0 value must be positive");
        require(msg.m1Value > 0,                         "M1 value must be positive");
        require(msg.m0Window >= 3600,                    "M0 review window minimum 1 hour");
        require(msg.m1Window >= 3600,                    "M1 review window minimum 1 hour");
        require(msg.m0DeliveryWindow >= 3600,            "M0 delivery window minimum 1 hour");
        require(msg.m1DeliveryWindow >= 3600,            "M1 delivery window minimum 1 hour");
        require(msg.buyer != msg.seller,                 "Buyer and seller must differ");
        require(msg.arbitrator != msg.buyer,             "Arbitrator cannot be buyer");
        require(msg.arbitrator != msg.seller,            "Arbitrator cannot be seller");
        require(msg.referrerFeeBps <= 1000,              "Referrer fee exceeds 10%");
        require(msg.referrerFeeBps == 0 || (msg.referrer != msg.buyer && msg.referrer != msg.seller), "Referrer cannot be a trade party");

        let total: Int = msg.m0Value + msg.m1Value;
        self.buyer              = msg.buyer;
        self.seller             = msg.seller;
        self.referrerFee        = total * msg.referrerFeeBps / 10000;
        self.disputeFee         = total * msg.disputeFeeBps / 10000;
        self.creator            = msg.creator;
        self.arbitrator         = msg.arbitrator;
        self.referrer           = msg.referrer;
        self.referrerFeeBps     = msg.referrerFeeBps;
        self.totalValue         = total;
        self.performanceBond    = msg.performanceBond;
        // L-2: a zero bond means no seller deposit is required — auto-credit it.
        if (self.performanceBond == 0) { self.sellerBonded = true; }
        self.milestoneCount     = msg.milestoneCount;
        self.m0Value            = msg.m0Value;
        self.m1Value            = msg.m1Value;
        self.m0Window           = msg.m0Window;
        self.m1Window           = msg.m1Window;
        self.m0DeliveryWindow   = msg.m0DeliveryWindow;
        self.m1DeliveryWindow   = msg.m1DeliveryWindow;
        self.tradeRef           = msg.tradeRef;
        self.jettonMaster       = msg.jettonMaster;

        send(SendParameters{
            to: self.factory,
            value: ton("0.05"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: MilestoneVaultInitOk{ tradeId: msg.tradeId }.toCell()
        });

        // Discover our jetton wallet from the (whitelisted) master.
        self._requestJettonWallet();
    }

    receive(msg: TakeWalletAddress) {
        require(sender() == self.jettonMaster, "Only jetton master may resolve wallet");
        require(!self.jwResolved,              "Wallet already resolved");
        self.myJettonWallet = msg.walletAddress;
        self.jwResolved = true;
        emit(EvtJettonWalletResolved{ tradeId: self.tradeId, jettonWallet: msg.walletAddress }.toCell());
    }

    // L-1: permissionless retry if the initial discovery message was lost.
    receive("RetryWalletDiscovery") {
        require(!self.jwResolved, "Wallet already resolved");
        // V2-N3: caller pays for their own retry instead of draining the vault's
        // fixed WalletDiscoveryGas budget for free.
        require(context().value >= self.WalletDiscoveryGas, "Send at least WalletDiscoveryGas");
        self._requestJettonWallet();
    }

    // ─── Gas top-up (rescue) ───────────────────────────────────────────────────
    // Permissionless: accept a plain empty-body TON transfer so anyone can refill
    // the vault's gas if the fixed deployment budget is ever exhausted by a long,
    // dispute-heavy lifecycle. Without this, a depleted vault could fail a payout
    // send AFTER state was advanced, stranding jettons. Accepting TON is harmless.
    receive() {}

    // ─── Deposit — TEP-74 notification from OUR jetton wallet ──────────────────
    // Routed by sender: seller → bond, buyer → payment. Never throws once real
    // jettons are held — invalid deposits are refunded.
    receive(msg: JettonTransferNotification) {
        // Reject hard rather than refund: forging a notification is cheap, and
        // refunding one would burn JettonFwdGas each time — a few forgeries would
        // drain our fixed TON budget and block real payouts.
        //
        // Accepted trade-off: this also rejects a GENUINE transfer of a DIFFERENT
        // jetton, which is then stranded in our wallet for that jetton (we only
        // ever command myJettonWallet). Deliberate — the alternative, an
        // owner-only sweep of foreign wallets, would hand the DAO a jetton-moving
        // power over vault funds guarded by an address check that is itself
        // unsafe before jwResolved. See escrow_jetton_vault.tact and
        // V2_JETTON_ESCROW_DESIGN.md §6.3.
        require(self.jwResolved,                    "Jetton wallet not resolved yet");
        require(sender() == self.myJettonWallet,    "Not from our jetton wallet");

        let from: Address = msg.sender;
        let amt: Int = msg.amount;

        // Deposits only accepted before the vault is active and only once each.
        if (self.vaultState != 0 || self.totalValue <= 0) {
            self._sendJettons(from, amt);
            return;
        }

        if (from == self.seller) {
            if (self.sellerBonded) { self._sendJettons(from, amt); return; }
            if (amt < self.performanceBond) { self._sendJettons(from, amt); return; }
            if (amt > self.performanceBond) { self._sendJettons(from, amt - self.performanceBond); }
            self.sellerBonded = true;
            if (self.buyerFunded) { self.activateVault(); }
        } else if (from == self.buyer) {
            if (self.buyerFunded) { self._sendJettons(from, amt); return; }
            let required: Int = self.totalValue + self.referrerFee + self.disputeFee;
            if (amt < required) { self._sendJettons(from, amt); return; }
            if (amt > required) { self._sendJettons(from, amt - required); }
            self.buyerFunded = true;
            if (self.sellerBonded) { self.activateVault(); }
        } else {
            self._sendJettons(from, amt);
        }
    }

    // ─── Refund stranded pre-activation funding after timeout ──────────────────
    receive("RefundPreActivationStall") {
        require(self.vaultState == 0,                "Vault already active or closed");
        require(self.totalValue > 0,                 "Vault not initialised");
        require(now() > self.createdAt + self.PreActivationTimeoutWindow, "Pre-activation timeout not yet passed");

        let buyerRefund: Int = 0;
        let sellerRefund: Int = 0;
        if (self.buyerFunded)  { buyerRefund = self.totalValue + self.referrerFee + self.disputeFee; self.buyerFunded = false; }
        if (self.sellerBonded) { sellerRefund = self.performanceBond; self.sellerBonded = false; }
        // No "nothing funded" gate: a vault that never received a single deposit
        // (e.g. TakeWalletAddress never resolved, or both parties abandoned it) is
        // exactly the case this must still be able to close out and sweep its
        // stranded gas — not a case to revert on.

        self.vaultState = 2; // CLOSED
        self.closedAt   = now();
        if (buyerRefund > 0)  { self._sendJettons(self.buyer, buyerRefund); }
        if (sellerRefund > 0) { self._sendJettons(self.seller, sellerRefund); }
        self._sweepAndDestroy();
    }

    // ─── Seller confirms milestone delivery ────────────────────────────────────
    receive(msg: SellerConfirmMilestone) {
        require(sender() == self.seller,              "Only seller");
        require(self.vaultState == 1,                 "Vault not active");
        require(msg.index <= 1,                       "Invalid milestone index");
        require(msg.index == self.activeMilestone,    "Not the active milestone");
        require(msg.docHash != 0,                     "Document hash required");

        if (msg.index == 0) {
            require(self.m0State == 0,                "M0 not in pending state");
            self.m0State    = 1;
            self.m0DocHash  = msg.docHash;
            self.m0Deadline = now() + max(self.m0Window, 3600);
        } else {
            require(self.m1State == 0,                "M1 not in pending state");
            self.m1State    = 1;
            self.m1DocHash  = msg.docHash;
            self.m1Deadline = now() + max(self.m1Window, 3600);
        }
    }

    // ─── Buyer confirms milestone received ────────────────────────────────────
    receive(msg: BuyerConfirmMilestone) {
        require(sender() == self.buyer,    "Only buyer");
        require(self.vaultState == 1,      "Vault not active");
        require(msg.index <= 1,            "Invalid milestone index");
        if (msg.index == 0) {
            require(self.m0State == 1,     "M0 not in confirming state");
            self.m0State = 2;
            self.releaseMilestone0();
        } else {
            require(self.m1State == 1,     "M1 not in confirming state");
            self.m1State = 2;
            self.releaseMilestone1();
        }
    }

    // ─── Auto-release on review timeout (permissionless) ───────────────────────
    receive("CheckTimeout") {
        require(self.vaultState == 1, "Vault not active");
        if (self.m0State == 1 && now() > self.m0Deadline) { self.m0State = 2; self.releaseMilestone0(); }
        if (self.m1State == 1 && now() > self.m1Deadline) { self.m1State = 2; self.releaseMilestone1(); }
        if (self.m0State == 3 && self.m0DisputeDeadline > 0 && now() > self.m0DisputeDeadline) { self.resolveDisputeTimeout(0); }
        if (self.m1State == 3 && self.m1DisputeDeadline > 0 && now() > self.m1DisputeDeadline) { self.resolveDisputeTimeout(1); }
    }

    // ─── Buyer raises dispute ──────────────────────────────────────────────────
    receive(msg: BuyerDisputeMilestone) {
        require(sender() == self.buyer,    "Only buyer");
        require(self.vaultState == 1,      "Vault not active");
        require(msg.index <= 1,            "Invalid milestone index");
        if (msg.index == 0) {
            require(self.m0State == 1,     "M0 not in confirming state");
            self.m0State = 3;
            self.activeMilestone   = 1;
            self.m0DisputeDeadline = now() + self.DisputeTimeoutWindow;
        } else {
            require(self.m1State == 1,     "M1 not in confirming state");
            self.m1State = 3;
            self.m1DisputeDeadline = now() + self.DisputeTimeoutWindow;
        }
    }

    // ─── Buyer reclaims if seller misses delivery deadline ─────────────────────
    receive(msg: BuyerClaimAbandoned) {
        require(sender() == self.buyer, "Only buyer");
        require(self.vaultState == 1,   "Vault not active");
        require(msg.index <= 1,         "Invalid milestone index");

        if (msg.index == 0) {
            require(self.m0State == 0,              "M0 is not pending");
            require(self.m0DeliveryDeadline > 0,    "Delivery deadline not set");
            require(now() > self.m0DeliveryDeadline,"Delivery deadline not yet passed");
            self.m0State = 2;
            self._sendJettons(self.buyer, self.m0Value);
            // Slash M0's proportional share of the bond — seller abandoned this
            // obligation but may still deliver M1, which keeps its own share as
            // collateral. Mirrors ArbitratorResolveMilestone's slash math.
            if (self.performanceBond > 0) {
                let m0BondSlash: Int = self.performanceBond * self.m0Value / self.totalValue;
                if (m0BondSlash > 0) { self._sendJettons(self.buyer, m0BondSlash); }
                self.performanceBond = self.performanceBond - m0BondSlash;
            }
            self.activeMilestone    = 1;
            self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
        } else {
            require(self.m1State == 0,              "M1 is not pending");
            require(self.m1DeliveryDeadline > 0,    "Delivery deadline not set");
            require(now() > self.m1DeliveryDeadline,"Delivery deadline not yet passed");
            self.m1State = 2;
            self._sendJettons(self.buyer, self.m1Value);
            if (self.performanceBond > 0) { self._sendJettons(self.buyer, self.performanceBond); self.performanceBond = 0; }
        }
        self.checkVaultClose();
    }

    // ─── Mutual cancel milestone ───────────────────────────────────────────────
    receive(msg: MutualCancelMilestone) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Only trade parties");
        require(self.vaultState == 1,                "Vault not active");
        require(msg.index <= 1,                      "Invalid milestone index");

        if (msg.index == 0) {
            require(self.m0State == 0 || self.m0State == 1, "M0 not in cancellable state");
            if (s == self.buyer) { self.m0CancelBuyer = !self.m0CancelBuyer; } else { self.m0CancelSeller = !self.m0CancelSeller; }
            if (self.m0CancelBuyer && self.m0CancelSeller) {
                self.m0State = 2;
                self._sendJettons(self.buyer, self.m0Value);
                if (self.activeMilestone == 0) { self.activeMilestone = 1; self.m1DeliveryDeadline = now() + self.m1DeliveryWindow; }
                self.checkVaultClose();
            }
        } else {
            require(self.m1State == 0 || self.m1State == 1, "M1 not in cancellable state");
            if (s == self.buyer) { self.m1CancelBuyer = !self.m1CancelBuyer; } else { self.m1CancelSeller = !self.m1CancelSeller; }
            if (self.m1CancelBuyer && self.m1CancelSeller) {
                self.m1State = 2;
                self._sendJettons(self.buyer, self.m1Value);
                self.checkVaultClose();
            }
        }
    }

    // ─── Mutual dispute settlement ─────────────────────────────────────────────
    receive(msg: ProposeMilestoneSettlement) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Only trade parties");
        require(self.vaultState == 1,                "Vault not active");
        require(msg.index <= 1,                      "Invalid milestone index");
        require(msg.buyerPct <= 100,                 "Percent must be 0-100");

        if (msg.index == 0) {
            require(self.m0State == 3, "M0 not in disputed state");
            if (self.m0SettleProposed && self.m0SettleProposer != s && self.m0SettleBuyerPct == msg.buyerPct) {
                self.executeMilestoneSettlement(0, msg.buyerPct);
            } else {
                self.m0SettleProposed = true; self.m0SettleBuyerPct = msg.buyerPct; self.m0SettleProposer = s;
            }
        } else {
            require(self.m1State == 3, "M1 not in disputed state");
            if (self.m1SettleProposed && self.m1SettleProposer != s && self.m1SettleBuyerPct == msg.buyerPct) {
                self.executeMilestoneSettlement(1, msg.buyerPct);
            } else {
                self.m1SettleProposed = true; self.m1SettleBuyerPct = msg.buyerPct; self.m1SettleProposer = s;
            }
        }
    }

    // ─── Arbitrator resolves dispute ───────────────────────────────────────────
    receive(msg: ArbitratorResolveMilestone) {
        require(sender() == self.arbitrator, "Only arbitrator");
        require(self.vaultState == 1,        "Vault not active");
        require(msg.index <= 1,              "Invalid milestone index"); // V2-N5
        // I-1: validate the milestone state BEFORE charging the fee, so a bad
        // index cannot consume the fee without actually resolving anything.
        if (msg.index == 0) {
            require(self.m0State == 3,       "M0 not in disputed state");
        } else {
            require(self.m1State == 3,       "M1 not in disputed state");
        }

        // Charge the buyer's prefunded arbitration fee — this is the only path
        // that consumes it. Once per vault, even if both milestones end up
        // arbitrated: it prices "this trade needed the council", not each ruling,
        // so a two-dispute trade can never cost the buyer more than they funded.
        if (!self.disputeFeePaid && self.disputeFee > 0) {
            self._sendJettons(self.arbitrator, self.disputeFee);
            self.disputeFeePaid = true;
        }

        if (msg.index == 0) {
            self.m0State = 2;
            self.m0DisputeDeadline = 0;
            if (msg.releaseToSeller) {
                self._sendJettons(self.seller, self.m0Value);
                self.payReferrer();
            } else {
                self._sendJettons(self.buyer, self.m0Value);
                if (self.performanceBond > 0) {
                    let m0BondSlash: Int = self.performanceBond * self.m0Value / self.totalValue;
                    if (m0BondSlash > 0) { self._sendJettons(self.buyer, m0BondSlash); }
                    self.performanceBond = self.performanceBond - m0BondSlash;
                }
            }
            if (self.m1State == 0 && self.m1DeliveryDeadline == 0) { self.m1DeliveryDeadline = now() + self.m1DeliveryWindow; }
        } else {
            self.m1State = 2;
            self.m1DisputeDeadline = 0;
            if (msg.releaseToSeller) {
                self._sendJettons(self.seller, self.m1Value);
                self.payReferrer();
            } else {
                self._sendJettons(self.buyer, self.m1Value);
                if (self.performanceBond > 0) { self._sendJettons(self.buyer, self.performanceBond); self.performanceBond = 0; }
            }
        }
        self.checkVaultClose();
    }

    // ─── Internal helpers ──────────────────────────────────────────────────────

    fun activateVault() {
        self.vaultState         = 1;
        self.activeMilestone    = 0;
        self.m0DeliveryDeadline = now() + self.m0DeliveryWindow;
    }

    fun releaseMilestone0() {
        self._sendJettons(self.seller, self.m0Value);
        self.payReferrer();
        self.activeMilestone    = 1;
        self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
        self.checkVaultClose();
    }

    fun releaseMilestone1() {
        self._sendJettons(self.seller, self.m1Value);
        self.payReferrer();
        self.checkVaultClose();
    }

    fun payReferrer() {
        if (!self.referrerPaid && self.referrerFee > 0) {
            self._sendJettons(self.referrer, self.referrerFee);
            self.referrerPaid = true;
        }
    }

    fun resolveDisputeTimeout(index: Int) {
        let buyerShare: Int = 0;
        let sellerShare: Int = 0;
        if (index == 0) {
            self.m0State = 2;
            self.m0DisputeDeadline = 0;
            buyerShare = self.m0Value / 2;
            sellerShare = self.m0Value - buyerShare;
            if (self.m1State == 0 && self.m1DeliveryDeadline == 0) { self.m1DeliveryDeadline = now() + self.m1DeliveryWindow; }
        } else {
            self.m1State = 2;
            self.m1DisputeDeadline = 0;
            buyerShare = self.m1Value / 2;
            sellerShare = self.m1Value - buyerShare;
        }
        if (buyerShare > 0)  { self._sendJettons(self.buyer, buyerShare); }
        if (sellerShare > 0) { self._sendJettons(self.seller, sellerShare); }
        self.payReferrer();
        self.checkVaultClose();
    }

    fun executeMilestoneSettlement(index: Int, buyerPct: Int) {
        let mValue: Int = self.m0Value;
        if (index != 0) { mValue = self.m1Value; }
        let buyerShare: Int  = mValue * buyerPct / 100;
        let sellerShare: Int = mValue - buyerShare;

        if (index == 0) { self.m0State = 2; self.m0DisputeDeadline = 0; }
        else            { self.m1State = 2; self.m1DisputeDeadline = 0; }

        if (buyerShare > 0)  { self._sendJettons(self.buyer, buyerShare); }
        if (sellerShare > 0) { self._sendJettons(self.seller, sellerShare); self.payReferrer(); }

        if (index == 0 && self.m1State == 0 && self.m1DeliveryDeadline == 0) { self.m1DeliveryDeadline = now() + self.m1DeliveryWindow; }
        self.checkVaultClose();
    }

    fun checkVaultClose() {
        if (self.vaultState == 2) { return; }
        if (self.m0State == 2 && self.m1State == 2) {
            self.vaultState = 2;
            self.closedAt   = now();
            if (self.performanceBond > 0) {
                self._sendJettons(self.seller, self.performanceBond);
                self.performanceBond = 0;
            }
            // If no milestone ever resolved in the seller's favour, payReferrer was
            // never called and the buyer's prepaid referrerFee is still held here.
            // Refund it to the buyer before self-destruct — otherwise those jettons
            // are stranded in the vault's wallet and lost by _sweepAndDestroy (which
            // only sweeps residual TON, not jettons).
            if (!self.referrerPaid && self.referrerFee > 0) {
                self._sendJettons(self.buyer, self.referrerFee);
                self.referrerPaid = true;
            }
            // Same for the arbitration fee: the buyer prefunded it, and if no
            // dispute was ever arbitrated the council did no work and it must go
            // back — otherwise it would be a silent surcharge on every clean
            // trade, and (like the referrerFee above) _sweepAndDestroy only
            // sweeps residual TON, so these jettons would be stranded.
            if (!self.disputeFeePaid && self.disputeFee > 0) {
                self._sendJettons(self.buyer, self.disputeFee);
                self.disputeFeePaid = true;
            }
            self._sweepAndDestroy();
        }
    }

    // Send `amount` jettons to `to` through our own jetton wallet.
    // Auto-generates a unique queryId so bounced() can recover a failed payout.
    fun _sendJettons(to: Address, amount: Int) {
        if (amount <= 0) { return; }
        self.withdrawNonce = self.withdrawNonce + 1;
        let qid: Int = self.withdrawNonce;
        self.pendingPayoutAddr.set(qid, to);
        self.pendingPayoutAmount.set(qid, amount);
        self.inFlightPayouts = self.inFlightPayouts + 1; // V2-N1: cleared by bounced(), time-bounded by lastPayoutAt
        self.lastPayoutAt = now();
        send(SendParameters{
            to:     self.myJettonWallet,
            value:  self.JettonFwdGas,
            mode:   SendPayGasSeparately,
            bounce: true,
            body:   JettonTransfer{
                queryId:             qid,
                amount:              amount,
                destination:         to,
                responseDestination: myAddress(),
                customPayload:       null,
                forwardTonAmount:    0,
                forwardPayload:      beginCell().storeUint(0, 1).endCell().asSlice()
            }.toCell()
        });
    }

    // Restore a payout that the jetton wallet bounced. Accumulates into
    // failedPayout[recipient] so the party can reclaim via ClaimFailedPayout.
    bounced(msg: bounced<JettonTransfer>) {
        let qid: Int = msg.queryId;
        if (!self.pendingPayoutAddr.exists(qid)) { return; }
        let to: Address  = self.pendingPayoutAddr.get(qid)!!;
        let amt: Int     = self.pendingPayoutAmount.get(qid)!!;
        self.pendingPayoutAddr.del(qid);
        self.pendingPayoutAmount.del(qid);
        self.inFlightPayouts = self.inFlightPayouts - 1; // V2-N1
        let prior: Int = 0;
        let isNewEntry: Bool = !self.failedPayout.exists(to);
        if (!isNewEntry) { prior = self.failedPayout.get(to)!!; }
        self.failedPayout.set(to, prior + amt);
        if (isNewEntry) { self.failedPayoutCount = self.failedPayoutCount + 1; } // V2-N1
    }

    // Best-effort cleanup only — NOT relied on for correctness. Per TEP-74,
    // `excesses` is sent by the RECIPIENT's own jetton wallet, not
    // self.myJettonWallet, so the check below means this in practice only
    // matches the narrow case where that happens to coincide. Real resolution
    // is time-based (lastPayoutAt, see _sweepAndDestroy) plus bounced().
    receive(msg: JettonExcesses) {
        if (sender() != self.myJettonWallet) { return; }
        if (!self.pendingPayoutAddr.exists(msg.queryId)) { return; }
        self.pendingPayoutAddr.del(msg.queryId);
        self.pendingPayoutAmount.del(msg.queryId);
        self.inFlightPayouts = self.inFlightPayouts - 1; // V2-N1
        // A confirmed payout may be the one _sweepAndDestroy was waiting on —
        // give the close another chance now instead of relying only on Reap.
        if (self.vaultState == 2) { self._sweepAndDestroy(); }
    }

    // Permissionless retry for a recipient whose payout previously bounced.
    receive("ClaimFailedPayout") {
        let s: Address = sender();
        require(self.failedPayout.exists(s) && self.failedPayout.get(s)!! > 0, "No failed payout to claim");
        let amt: Int = self.failedPayout.get(s)!!;
        self.failedPayout.del(s);
        self.failedPayoutCount = self.failedPayoutCount - 1; // V2-N1
        self._sendJettons(s, amt);
    }

    fun _requestJettonWallet() {
        send(SendParameters{
            to:     self.jettonMaster,
            value:  self.WalletDiscoveryGas,
            mode:   SendPayGasSeparately,
            bounce: false,
            body:   ProvideWalletAddress{ queryId: 0, ownerAddress: myAddress(), includeAddress: false }.toCell()
        });
    }

    // Jettons are already distributed by the time we close — sweep residual TON
    // gas to the buyer and self-destruct.
    //
    // Deferred by DestroyGraceWindow: a jetton deposit reaches us over several
    // hops, so one can still be in flight as we close. Destroying immediately
    // would leave it in our jetton wallet — a SEPARATE contract that outlives us
    // and takes orders from nobody else — stranding it permanently. Staying
    // alive through the window lets the deposit handler refund it instead.
    // Nothing is withheld by waiting; only the leftover gas sweep is delayed.
    // `Reap` completes it afterwards.
    fun _sweepAndDestroy() {
        // V2-N1: never destroy in the same transaction that just queued a
        // payout send. Bounded by lastPayoutAt, not held open indefinitely — a
        // real failure bounces back promptly, so once DestroyGraceWindow has
        // passed since the last send with no bounce, it's safe to treat it as
        // settled (see the JettonExcesses receiver above).
        if (self.inFlightPayouts > 0 && now() < self.lastPayoutAt + self.DestroyGraceWindow) { return; }
        // Unlike inFlightPayouts, failedPayoutCount stays an indefinite gate —
        // a bounce already confirmed via bounced() that this money is owed;
        // only ClaimFailedPayout should ever release it.
        if (self.failedPayoutCount > 0) { return; }
        if (self.closedAt != 0 && now() < self.closedAt + self.DestroyGraceWindow) {
            return; // still inside the grace window — a late deposit can arrive
        }
        send(SendParameters{
            // To the CREATOR, not the buyer: they funded the gas budget via
            // CreateJettonMilestoneEscrow, so the unspent remainder is their
            // prepayment returning. Usually the buyer, but need not be.
            to:    self.creator,
            value: 0,
            mode:  SendRemainingBalance + SendDestroyIfZero,
            bounce: false
        });
    }

    // Permissionless: perform the destroy the grace window deferred, reclaiming
    // residual gas. Only acts on a CLOSED vault past the window, so it grants no
    // privilege; called too early it simply does nothing.
    receive("Reap") {
        require(self.vaultState == 2, "Vault not closed");
        self._sweepAndDestroy();
    }

    // ─── Getters (V1 + jetton) ─────────────────────────────────────────────────
    get fun vaultState(): Int          { return self.vaultState;         }
    get fun activeMilestone(): Int     { return self.activeMilestone;    }
    get fun m0State(): Int             { return self.m0State;            }
    get fun m1State(): Int             { return self.m1State;            }
    get fun m0DocHash(): Int           { return self.m0DocHash;          }
    get fun m1DocHash(): Int           { return self.m1DocHash;          }
    get fun totalValue(): Int          { return self.totalValue;         }
    get fun performanceBond(): Int     { return self.performanceBond;    }
    get fun sellerBonded(): Bool       { return self.sellerBonded;       }
    get fun buyerFunded(): Bool        { return self.buyerFunded;        }
    get fun tradeRef(): String         { return self.tradeRef;           }
    get fun factoryAddress(): Address  { return self.factory;            }
    get fun tradeIdNum(): Int          { return self.tradeId;            }
    get fun m0Value(): Int             { return self.m0Value;            }
    get fun m1Value(): Int             { return self.m1Value;            }
    get fun m0Deadline(): Int          { return self.m0Deadline;         }
    get fun m1Deadline(): Int          { return self.m1Deadline;         }
    get fun m0DeliveryDeadline(): Int  { return self.m0DeliveryDeadline; }
    get fun m1DeliveryDeadline(): Int  { return self.m1DeliveryDeadline; }
    get fun m0DisputeDeadline(): Int   { return self.m0DisputeDeadline;  }
    get fun m1DisputeDeadline(): Int   { return self.m1DisputeDeadline;  }
    get fun referrer(): Address    { return self.referrer;       }
    get fun arbitrator(): Address  { return self.arbitrator;     }
    get fun buyer(): Address       { return self.buyer;          }
    get fun seller(): Address      { return self.seller;         }
    get fun referrerFee(): Int     { return self.referrerFee;    }
    get fun referrerPaid(): Bool   { return self.referrerPaid;   }
    get fun referrerFeeBps(): Int  { return self.referrerFeeBps; }
    get fun jettonMasterAddr(): Address { return self.jettonMaster;   }
    // 0 until the vault closes; afterwards, the time it did. A reaper can call
    // "Reap" once now() >= closedAt + 3600 to reclaim the residual gas.
    // Prefunded arbitration fee and whether it's been consumed. Exposed so the UI
    // can show the buyer what they funded and whether it's refundable.
    get fun disputeFee(): Int           { return self.disputeFee;     }
    get fun disputeFeePaid(): Bool      { return self.disputeFeePaid; }
    get fun closedAt(): Int             { return self.closedAt;       }
    get fun jettonWallet(): Address     { return self.myJettonWallet; }
    get fun walletResolved(): Bool      { return self.jwResolved;     }
}
