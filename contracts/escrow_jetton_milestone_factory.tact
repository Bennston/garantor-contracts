import "@stdlib/ownable";
import "./escrow_jetton_vault_milestone";

// ============================================================
// EscrowJettonMilestoneFactory (V2) — deploys EscrowJettonVaultMilestone
// ============================================================
//
// Jetton (USDT) counterpart of EscrowMilestoneFactory. Sequential tradeId,
// deterministic vault address, buyer/seller registry, time-locked params.
// The arbitrator is PINNED to the factory owner (never caller-supplied), same
// as V1. Trade amounts are in the jetton's minimal units; TON paid only covers
// the deployment fee + the vault's gas budget.
// ============================================================

message(0x3002) CreateJettonMilestoneEscrow {
    buyer:              Address;
    seller:             Address;
    arbitrator:         Address;          // ignored — pinned to owner
    referrer:           Address;
    referrerFeeBps:     Int as uint16;
    milestoneCount:     Int as uint8;     // must be 2
    jettonMaster:       Address;          // must equal the factory's configured master
    m0Value:            Int as coins;     // jetton minimal units
    m1Value:            Int as coins;
    m0Window:           Int as uint32;
    m1Window:           Int as uint32;
    m0DeliveryWindow:   Int as uint32;
    m1DeliveryWindow:   Int as uint32;
    performanceBond:    Int as coins;
    tradeRef:           String;
    nonce:              Int as uint256;   // client idempotency key — one per trade FORM, reused on retry
}

message(0x3005) WithdrawFees {}
message(0x3006) UpdateOperationalReserve { newOperationalReserve: Int as coins; }
// Owner-only AND TIMELOCKED — jettonMaster decides WHICH asset this factory
// escrows, so it gets at least the protection the numeric params already have
// (design doc §6.7). An instant switch would let a compromised owner silently
// point new vaults at a master it controls, which can then hand each vault an
// attacker-owned "jetton wallet" whose forged notifications the vault would
// credit as real deposits. Existing vaults keep the master they were built with.
message(0x2010) ScheduleJettonMaster { newJettonMaster: Address; }
message(0x2011) ApplyJettonMaster {}
message(0x2012) CancelJettonMaster {}
message(0x3009) ScheduleParamChange { param: Int as uint8; value: Int as coins; }
message(0x300A) ApplyParamChange {}
message(0x300B) CancelParamChange {}
message(0x300C) UpdateTimelockDelay { newDelay: Int as uint32; }

message(0xF102) EvtJettonMilestoneVaultDeployed {
    vaultAddress: Address;
    buyer: Address;
    seller: Address;
    jettonMaster: Address;
    totalValue: Int as coins;
    tradeId: Int as uint64;
}

struct JettonMilestoneFactoryConfig {
    owner: Address;
    jettonMaster: Address;
    deploymentFee: Int as coins;
    minTradeValue: Int as coins;
    totalVaultsDeployed: Int as uint32;
    totalFeesCollected: Int as coins;
    operationalReserve: Int as coins;
    timelockDelay: Int as uint32;
    disputeFeeBps: Int as uint16;
    pendingParam: Int as uint8;
    pendingValue: Int as coins;
    pendingEffectiveAt: Int as uint32;
    // Pending jetton-master change; pendingJettonMasterAt == 0 means none.
    // Exposed so a scheduled asset switch is visible on-chain during the
    // timelock window rather than only at the moment it lands — the window is
    // only useful if someone can see it. Mirrors EscrowJettonFactory.
    pendingJettonMaster: Address;
    pendingJettonMasterAt: Int as uint32;
}

