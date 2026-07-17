import "@stdlib/deploy";

// ─── Message Types ────────────────────────────────────────────────────────────

message InitMilestoneVault {
    tradeId:            Int as uint64;
    buyer:              Address;
    seller:             Address;
    arbitrator:         Address;
    referrer:           Address;
    referrerFeeBps:     Int as uint16;  // 100 = 1%, 200 = 2%, max 1000 = 10%
    milestoneCount:     Int as uint8;   // fixed at 2 for current version
    m0Value:            Int as coins;   // milestone 0 TON amount
    m1Value:            Int as coins;   // milestone 1 TON amount
    m0Window:           Int as uint32;  // buyer review window seconds (confirm/dispute after seller submits)
    m1Window:           Int as uint32;  // buyer review window seconds
    m0DeliveryWindow:   Int as uint32;  // seller delivery window seconds (time to submit M0 after activation)
    m1DeliveryWindow:   Int as uint32;  // seller delivery window seconds (time to submit M1 after M0 resolves)
    arbitratorFee:      Int as coins;   // dispute resolution fee forwarded to factory (DAO)
    performanceBond:    Int as coins;   // seller's bond amount (typically 2% of total)
    tradeRef:           String;         // human readable reference e.g. "Urea N46% 5000MT"
}

message(0x3007) MilestoneVaultInitOk {
    tradeId: Int as uint64;
}

message SellerConfirmMilestone {
    index:   Int as uint8;
    docHash: Int as uint256;  // SHA-256 hash of combined documents
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

// Buyer reclaims funds if seller misses the delivery deadline for a milestone.
// Permissioned to buyer only; index must be in PENDING state past its deadline.
message(0x4B01) BuyerClaimAbandoned {
    index: Int as uint8;
}

// Both buyer and seller agree to cancel a milestone without arbitration.
// Use case: force majeure or mutual agreement that delivery will not happen.
// On mutual consent: milestone value refunded to buyer, bond returned to seller at close.
// Cannot bypass active arbitration — restricted to PENDING (0) and CONFIRMING (1) states.
message(0x4B02) MutualCancelMilestone {
    index: Int as uint8;
}

// Buyer and seller mutually settle a DISPUTED milestone on an agreed split,
// bypassing both the arbitrator and the 50/50 timeout. One party proposes a
// buyer percentage (0-100); the other approves by echoing the exact same
// percentage. Execution requires the counterparty to match, so neither side
// can settle unilaterally. Seller always receives the remainder (100 - pct).
message(0x4B03) ProposeMilestoneSettlement {
    index:    Int as uint8;
    buyerPct: Int as uint8;   // 0-100 of the milestone value; seller gets the rest
}

// ─── State Constants ──────────────────────────────────────────────────────────
// Milestone states:
//   0 = PENDING     not yet started
//   1 = CONFIRMING  seller confirmed delivery, awaiting buyer review
//   2 = DONE        funds released
//   3 = DISPUTED    in arbitration
//
// Vault states:
//   0 = AWAITING_BOND  waiting for seller to deposit performance bond
//   1 = ACTIVE         seller bond + buyer payment both funded, milestones running
//   2 = CLOSED         all milestones resolved

// ─── Contract ─────────────────────────────────────────────────────────────────

contract EscrowVaultMilestone with Deployable {

    const DisputeTimeoutWindow: Int = 2592000; // 30 days — last-resort backstop only.
    // Long enough that no rational party stalls for the 50/50 timeout instead of
    // settling (ProposeMilestoneSettlement) or letting the council resolve (24-48h).
    const PreActivationTimeoutWindow: Int = 604800; // 7 days

    // Factory that deployed this vault (only factory can call InitMilestoneVault)
    factory:            Address;
    tradeId:            Int as uint64;

    // Core parties — set by factory via InitMilestoneVault
    buyer:              Address;
    seller:             Address;
    arbitrator:         Address;
    referrer:           Address;
    referrerFeeBps:     Int as uint16;

    // Financial
    totalValue:         Int as coins;
    performanceBond:    Int as coins;
    arbitratorFee:      Int as coins;
    referrerFee:        Int as coins;
    referrerPaid:       Bool;

    // Milestone config
    milestoneCount:     Int as uint8;
    m0Value:            Int as coins;
    m1Value:            Int as coins;
    m0Window:           Int as uint32;  // buyer review window
    m1Window:           Int as uint32;  // buyer review window
    m0DeliveryWindow:   Int as uint32;  // seller delivery window
    m1DeliveryWindow:   Int as uint32;  // seller delivery window
    tradeRef:           String;

    // Milestone runtime state
    m0State:            Int as uint8;
    m1State:            Int as uint8;
    m0DocHash:          Int as uint256;
    m1DocHash:          Int as uint256;
    m0Deadline:         Int as uint32;  // buyer review deadline (after seller confirms)
    m1Deadline:         Int as uint32;  // buyer review deadline
    m0DeliveryDeadline: Int as uint32;  // seller must submit M0 by this time
    m1DeliveryDeadline: Int as uint32;  // seller must submit M1 by this time
    m0DisputeDeadline:  Int as uint32;  // arbitrator must resolve M0 dispute by this time
    m1DisputeDeadline:  Int as uint32;  // arbitrator must resolve M1 dispute by this time

    // Vault state
    sellerBonded:       Bool;
    buyerFunded:        Bool;
    activeMilestone:    Int as uint8;
    vaultState:         Int as uint8;
    createdAt:          Int as uint32;

    // Mutual cancel consent flags — both must be true to execute a no-penalty cancel
    m0CancelBuyer:      Bool;
    m0CancelSeller:     Bool;
    m1CancelBuyer:      Bool;
    m1CancelSeller:     Bool;

    // Mutual dispute settlement — pending %-split proposal per milestone.
    // Executes when the counterparty echoes the same buyerPct.
    m0SettleProposed:   Bool;
    m0SettleBuyerPct:   Int as uint8;
    m0SettleProposer:   Address;
    m1SettleProposed:   Bool;
    m1SettleBuyerPct:   Int as uint8;
    m1SettleProposer:   Address;

    // ─── Init ──────────────────────────────────────────────────────────────────
    init(factory: Address, tradeId: Int) {
        self.factory            = factory;
        self.tradeId            = tradeId;
        self.buyer              = newAddress(0, 0);
        self.seller             = newAddress(0, 0);
        self.arbitrator         = newAddress(0, 0);
        self.referrer           = newAddress(0, 0);
        self.referrerFeeBps     = 0;
        self.totalValue         = 0;
        self.performanceBond    = 0;
        self.arbitratorFee      = 0;
        self.referrerFee        = 0;
        self.referrerPaid       = false;
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
        self.arbitrator         = msg.arbitrator;
        self.referrer           = msg.referrer;
        self.referrerFeeBps     = msg.referrerFeeBps;
        self.totalValue         = total;
        self.performanceBond    = msg.performanceBond;
        self.arbitratorFee      = msg.arbitratorFee;
        self.milestoneCount     = msg.milestoneCount;
        self.m0Value            = msg.m0Value;
        self.m1Value            = msg.m1Value;
        self.m0Window           = msg.m0Window;
        self.m1Window           = msg.m1Window;
        self.m0DeliveryWindow   = msg.m0DeliveryWindow;
        self.m1DeliveryWindow   = msg.m1DeliveryWindow;
        self.tradeRef           = msg.tradeRef;
        self.m0State            = 0;
        self.m1State            = 0;
        self.sellerBonded       = false;
        self.buyerFunded        = false;
        // vaultState stays 0 until both seller bond and buyer payment are deposited

        send(SendParameters{
            to: self.factory,
            value: ton("0.05"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: MilestoneVaultInitOk{ tradeId: msg.tradeId }.toCell()
        });
    }

    // ─── Seller deposits Performance Bond ─────────────────────────────────────
    receive("DepositBond") {
        require(sender() == self.seller,                  "Only seller");
        require(self.vaultState == 0,                     "Wrong vault state");
        require(self.totalValue > 0,                      "Vault not initialised");
        require(!self.sellerBonded,                       "Bond already deposited");

        let msgValue: Int = context().value;
        require(msgValue >= self.performanceBond,         "Insufficient bond amount");

        let excess: Int = msgValue - self.performanceBond;
        if (excess > 0) {
            send(SendParameters{
                to:     self.seller,
                value:  excess,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Bond deposit excess refund".asComment()
            });
        }

        self.sellerBonded = true;

        if (self.buyerFunded) {
            self.activateVault();
        }
    }

    // ─── Buyer deposits milestone payment value ────────────────────────────────
    receive("DepositPayment") {
        require(sender() == self.buyer,              "Only buyer");
        require(self.vaultState == 0,                "Wrong vault state");
        require(self.totalValue > 0,                 "Vault not initialised");
        require(!self.buyerFunded,                   "Payment already deposited");

        let msgValue: Int = context().value;
        let required: Int = self.totalValue + self.referrerFee;
        // Buyer must cover trade value + referrer fee; referrer fee is paid from vault balance.
        require(msgValue >= required,                "Insufficient buyer payment: include referrer fee");

        let excess: Int = msgValue - required;
        if (excess > 0) {
            send(SendParameters{
                to:     self.buyer,
                value:  excess,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Payment deposit excess refund".asComment()
            });
        }

        self.buyerFunded = true;

        if (self.sellerBonded) {
            self.activateVault();
        }
    }

    // ─── Refund stranded pre-activation funding after timeout ───────────────
    // If only one side funds the vault and the counterparty never completes
    // activation, allow the funded party's value to be recovered instead of
    // remaining trapped in vaultState 0 indefinitely.
    receive("RefundPreActivationStall") {
        require(self.vaultState == 0,                "Vault already active or closed");
        require(self.totalValue > 0,                 "Vault not initialised");
        require(now() > self.createdAt + self.PreActivationTimeoutWindow, "Pre-activation timeout not yet passed");

        let buyerRefund: Int = 0;
        let sellerRefund: Int = 0;

        if (self.buyerFunded) {
            buyerRefund = self.totalValue + self.referrerFee;
            self.buyerFunded = false;
        }

        if (self.sellerBonded) {
            sellerRefund = self.performanceBond;
            self.sellerBonded = false;
        }

        // No "nothing funded" gate: a vault that never received a single deposit
        // (e.g. both parties abandoned it) is exactly the case this must still be
        // able to close out and sweep its stranded gas — not a case to revert on.

        self.vaultState = 2; // CLOSED

        if (buyerRefund > 0) {
            send(SendParameters{
                to:    self.buyer,
                value: buyerRefund,
                mode:  SendPayGasSeparately,
                bounce: false,
                body:  "Pre-activation buyer refund".asComment()
            });
        }

        if (sellerRefund > 0) {
            send(SendParameters{
                to:    self.seller,
                value: sellerRefund,
                mode:  SendPayGasSeparately,
                bounce: false,
                body:  "Pre-activation seller refund".asComment()
            });
        }

        if (buyerRefund > 0) {
            send(SendParameters{
                to:    self.buyer,
                value: 0,
                mode:  SendRemainingBalance + SendDestroyIfZero,
                bounce: false
            });
        } else {
            send(SendParameters{
                to:    self.seller,
                value: 0,
                mode:  SendRemainingBalance + SendDestroyIfZero,
                bounce: false
            });
        }
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
            self.m0State    = 1; // CONFIRMING
            self.m0DocHash  = msg.docHash;
            self.m0Deadline = now() + max(self.m0Window, 3600);
        } else {
            require(self.m1State == 0,                "M1 not in pending state");
            self.m1State    = 1; // CONFIRMING
            self.m1DocHash  = msg.docHash;
            self.m1Deadline = now() + max(self.m1Window, 3600);
        }
    }

    // ─── Buyer confirms milestone received ────────────────────────────────────
    receive(msg: BuyerConfirmMilestone) {
        require(sender() == self.buyer,    "Only buyer");
        require(self.vaultState == 1,      "Vault not active");

        if (msg.index == 0) {
            require(self.m0State == 1,     "M0 not in confirming state");
            self.m0State = 2; // DONE
            self.releaseMilestone0();
        } else {
            require(self.m1State == 1,     "M1 not in confirming state");
            self.m1State = 2; // DONE
            self.releaseMilestone1();
        }
    }

    // ─── Auto-release on review timeout ───────────────────────────────────────
    // Permissionless — anyone can call. Protects sellers from buyer ghosting.
    receive("CheckTimeout") {
        require(self.vaultState == 1, "Vault not active");

        if (self.m0State == 1 && now() > self.m0Deadline) {
            self.m0State = 2;
            self.releaseMilestone0();
        }

        if (self.m1State == 1 && now() > self.m1Deadline) {
            self.m1State = 2;
            self.releaseMilestone1();
        }

        if (self.m0State == 3 && self.m0DisputeDeadline > 0 && now() > self.m0DisputeDeadline) {
            self.resolveDisputeTimeout(0);
        }

        if (self.m1State == 3 && self.m1DisputeDeadline > 0 && now() > self.m1DisputeDeadline) {
            self.resolveDisputeTimeout(1);
        }
    }

    // ─── Buyer raises dispute ──────────────────────────────────────────────────
    // Disputing M0 does NOT freeze M1 — activeMilestone advances so seller can
    // continue delivering M1 while M0 arbitration proceeds independently.
    receive(msg: BuyerDisputeMilestone) {
        require(sender() == self.buyer,    "Only buyer");
        require(self.vaultState == 1,      "Vault not active");

        if (msg.index == 0) {
            require(self.m0State == 1,     "M0 not in confirming state");
            self.m0State = 3; // DISPUTED
            // Advance cursor so seller can deliver M1 in parallel with arbitration
            self.activeMilestone   = 1;
            self.m0DisputeDeadline = now() + self.DisputeTimeoutWindow;
        } else {
            require(self.m1State == 1,     "M1 not in confirming state");
            self.m1State = 3; // DISPUTED
            self.m1DisputeDeadline = now() + self.DisputeTimeoutWindow;
        }
    }

    // ─── Buyer reclaims if seller misses delivery deadline ─────────────────────
    // If seller never submits SellerConfirmMilestone within the delivery window,
    // buyer can reclaim the milestone value + bond (seller forfeits both).
    receive(msg: BuyerClaimAbandoned) {
        require(sender() == self.buyer, "Only buyer");
        require(self.vaultState == 1,   "Vault not active");
        require(msg.index <= 1,         "Invalid milestone index");

        if (msg.index == 0) {
            require(self.m0State == 0,              "M0 is not pending");
            require(self.m0DeliveryDeadline > 0,    "Delivery deadline not set");
            require(now() > self.m0DeliveryDeadline,"Delivery deadline not yet passed");

            self.m0State = 2; // DONE (refunded)
            send(SendParameters{
                to:    self.buyer,
                value: self.m0Value,
                mode:  SendPayGasSeparately,
                bounce: false
            });
            // Slash M0's proportional share of the bond to buyer — seller abandoned
            // this obligation but may still deliver M1, which keeps its own share as
            // collateral. Mirrors ArbitratorResolveMilestone's slash math.
            if (self.performanceBond > 0) {
                let m0BondSlash: Int = self.performanceBond * self.m0Value / self.totalValue;
                if (m0BondSlash > 0) {
                    send(SendParameters{
                        to:    self.buyer,
                        value: m0BondSlash,
                        mode:  SendPayGasSeparately,
                        bounce: false
                    });
                }
                self.performanceBond = self.performanceBond - m0BondSlash;
            }
            // Allow M1 to be attempted (or claimed abandoned too)
            self.activeMilestone    = 1;
            self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;

        } else {
            require(self.m1State == 0,              "M1 is not pending");
            require(self.m1DeliveryDeadline > 0,    "Delivery deadline not set");
            require(now() > self.m1DeliveryDeadline,"Delivery deadline not yet passed");

            self.m1State = 2; // DONE (refunded)
            send(SendParameters{
                to:    self.buyer,
                value: self.m1Value,
                mode:  SendPayGasSeparately,
                bounce: false
            });
            // Slash any remaining bond to buyer
            if (self.performanceBond > 0) {
                send(SendParameters{
                    to:    self.buyer,
                    value: self.performanceBond,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
                self.performanceBond = 0;
            }
        }

        self.checkVaultClose();
    }

    // ─── Mutual cancel milestone (force majeure / bilateral agreement) ─────────
    // Either party sends this message to register their consent. Execution fires
    // only when BOTH buyer and seller have consented for the same milestone index.
    //
    // On execution:
    //   • Milestone value refunded to buyer (no penalty)
    //   • performanceBond is NOT slashed — it remains in vault and is returned to
    //     seller at checkVaultClose, because force majeure is not seller's fault
    //   • Referrer is NOT paid (no delivery occurred)
    //   • If M0 is cancelled, M1 delivery window starts immediately
    //
    // Restricted to PENDING (0) and CONFIRMING (1) states.
    // DISPUTED (3) milestones must go through arbitration — MutualCancel cannot
    // bypass an active arbitration once raised.
    receive(msg: MutualCancelMilestone) {
        let s: Address = sender();
        require(s == self.buyer || s == self.seller, "Only trade parties");
        require(self.vaultState == 1,                "Vault not active");
        require(msg.index <= 1,                      "Invalid milestone index");

        if (msg.index == 0) {
            require(self.m0State == 0 || self.m0State == 1, "M0 not in cancellable state");
            // Sending again toggles consent — allows a party to retract before
            // the counterparty has also consented. Once both consent, execution
            // fires immediately so retraction at that point is not possible.
            if (s == self.buyer)  { self.m0CancelBuyer  = !self.m0CancelBuyer;  }
            else                  { self.m0CancelSeller = !self.m0CancelSeller; }

            if (self.m0CancelBuyer && self.m0CancelSeller) {
                self.m0State = 2; // DONE — mutual cancel
                send(SendParameters{
                    to:     self.buyer,
                    value:  self.m0Value,
                    mode:   SendPayGasSeparately,
                    bounce: false,
                    body:   "Mutual cancel: M0 refund".asComment()
                });
                // Advance cursor so M1 can proceed (or be mutually cancelled too)
                if (self.activeMilestone == 0) {
                    self.activeMilestone    = 1;
                    self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
                }
                self.checkVaultClose();
            }
        } else {
            require(self.m1State == 0 || self.m1State == 1, "M1 not in cancellable state");
            if (s == self.buyer)  { self.m1CancelBuyer  = !self.m1CancelBuyer;  }
            else                  { self.m1CancelSeller = !self.m1CancelSeller; }

            if (self.m1CancelBuyer && self.m1CancelSeller) {
                self.m1State = 2; // DONE — mutual cancel
                send(SendParameters{
                    to:     self.buyer,
                    value:  self.m1Value,
                    mode:   SendPayGasSeparately,
                    bounce: false,
                    body:   "Mutual cancel: M1 refund".asComment()
                });
                self.checkVaultClose();
            }
        }
    }

    // ─── Mutual dispute settlement (no arbitrator, no 50/50 timeout) ───────────
    // During an active dispute, buyer and seller agree on a % split of the
    // milestone value. One party proposes a buyerPct; the other approves by
    // echoing the exact same value. A different value overwrites the pending
    // proposal (counter-offer). Execution requires the *other* party to match,
    // so neither side can settle unilaterally.
    //
    // Bond is NOT slashed — it returns to the seller at close, since a mutual
    // settlement is a consensual compromise, not a fault finding. Referrer is
    // paid only if the seller realises value (sellerShare > 0).
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
                self.m0SettleProposed = true;
                self.m0SettleBuyerPct = msg.buyerPct;
                self.m0SettleProposer = s;
            }
        } else {
            require(self.m1State == 3, "M1 not in disputed state");
            if (self.m1SettleProposed && self.m1SettleProposer != s && self.m1SettleBuyerPct == msg.buyerPct) {
                self.executeMilestoneSettlement(1, msg.buyerPct);
            } else {
                self.m1SettleProposed = true;
                self.m1SettleBuyerPct = msg.buyerPct;
                self.m1SettleProposer = s;
            }
        }
    }

    // ─── Arbitrator resolves dispute ───────────────────────────────────────────
    receive(msg: ArbitratorResolveMilestone) {
        require(sender() == self.arbitrator, "Only arbitrator");
        require(self.vaultState == 1,        "Vault not active");

        if (msg.index == 0) {
            require(self.m0State == 3,       "M0 not in disputed state");
            self.m0State = 2; // DONE
            self.m0DisputeDeadline = 0;

            if (msg.releaseToSeller) {
                // Seller wins — release M0 value; bond stays in vault until close
                send(SendParameters{
                    to:    self.seller,
                    value: self.m0Value,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
                self.payReferrer();
            } else {
                // Buyer wins — return M0 value + slash only M0-proportional share of bond.
                // Remaining bond (m1Value / totalValue share) stays in vault so seller
                // retains collateral for M1. It is slashed or returned at checkVaultClose.
                send(SendParameters{
                    to:    self.buyer,
                    value: self.m0Value,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
                if (self.performanceBond > 0) {
                    let m0BondSlash: Int = self.performanceBond * self.m0Value / self.totalValue;
                    if (m0BondSlash > 0) {
                        send(SendParameters{
                            to:    self.buyer,
                            value: m0BondSlash,
                            mode:  SendPayGasSeparately,
                            bounce: false
                        });
                    }
                    self.performanceBond = self.performanceBond - m0BondSlash;
                }
            }
            // M1 delivery starts only after the M0 dispute is actually resolved.
            if (self.m1State == 0 && self.m1DeliveryDeadline == 0) {
                self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
            }

        } else {
            require(self.m1State == 3,       "M1 not in disputed state");
            self.m1State = 2; // DONE
            self.m1DisputeDeadline = 0;

            if (msg.releaseToSeller) {
                send(SendParameters{
                    to:    self.seller,
                    value: self.m1Value,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
                // Referrer fee only paid when seller wins — delivery was completed.
                // If buyer wins the dispute, seller failed to deliver so the buyer
                // should not subsidise the referrer fee.
                self.payReferrer();
            } else {
                send(SendParameters{
                    to:    self.buyer,
                    value: self.m1Value,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
                // Slash any remaining bond to buyer
                if (self.performanceBond > 0) {
                    send(SendParameters{
                        to:    self.buyer,
                        value: self.performanceBond,
                        mode:  SendPayGasSeparately,
                        bounce: false
                    });
                    self.performanceBond = 0;
                }
            }
        }

        // Pay dispute resolution fee to factory (DAO)
        if (self.arbitratorFee > 0) {
            send(SendParameters{
                to:    self.arbitrator,
                value: self.arbitratorFee,
                mode:  SendPayGasSeparately,
                bounce: false,
                body:  "Dispute resolution fee".asComment()
            });
        }

        self.checkVaultClose();
    }

    // ─── Internal: activate vault when both parties funded ────────────────────
    fun activateVault() {
        self.vaultState         = 1; // ACTIVE
        self.activeMilestone    = 0;
        self.m0DeliveryDeadline = now() + self.m0DeliveryWindow;
    }

    // ─── Internal: release milestone 0 ────────────────────────────────────────
    fun releaseMilestone0() {
        send(SendParameters{
            to:    self.seller,
            value: self.m0Value,
            mode:  SendPayGasSeparately,
            bounce: false
        });
        self.payReferrer();
        self.activeMilestone    = 1;
        self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
        self.checkVaultClose();
    }

    // ─── Internal: release milestone 1 ────────────────────────────────────────
    // Bond is NOT returned here — it is handled in checkVaultClose so that
    // it is never double-spent when M0 is disputed while M1 completes.
    fun releaseMilestone1() {
        send(SendParameters{
            to:    self.seller,
            value: self.m1Value,
            mode:  SendPayGasSeparately,
            bounce: false
        });
        self.payReferrer();
        self.checkVaultClose();
    }

    // ─── Internal: pay referrer once on first milestone release ───────────────
    fun payReferrer() {
        if (!self.referrerPaid && self.referrerFee > 0) {
            send(SendParameters{
                to:    self.referrer,
                value: self.referrerFee,
                mode:  SendPayGasSeparately,
                bounce: false
            });
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

            if (self.m1State == 0 && self.m1DeliveryDeadline == 0) {
                self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
            }
        } else {
            self.m1State = 2;
            self.m1DisputeDeadline = 0;
            buyerShare = self.m1Value / 2;
            sellerShare = self.m1Value - buyerShare;
        }

        if (buyerShare > 0) {
            send(SendParameters{
                to: self.buyer,
                value: buyerShare,
                mode: SendPayGasSeparately,
                bounce: false
            });
        }

        if (sellerShare > 0) {
            send(SendParameters{
                to: self.seller,
                value: sellerShare,
                mode: SendPayGasSeparately,
                bounce: false
            });
        }

        self.payReferrer();
        self.checkVaultClose();
    }

    // ─── Internal: execute a mutually-agreed dispute settlement ───────────────
    // Splits the milestone value buyerPct / (100 - buyerPct). Seller gets the
    // exact remainder so conservation holds regardless of integer truncation.
    fun executeMilestoneSettlement(index: Int, buyerPct: Int) {
        let mValue: Int = self.m0Value;
        if (index != 0) { mValue = self.m1Value; }

        let buyerShare: Int  = mValue * buyerPct / 100;
        let sellerShare: Int = mValue - buyerShare;

        if (index == 0) {
            self.m0State = 2;
            self.m0DisputeDeadline = 0;
        } else {
            self.m1State = 2;
            self.m1DisputeDeadline = 0;
        }

        if (buyerShare > 0) {
            send(SendParameters{
                to:     self.buyer,
                value:  buyerShare,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Dispute settlement: buyer share".asComment()
            });
        }
        if (sellerShare > 0) {
            send(SendParameters{
                to:     self.seller,
                value:  sellerShare,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   "Dispute settlement: seller share".asComment()
            });
            // Seller realised value — referrer earned their fee.
            self.payReferrer();
        }

        // Settling M0 must not deadlock M1 — start its delivery window if unset.
        if (index == 0 && self.m1State == 0 && self.m1DeliveryDeadline == 0) {
            self.m1DeliveryDeadline = now() + self.m1DeliveryWindow;
        }

        self.checkVaultClose();
    }

    // ─── Internal: close vault when ALL milestones are DONE ───────────────────
    //
    // Closes only when both milestones reach state 2 (DONE).
    // State 3 (DISPUTED) keeps the vault open — arbitration is still pending.
    //
    // Bond disposition at close:
    //   performanceBond > 0  → return to seller (not slashed, or already zeroed)
    //   performanceBond == 0 → skip (already sent to buyer during dispute resolution
    //                          or BuyerClaimAbandoned)
    //
    // After bond send, sweeps gas residue to buyer and self-destructs.
    fun checkVaultClose() {
        if (self.vaultState == 2) { return; } // double-close guard
        if (self.m0State == 2 && self.m1State == 2) {
            self.vaultState = 2; // CLOSED

            // Return performance bond to seller if not already slashed/claimed
            if (self.performanceBond > 0) {
                send(SendParameters{
                    to:    self.seller,
                    value: self.performanceBond,
                    mode:  SendPayGasSeparately,
                    bounce: false
                });
            }

            // Gas residue refund to buyer + self-destruct
            send(SendParameters{
                to:    self.buyer,
                value: 0,
                mode:  SendRemainingBalance + SendDestroyIfZero,
                bounce: false
            });
        }
    }

    // ─── Getters ───────────────────────────────────────────────────────────────
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
    get fun m0Window(): Int            { return self.m0Window;           }
    get fun m1Window(): Int            { return self.m1Window;           }
    get fun m0DeliveryWindow(): Int    { return self.m0DeliveryWindow;   }
    get fun m1DeliveryWindow(): Int    { return self.m1DeliveryWindow;   }
    get fun m0DeliveryDeadline(): Int  { return self.m0DeliveryDeadline; }
    get fun m1DeliveryDeadline(): Int  { return self.m1DeliveryDeadline; }
    get fun m0DisputeDeadline(): Int   { return self.m0DisputeDeadline;  }
    get fun m1DisputeDeadline(): Int   { return self.m1DisputeDeadline;  }

    get fun milestoneState(index: Int): Int {
        if (index == 0) { return self.m0State; }
        return self.m1State;
    }

    get fun isTimedOut(index: Int): Bool {
        if (index == 0) {
            return self.m0State == 1 && now() > self.m0Deadline;
        }
        return self.m1State == 1 && now() > self.m1Deadline;
    }

    get fun isDeliveryMissed(index: Int): Bool {
        if (index == 0) {
            return self.m0State == 0 && self.m0DeliveryDeadline > 0 && now() > self.m0DeliveryDeadline;
        }
        return self.m1State == 0 && self.m1DeliveryDeadline > 0 && now() > self.m1DeliveryDeadline;
    }

    get fun isDisputeTimedOut(index: Int): Bool {
        if (index == 0) {
            return self.m0State == 3 && self.m0DisputeDeadline > 0 && now() > self.m0DisputeDeadline;
        }
        return self.m1State == 3 && self.m1DisputeDeadline > 0 && now() > self.m1DisputeDeadline;
    }

    get fun timeRemaining(index: Int): Int {
        if (index == 0) {
            if (self.m0Deadline == 0) { return 0; }
            let remaining: Int = self.m0Deadline - now();
            if (remaining < 0) { return 0; }
            return remaining;
        }
        if (self.m1Deadline == 0) { return 0; }
        let remaining: Int = self.m1Deadline - now();
        if (remaining < 0) { return 0; }
        return remaining;
    }

    get fun deliveryTimeRemaining(index: Int): Int {
        if (index == 0) {
            if (self.m0DeliveryDeadline == 0) { return 0; }
            let remaining: Int = self.m0DeliveryDeadline - now();
            if (remaining < 0) { return 0; }
            return remaining;
        }
        if (self.m1DeliveryDeadline == 0) { return 0; }
        let remaining: Int = self.m1DeliveryDeadline - now();
        if (remaining < 0) { return 0; }
        return remaining;
    }

    get fun referrer(): Address    { return self.referrer;       }
    get fun arbitrator(): Address  { return self.arbitrator;     }
    get fun buyer(): Address       { return self.buyer;          }
    get fun seller(): Address      { return self.seller;         }
    get fun referrerFee(): Int     { return self.referrerFee;    }
    get fun referrerPaid(): Bool   { return self.referrerPaid;   }
    get fun referrerFeeBps(): Int  { return self.referrerFeeBps; }

    // Mutual cancel consent state — frontend uses these to show "waiting for [party]"
    get fun m0CancelBuyer(): Bool  { return self.m0CancelBuyer;  }
    get fun m0CancelSeller(): Bool { return self.m0CancelSeller; }
    get fun m1CancelBuyer(): Bool  { return self.m1CancelBuyer;  }
    get fun m1CancelSeller(): Bool { return self.m1CancelSeller; }

    // Pending dispute-settlement proposals — frontend shows the offered split
    // and which party still needs to approve.
    get fun m0SettleProposed(): Bool    { return self.m0SettleProposed; }
    get fun m0SettleBuyerPct(): Int     { return self.m0SettleBuyerPct; }
    get fun m0SettleProposer(): Address { return self.m0SettleProposer; }
    get fun m1SettleProposed(): Bool    { return self.m1SettleProposed; }
    get fun m1SettleBuyerPct(): Int     { return self.m1SettleBuyerPct; }
    get fun m1SettleProposer(): Address { return self.m1SettleProposer; }

    get fun fullInfo(): String {
        let sb: StringBuilder = beginString();
        sb.append("ref:");
        sb.append(self.tradeRef);
        sb.append("|vault:");
        sb.append(self.vaultState.toString());
        sb.append("|active:");
        sb.append(self.activeMilestone.toString());
        sb.append("|m0:");
        sb.append(self.m0State.toString());
        sb.append("|m1:");
        sb.append(self.m1State.toString());
        sb.append("|total:");
        sb.append(self.totalValue.toString());
        sb.append("|bond:");
        sb.append(self.performanceBond.toString());
        return sb.toString();
    }
}