contract EscrowJettonMilestoneFactory with Ownable {

    owner: Address;
    jettonMaster: Address;

    deploymentFee:      Int as coins;
    minTradeValue:      Int as coins;     // in jetton minimal units
    operationalReserve: Int as coins;

    // Arbitration fee, in basis points of the trade's totalValue. Prefunded by
    // the buyer in JETTONS and paid to the arbitrator only if a milestone dispute
    // is actually arbitrated — refunded to the buyer at close otherwise.
    //
    // Exists because V1's per-dispute arbitratorFee was paid from the vault's
    // spare TON, which has no jetton equivalent, so the port dropped it and left
    // milestone arbitration uncompensated (see the vault's header). Milestone
    // disputes are the most labour-intensive the council handles, so "free" was a
    // porting gap, not a policy decision.
    //
    // Proportional rather than flat, to avoid the regressiveness a flat fee
    // imposes on small trades (same reason the commission is a percentage).
    // Timelocked via ScheduleParamChange param=3; capped at 10% to mirror the
    // regular vault's daoFee ceiling.
    disputeFeeBps:      Int as uint16;

    const VaultGasBudget: Int = ton("1.0"); // wallet discovery + push payouts + up to 30d rent (raised from 0.6 for dispute-heavy safety; top-up receiver on the vault is the backstop)

    timelockDelay:      Int as uint32;
    pendingParam:       Int as uint8;
    pendingValue:       Int as coins;
    pendingEffectiveAt: Int as uint32;

    // Pending jetton-master change (separate slot: it's an Address, not a coins
    // value, so it can't ride the numeric pendingParam slot).
    // pendingJettonMasterAt == 0 means nothing is pending.
    pendingJettonMaster:   Address;
    pendingJettonMasterAt: Int as uint32;

    totalVaultsDeployed: Int as uint32;
    totalFeesCollected: Int as coins;
    nextTradeId: Int as uint64;

    buyerVaultCount:  map<Address, Int as uint32>;
    sellerVaultCount: map<Address, Int as uint32>;
    buyerVaults:      map<Int, Int as uint64>;
    sellerVaults:     map<Int, Int as uint64>;
    pendingBuyer:     map<Int, Address>;
    pendingSeller:    map<Int, Address>;
    pendingCreator:   map<Int, Address>;
    pendingTotal:     map<Int, Int as coins>;
    pendingRefund:    map<Int, Int as coins>;
    pendingTradeByVault: map<Address, Int as uint64>;

    // Idempotency guard: hash(creator, nonce) → true once a create has been
    // accepted. A repeat of the SAME trade form (same nonce from the same
    // wallet) is rejected so the payment bounces instead of spawning a 2nd vault.
    // Released again in bounced() if the vault deploy fails, so a genuine retry
    // of the same form still works — the guard exists to stop duplicate vaults,
    // not to permanently burn a form that never produced one.
    seenTradeNonce: map<Int, Bool>;
    // tradeId → nonceKey, so bounced() knows which guard entry to release.
    pendingNonceKey: map<Int, Int>;

    init(owner: Address, jettonMaster: Address) {
        self.owner = owner;
        self.jettonMaster = jettonMaster;
        self.deploymentFee = ton("1.77");
        self.minTradeValue = 1;            // 1 jetton minimal unit (set real min via timelock)
        self.operationalReserve = ton("2");
        self.disputeFeeBps      = 100;   // 1% of totalValue, charged only on an arbitrated dispute
        self.timelockDelay      = 86400;
        self.pendingParam       = 0;
        self.pendingValue       = 0;
        self.pendingEffectiveAt = 0;
        self.pendingJettonMaster   = jettonMaster;  // placeholder; unused while At == 0
        self.pendingJettonMasterAt = 0;
        self.totalVaultsDeployed = 0;
        self.totalFeesCollected = 0;
        self.nextTradeId = 1;
    }

    receive() {}    // accept empty deploy message from Blueprint

    receive(msg: CreateJettonMilestoneEscrow) {
        // Idempotency: reject a repeat of the same trade form from the same
        // wallet. The inbound message is bounceable, so throwing here returns
        // the TON (minus gas) to the creator instead of deploying a 2nd vault.
        let nonceKey: Int = beginCell().storeAddress(sender()).storeUint(msg.nonce, 256).endCell().hash();
        require(!self.seenTradeNonce.exists(nonceKey), "Duplicate trade submission");
        self.seenTradeNonce.set(nonceKey, true);

        require(msg.jettonMaster == self.jettonMaster, "Unsupported jetton");
        require(msg.milestoneCount == 2,          "Exactly 2 milestones required");
        require(msg.m0Value > 0,                  "M0 value must be positive");
        require(msg.m1Value > 0,                  "M1 value must be positive");
        require(msg.buyer != msg.seller,          "Buyer and seller must differ");
        require(self.owner != msg.buyer,          "Owner/arbitrator cannot be buyer");
        require(self.owner != msg.seller,         "Owner/arbitrator cannot be seller");
        require(msg.referrerFeeBps <= 1000,       "Referrer fee exceeds 10%");
        require(msg.referrerFeeBps == 0 || (msg.referrer != msg.buyer && msg.referrer != msg.seller), "Referrer cannot be a trade party");

        let total: Int    = msg.m0Value + msg.m1Value;
        let msgValue: Int = context().value;
        require(total >= self.minTradeValue, "Trade value below minimum");
        require(msgValue >= self.deploymentFee + self.VaultGasBudget, "Insufficient deployment fee + gas");

        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        let vaultInit: StateInit = initOf EscrowJettonVaultMilestone(myAddress(), tradeId);
        let vaultAddress: Address = contractAddress(vaultInit);

        send(SendParameters{
            to:     vaultAddress,
            value:  msgValue - self.deploymentFee,
            mode:   0,
            bounce: true,
            code:   vaultInit.code,
            data:   vaultInit.data,
            body:   InitMilestoneVault{
                tradeId:            tradeId,
                buyer:              msg.buyer,
                seller:             msg.seller,
                creator:            sender(),   // funded the gas budget; gets the residual back
                arbitrator:         self.owner,   // pinned to DAO, msg.arbitrator ignored
                referrer:           msg.referrer,
                referrerFeeBps:     msg.referrerFeeBps,
                milestoneCount:     msg.milestoneCount,
                jettonMaster:       self.jettonMaster,
                m0Value:            msg.m0Value,
                m1Value:            msg.m1Value,
                m0Window:           msg.m0Window,
                m1Window:           msg.m1Window,
                m0DeliveryWindow:   msg.m0DeliveryWindow,
                m1DeliveryWindow:   msg.m1DeliveryWindow,
                performanceBond:    msg.performanceBond,
                tradeRef:           msg.tradeRef,
                // Snapshotted at creation, like referrerFeeBps — a later timelocked
                // change must never re-price a trade the parties already funded.
                disputeFeeBps:      self.disputeFeeBps
            }.toCell()
        });

        self.pendingBuyer.set(tradeId, msg.buyer);
        self.pendingSeller.set(tradeId, msg.seller);
        self.pendingCreator.set(tradeId, sender());
        self.pendingTotal.set(tradeId, total);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingTradeByVault.set(vaultAddress, tradeId);
        self.pendingNonceKey.set(tradeId, nonceKey);
    }

    receive(msg: MilestoneVaultInitOk) {
        let vaultAddress: Address = sender();
        require(self.pendingTradeByVault.exists(vaultAddress), "Only deployed vault");
        require(self.pendingTradeByVault.get(vaultAddress)!! == msg.tradeId, "Mismatched pending vault");
        require(self.pendingCreator.exists(msg.tradeId), "Unknown pending trade");

        let buyer: Address = self.pendingBuyer.get(msg.tradeId)!!;
        let seller: Address = self.pendingSeller.get(msg.tradeId)!!;
        let total: Int = self.pendingTotal.get(msg.tradeId)!!;

        self.totalFeesCollected = self.totalFeesCollected + self.deploymentFee;
        self._registerBuyerVault(buyer, msg.tradeId);
        self._registerSellerVault(seller, msg.tradeId);
        self.totalVaultsDeployed = self.totalVaultsDeployed + 1;

        emit(EvtJettonMilestoneVaultDeployed{
            vaultAddress: vaultAddress,
            buyer: buyer,
            seller: seller,
            jettonMaster: self.jettonMaster,
            totalValue: total,
            tradeId: msg.tradeId
        }.toCell());

        self.clearPendingTrade(msg.tradeId);
    }

    bounced(msg: Slice) {
        let vaultAddress: Address = sender();
        if (!self.pendingTradeByVault.exists(vaultAddress)) { return; }
        let tradeId: Int = self.pendingTradeByVault.get(vaultAddress)!!;
        let creator: Address = self.pendingCreator.get(tradeId)!!;

        // The vault never came into existence, so this form produced no vault.
        // Release the idempotency guard so the creator can retry the same form.
        if (self.pendingNonceKey.exists(tradeId)) {
            self.seenTradeNonce.del(self.pendingNonceKey.get(tradeId)!!);
        }

        // L-5: credit the ~0.02 TON bounce-handling overhead to fees.
        let bounceDust: Int = ton("0.02");
        self.totalFeesCollected = self.totalFeesCollected + bounceDust;

        let refundableBalance: Int = self.deploymentFee + context().value - bounceDust;
        if (refundableBalance < 0) { refundableBalance = 0; }
        let refundAmount: Int = min(self.pendingRefund.get(tradeId)!!, refundableBalance);
        send(SendParameters{
            to: creator,
            value: refundAmount,
            mode: 0,
            bounce: false,
            body: "Jetton milestone vault deployment failed".asComment()
        });
        self.clearPendingTrade(tradeId);
    }

    // ─── Registry helpers ──────────────────────────────────────────────────────
    fun _buyerKey(wallet: Address, index: Int): Int {
        return beginCell().storeUint(0, 1).storeAddress(wallet).storeUint(index, 32).endCell().hash();
    }
    fun _sellerKey(wallet: Address, index: Int): Int {
        return beginCell().storeUint(1, 1).storeAddress(wallet).storeUint(index, 32).endCell().hash();
    }
    fun _registerBuyerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.buyerVaultCount.exists(wallet)) { count = self.buyerVaultCount.get(wallet)!!; }
        self.buyerVaults.set(self._buyerKey(wallet, count), tradeId);
        self.buyerVaultCount.set(wallet, count + 1);
    }
    fun _registerSellerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.sellerVaultCount.exists(wallet)) { count = self.sellerVaultCount.get(wallet)!!; }
        self.sellerVaults.set(self._sellerKey(wallet, count), tradeId);
        self.sellerVaultCount.set(wallet, count + 1);
    }
    fun clearPendingTrade(tradeId: Int) {
        let vaultAddress: Address = contractAddress(initOf EscrowJettonVaultMilestone(myAddress(), tradeId));
        self.pendingBuyer.del(tradeId);
        self.pendingSeller.del(tradeId);
        self.pendingCreator.del(tradeId);
        self.pendingTotal.del(tradeId);
        self.pendingRefund.del(tradeId);
        self.pendingTradeByVault.del(vaultAddress);
        // Only the tradeId→nonceKey lookup is dropped here. The seenTradeNonce
        // entry itself is deliberately KEPT on the success path (VaultInitOk) —
        // that form did produce a vault and must not be replayable. bounced()
        // releases it explicitly before calling this.
        self.pendingNonceKey.del(tradeId);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────
    receive(msg: ScheduleJettonMaster) {
        self.requireOwner();
        require(msg.newJettonMaster != self.jettonMaster, "Already the active jetton master");
        self.pendingJettonMaster   = msg.newJettonMaster;
        self.pendingJettonMasterAt = now() + self.timelockDelay;
        cashback(sender());
    }
    receive(msg: ApplyJettonMaster) {
        self.requireOwner();
        require(self.pendingJettonMasterAt != 0,     "No pending jetton master change");
        require(now() >= self.pendingJettonMasterAt, "Timelock not yet expired");
        self.jettonMaster          = self.pendingJettonMaster;
        self.pendingJettonMasterAt = 0;
        cashback(sender());
    }
    receive(msg: CancelJettonMaster) {
        self.requireOwner();
        require(self.pendingJettonMasterAt != 0, "No pending jetton master change");
        self.pendingJettonMasterAt = 0;
        cashback(sender());
    }
    receive(msg: ScheduleParamChange) {
        self.requireOwner();
        require(msg.param >= 1 && msg.param <= 3, "Unknown param opcode");
        if (msg.param == 1) { require(msg.value >= ton("1"), "deploymentFee too low"); }
        if (msg.param == 2) { require(msg.value > 0, "minTradeValue must be positive"); }
        // Cap at 10% — mirrors the regular vault's daoFee ceiling.
        if (msg.param == 3) { require(msg.value <= 1000, "disputeFeeBps max 10%"); }
        self.pendingParam = msg.param;
        self.pendingValue = msg.value;
        self.pendingEffectiveAt = now() + self.timelockDelay;
        cashback(sender());
    }
    receive(msg: ApplyParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0,           "No pending change");
        require(now() >= self.pendingEffectiveAt, "Timelock not yet expired");
        if (self.pendingParam == 1) { self.deploymentFee = self.pendingValue; }
        if (self.pendingParam == 2) { self.minTradeValue = self.pendingValue; }
        if (self.pendingParam == 3) { self.disputeFeeBps = self.pendingValue; }
        self.pendingParam = 0; self.pendingValue = 0; self.pendingEffectiveAt = 0;
        cashback(sender());
    }
    receive(msg: CancelParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0, "No pending change");
        self.pendingParam = 0; self.pendingValue = 0; self.pendingEffectiveAt = 0;
        cashback(sender());
    }
    receive(msg: UpdateTimelockDelay) {
        self.requireOwner();
        require(msg.newDelay >= 86400, "Timelock delay minimum is 24h");
        self.timelockDelay = msg.newDelay;
        cashback(sender());
    }
    receive(msg: WithdrawFees) {
        self.requireOwner();
        let withdrawable: Int = min(myBalance() - self.operationalReserve, self.totalFeesCollected);
        require(withdrawable > 0, "No fees to withdraw");
        send(SendParameters{ to: sender(), value: withdrawable, mode: 0, bounce: false, body: "Factory fee withdrawal".asComment() });
        self.totalFeesCollected = self.totalFeesCollected - withdrawable;
    }
    receive(msg: UpdateOperationalReserve) {
        self.requireOwner();
        require(msg.newOperationalReserve >= ton("0.5"), "Operational reserve too low");
        self.operationalReserve = msg.newOperationalReserve;
        cashback(sender());
    }

    // ─── Getters ───────────────────────────────────────────────────────────────
    get fun factoryConfig(): JettonMilestoneFactoryConfig {
        return JettonMilestoneFactoryConfig{
            owner: self.owner,
            jettonMaster: self.jettonMaster,
            deploymentFee: self.deploymentFee,
            minTradeValue: self.minTradeValue,
            totalVaultsDeployed: self.totalVaultsDeployed,
            totalFeesCollected: self.totalFeesCollected,
            operationalReserve: self.operationalReserve,
            timelockDelay: self.timelockDelay,
            disputeFeeBps: self.disputeFeeBps,
            pendingParam: self.pendingParam,
            pendingValue: self.pendingValue,
            pendingEffectiveAt: self.pendingEffectiveAt,
            pendingJettonMaster: self.pendingJettonMaster,
            pendingJettonMasterAt: self.pendingJettonMasterAt
        };
    }
    get fun totalVaults(): Int { return self.totalVaultsDeployed; }
    get fun deploymentFeeAmount(): Int { return self.deploymentFee; }
    get fun jettonMasterAddr(): Address { return self.jettonMaster; }
    get fun vaultAddress(tradeId: Int): Address {
        return contractAddress(initOf EscrowJettonVaultMilestone(myAddress(), tradeId));
    }
    get fun walletVaultCount(wallet: Address, isBuyer: Bool): Int {
        if (isBuyer) {
            if (self.buyerVaultCount.exists(wallet)) { return self.buyerVaultCount.get(wallet)!!; }
            return 0;
        }
        if (self.sellerVaultCount.exists(wallet)) { return self.sellerVaultCount.get(wallet)!!; }
        return 0;
    }
    get fun walletVaultAtIndex(wallet: Address, isBuyer: Bool, index: Int): Int {
        if (isBuyer) {
            let key: Int = self._buyerKey(wallet, index);
            if (self.buyerVaults.exists(key)) { return self.buyerVaults.get(key)!!; }
            return 0;
        }
        let key: Int = self._sellerKey(wallet, index);
        if (self.sellerVaults.exists(key)) { return self.sellerVaults.get(key)!!; }
        return 0;
    }
}
