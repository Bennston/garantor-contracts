import "@stdlib/ownable";
import "./escrow_vault_milestone";

// ─── Messages ─────────────────────────────────────────────────────────────────

// Sent by trade creator to the factory to create a new milestone vault.
// Creator attaches deploymentFee + gas TON. Buyer deposits milestone value later.
message(0x3001) CreateMilestoneVault {
    buyer:              Address;        // buyer wallet (may differ from sender for bots/delegated flows)
    seller:             Address;
    arbitrator:         Address;
    referrer:           Address;
    referrerFeeBps:     Int as uint16;  // 100 = 1%, 0 = no referrer
    milestoneCount:     Int as uint8;   // must be 2
    m0Value:            Int as coins;
    m1Value:            Int as coins;
    m0Window:           Int as uint32;  // buyer review window seconds
    m1Window:           Int as uint32;  // buyer review window seconds
    m0DeliveryWindow:   Int as uint32;  // seller delivery window seconds (time to submit M0 docs after activation)
    m1DeliveryWindow:   Int as uint32;  // seller delivery window seconds (time to submit M1 docs after M0 resolves)
    performanceBond:    Int as coins;
    tradeRef:           String;
}

// Admin messages for instant (non-timelocked) operational parameters
message(0x3003) UpdateArbitratorFee {
    newArbitratorFee: Int as coins;
}

message(0x3005) WithdrawFees {}

message(0x3006) UpdateOperationalReserve {
    newOperationalReserve: Int as coins;
}

// ─── Time-lock messages ───────────────────────────────────────────────────────
// Critical parameter changes require a two-step process: schedule → wait → apply.
// Param opcodes: 1=deploymentFee  2=minTradeValue

message(0x3009) ScheduleParamChange {
    param:  Int as uint8;
    value:  Int as coins;
}

message(0x300A) ApplyParamChange {}

message(0x300B) CancelParamChange {}

message(0x300C) UpdateTimelockDelay {
    newDelay: Int as uint32;  // minimum 3600 enforced
}

// ─── Events ───────────────────────────────────────────────────────────────────

message(0xF101) EvtMilestoneVaultDeployed {
    vaultAddress: Address;
    buyer:        Address;
    seller:       Address;
    tradeId:      Int as uint64;
    creator:      Address;           // msg sender (= buyer in normal flow)
}

// ─── Config struct (for getter) ───────────────────────────────────────────────

struct MilestoneFactoryConfig {
    owner:               Address;
    totalVaultsDeployed: Int as uint32;
    deploymentFee:       Int as coins;
    arbitratorFee:       Int as coins;
    minTradeValue:       Int as coins;
    operationalReserve:  Int as coins;
    totalFeesCollected:  Int as coins;
    timelockDelay:       Int as uint32;
    pendingParam:        Int as uint8;
    pendingValue:        Int as coins;
    pendingEffectiveAt:  Int as uint32;
}

// ─── Factory contract ─────────────────────────────────────────────────────────
//
// Deploys EscrowVaultMilestone vaults for milestone trades.
// Because the factory already exists on-chain, the buyer's TonConnect transaction
// has no stateInit — avoiding wallet compatibility issues with stateInit stripping.
//
// The factory sends an internal message to the vault with stateInit+body,
// which is always supported.
//
// Wallet registry (same pattern as EscrowFactory):
//   Per-wallet index maps allow O(1) vault discovery by buyer or seller.

contract EscrowMilestoneFactory with Ownable {

    owner:               Address;
    deploymentSalt:      Int as uint32; // bump to force a new factory address on redeploy
    nextTradeId:         Int as uint64;
    totalVaultsDeployed: Int as uint32;

    // Configurable parameters
    deploymentFee:       Int as coins;  // minimum deployment fee (currently 1.77 TON)
    arbitratorFee:       Int as coins;  // arbitrator fee per milestone
    minTradeValue:       Int as coins;  // minimum total trade value
    operationalReserve:  Int as coins;  // TON kept in factory to fund future deployments and rent
    totalFeesCollected:  Int as coins;  // collected fees for withdrawal

    // Time-lock
    timelockDelay:       Int as uint32; // seconds between schedule and apply (default 86400 = 24h)
    pendingParam:        Int as uint8;  // 0 = none; 1=deploymentFee  2=minTradeValue
    pendingValue:        Int as coins;
    pendingEffectiveAt:  Int as uint32;

    // Per-wallet registry
    buyerVaultCount:    map<Address, Int as uint32>;
    sellerVaultCount:   map<Address, Int as uint32>;
    referrerVaultCount: map<Address, Int as uint32>;
    buyerVaults:        map<Int, Int as uint64>;   // hash(address || index) → tradeId
    sellerVaults:       map<Int, Int as uint64>;   // hash(address || index) → tradeId
    referrerVaults:     map<Int, Int as uint64>;   // hash(address || index) → tradeId
    pendingBuyer:       map<Int, Address>;
    pendingSeller:      map<Int, Address>;
    pendingCreator:     map<Int, Address>;
    pendingReferrer:    map<Int, Address>;
    pendingReferrerFeeBps: map<Int, Int as uint16>;
    pendingRefund:      map<Int, Int as coins>;
    pendingTradeByVault: map<Address, Int as uint64>;

    // ─── Init ─────────────────────────────────────────────────────────────────
    init(owner: Address, deploymentSalt: Int) {
        self.owner               = owner;
        self.deploymentSalt      = deploymentSalt;
        self.nextTradeId         = 1;
        self.totalVaultsDeployed = 0;

        // Initialize configurable parameters
        self.deploymentFee       = ton("1.77");  // minimum deployment fee for milestone vaults
        self.arbitratorFee       = ton("0.1");   // arbitrator fee per milestone
        self.minTradeValue       = ton("1");     // minimum total trade value
        self.operationalReserve  = ton("2");     // keep enough headroom for multiple deployments
        self.totalFeesCollected  = 0;
        self.timelockDelay       = 86400;        // 24 hours default
        self.pendingParam        = 0;
        self.pendingValue        = 0;
        self.pendingEffectiveAt  = 0;
    }

    receive() {}

    // ─── CreateMilestoneVault ─────────────────────────────────────────────────
    receive(msg: CreateMilestoneVault) {
        require(msg.milestoneCount == 2,          "Exactly 2 milestones required");
        require(msg.m0Value > 0,                  "M0 value must be positive");
        require(msg.m1Value > 0,                  "M1 value must be positive");
        require(msg.buyer  != msg.seller,          "Buyer and seller must differ");
        // SECURITY: the arbitrator is PINNED to the factory owner (Garantor DAO
        // multisig), never taken from the caller. A caller-supplied arbitrator could
        // install a colluding resolver that rules releaseToSeller and drains the buyer,
        // so msg.arbitrator is ignored (see the forwarded body below).
        // FUTURE custom arbitration must go through an owner-managed allowlist of vetted
        // arbitrators — register approved resolvers via an admin message and check
        // membership here — never accept a raw caller value.
        require(self.owner != msg.buyer,           "Owner/arbitrator cannot be buyer");
        require(self.owner != msg.seller,          "Owner/arbitrator cannot be seller");
        require(msg.referrerFeeBps <= 1000,        "Referrer fee exceeds 10%");
        require(msg.referrerFeeBps == 0 || (msg.referrer != msg.buyer && msg.referrer != msg.seller), "Referrer cannot be a trade party");

        let total: Int    = msg.m0Value + msg.m1Value;
        let msgValue: Int = context().value;

        // Validate minimum trade value
        require(total >= self.minTradeValue, "Trade value below minimum");

        // Require deployment fee + gas (factory compute + vault deploy)
        require(msgValue >= self.deploymentFee + ton("0.25"), "Insufficient value: send deploymentFee + 0.25 TON gas");

        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        // Compute deterministic vault address
        let vaultInit: StateInit = initOf EscrowVaultMilestone(myAddress(), tradeId);
        let vaultAddress: Address = contractAddress(vaultInit);

        // Deploy vault and init in a single send.
        // Factory keeps deployment fee and forwards remaining gas buffer to vault.
        send(SendParameters{
            to:     vaultAddress,
            value:  msgValue - self.deploymentFee,  // keep deployment fee, forward rest
            mode:   0,                      // revert on action-phase failure
            bounce: true,
            code:   vaultInit.code,
            data:   vaultInit.data,
            body:   InitMilestoneVault{
                tradeId:            tradeId,
                buyer:              msg.buyer,
                seller:             msg.seller,
                arbitrator:         self.owner,   // pinned to DAO, not caller-supplied (msg.arbitrator ignored)
                referrer:           msg.referrer,
                referrerFeeBps:     msg.referrerFeeBps,
                milestoneCount:     msg.milestoneCount,
                m0Value:            msg.m0Value,
                m1Value:            msg.m1Value,
                m0Window:           msg.m0Window,
                m1Window:           msg.m1Window,
                m0DeliveryWindow:   msg.m0DeliveryWindow,
                m1DeliveryWindow:   msg.m1DeliveryWindow,
                arbitratorFee:      self.arbitratorFee,
                performanceBond:    msg.performanceBond,
                tradeRef:           msg.tradeRef
            }.toCell()
        });

        self.pendingBuyer.set(tradeId, msg.buyer);
        self.pendingSeller.set(tradeId, msg.seller);
        self.pendingCreator.set(tradeId, sender());
        self.pendingReferrer.set(tradeId, msg.referrer);
        self.pendingReferrerFeeBps.set(tradeId, msg.referrerFeeBps);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingTradeByVault.set(vaultAddress, tradeId);
    }

    receive(msg: MilestoneVaultInitOk) {
        let vaultAddress: Address = contractAddress(initOf EscrowVaultMilestone(myAddress(), msg.tradeId));
        require(sender() == vaultAddress, "Only deployed vault");
        require(self.pendingCreator.exists(msg.tradeId), "Unknown pending trade");

        let buyer: Address = self.pendingBuyer.get(msg.tradeId)!!;
        let seller: Address = self.pendingSeller.get(msg.tradeId)!!;
        let creator: Address = self.pendingCreator.get(msg.tradeId)!!;
        let referrer: Address = self.pendingReferrer.get(msg.tradeId)!!;
        let referrerFeeBps: Int = self.pendingReferrerFeeBps.get(msg.tradeId)!!;

        self.totalFeesCollected = self.totalFeesCollected + self.deploymentFee;
        self._registerBuyerVault(buyer, msg.tradeId);
        self._registerSellerVault(seller, msg.tradeId);
        if (referrerFeeBps > 0) {
            self._registerReferrerVault(referrer, msg.tradeId);
        }
        self.totalVaultsDeployed = self.totalVaultsDeployed + 1;

        emit(EvtMilestoneVaultDeployed{
            vaultAddress: vaultAddress,
            buyer:        buyer,
            seller:       seller,
            tradeId:      msg.tradeId,
            creator:      creator
        }.toCell());

        self.clearPendingTrade(msg.tradeId);
    }

    bounced(msg: Slice) {
        let vaultAddress: Address = sender();
        if (!self.pendingTradeByVault.exists(vaultAddress)) {
            return;
        }

        let tradeId: Int = self.pendingTradeByVault.get(vaultAddress)!!;

        let creator: Address = self.pendingCreator.get(tradeId)!!;
        let refundableBalance: Int = self.deploymentFee + context().value - ton("0.02");
        if (refundableBalance < 0) {
            refundableBalance = 0;
        }
        let refundAmount: Int = min(self.pendingRefund.get(tradeId)!!, refundableBalance);

        send(SendParameters{
            to: creator,
            value: refundAmount,
            mode: 0,
            bounce: false,
            body: "Milestone vault deployment failed".asComment()
        });

        self.clearPendingTrade(tradeId);
    }

    // ─── Wallet registry helpers ──────────────────────────────────────────────

    fun _buyerKey(wallet: Address, index: Int): Int {
        return beginCell()
            .storeUint(0, 1)
            .storeAddress(wallet)
            .storeUint(index, 32)
            .endCell()
            .hash();
    }

    fun _sellerKey(wallet: Address, index: Int): Int {
        return beginCell()
            .storeUint(1, 1)
            .storeAddress(wallet)
            .storeUint(index, 32)
            .endCell()
            .hash();
    }

    fun _registerBuyerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.buyerVaultCount.exists(wallet)) {
            count = self.buyerVaultCount.get(wallet)!!;
        }
        let key: Int = self._buyerKey(wallet, count);
        self.buyerVaults.set(key, tradeId);
        self.buyerVaultCount.set(wallet, count + 1);
    }

    fun _registerSellerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.sellerVaultCount.exists(wallet)) {
            count = self.sellerVaultCount.get(wallet)!!;
        }
        let key: Int = self._sellerKey(wallet, count);
        self.sellerVaults.set(key, tradeId);
        self.sellerVaultCount.set(wallet, count + 1);
    }

    fun _referrerKey(wallet: Address, index: Int): Int {
        return beginCell()
            .storeUint(2, 2)
            .storeAddress(wallet)
            .storeUint(index, 32)
            .endCell()
            .hash();
    }

    fun _registerReferrerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.referrerVaultCount.exists(wallet)) {
            count = self.referrerVaultCount.get(wallet)!!;
        }
        let key: Int = self._referrerKey(wallet, count);
        self.referrerVaults.set(key, tradeId);
        self.referrerVaultCount.set(wallet, count + 1);
    }

    fun clearPendingTrade(tradeId: Int) {
        let vaultAddress: Address = contractAddress(initOf EscrowVaultMilestone(myAddress(), tradeId));
        self.pendingBuyer.del(tradeId);
        self.pendingSeller.del(tradeId);
        self.pendingCreator.del(tradeId);
        self.pendingReferrer.del(tradeId);
        self.pendingReferrerFeeBps.del(tradeId);
        self.pendingRefund.del(tradeId);
        self.pendingTradeByVault.del(vaultAddress);
    }

    // ─── Admin Functions ─────────────────────────────────────────────────────

    // ========================================
    // Admin: Time-lock — schedule a critical parameter change
    // Param opcodes: 1=deploymentFee  2=minTradeValue
    // ========================================

    receive(msg: ScheduleParamChange) {
        self.requireOwner();
        require(msg.param >= 1 && msg.param <= 2, "Unknown param opcode");
        if (msg.param == 1) { require(msg.value >= ton("1"), "deploymentFee too low"); }
        if (msg.param == 2) { require(msg.value > 0,         "minTradeValue must be positive"); }
        self.pendingParam       = msg.param;
        self.pendingValue       = msg.value;
        self.pendingEffectiveAt = now() + self.timelockDelay;
        cashback(sender());
    }

    // ========================================
    // Admin: Time-lock — apply a scheduled change after delay
    // ========================================

    receive(msg: ApplyParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0,           "No pending change");
        require(now() >= self.pendingEffectiveAt, "Timelock not yet expired");
        if (self.pendingParam == 1) { self.deploymentFee  = self.pendingValue; }
        if (self.pendingParam == 2) { self.minTradeValue  = self.pendingValue; }
        self.pendingParam       = 0;
        self.pendingValue       = 0;
        self.pendingEffectiveAt = 0;
        cashback(sender());
    }

    // ========================================
    // Admin: Time-lock — cancel a pending change
    // ========================================

    receive(msg: CancelParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0, "No pending change");
        self.pendingParam       = 0;
        self.pendingValue       = 0;
        self.pendingEffectiveAt = 0;
        cashback(sender());
    }

    // ========================================
    // Admin: Update the time-lock delay (minimum 1 hour)
    // ========================================

    receive(msg: UpdateTimelockDelay) {
        self.requireOwner();
        require(msg.newDelay >= 3600, "Timelock delay minimum is 1 hour");
        self.timelockDelay = msg.newDelay;
        cashback(sender());
    }

    // ========================================
    // Admin: Update arbitrator fee (instant — operational)
    // ========================================

    receive(msg: UpdateArbitratorFee) {
        self.requireOwner();
        require(msg.newArbitratorFee >= 0, "Arbitrator fee cannot be negative");
        self.arbitratorFee = msg.newArbitratorFee;
        cashback(sender());
    }

    // ========================================
    // Admin: Update operational reserve (instant — internal accounting)
    // ========================================

    receive(msg: UpdateOperationalReserve) {
        self.requireOwner();
        require(msg.newOperationalReserve >= ton("0.2"), "Operational reserve too low");
        self.operationalReserve = msg.newOperationalReserve;
        cashback(sender());
    }

    // ========================================
    // Admin: Withdraw collected deployment fees
    // ========================================

    receive(msg: WithdrawFees) {
        self.requireOwner();
        // Cap at the accounting ledger so we never withdraw gas/residue that
        // belongs to pending vault operations or the operational reserve.
        let withdrawable: Int = min(myBalance() - self.operationalReserve, self.totalFeesCollected);
        require(withdrawable > 0, "No fees to withdraw");

        send(SendParameters{
            to: sender(),
            value: withdrawable,
            mode: 0,
            bounce: false,
            body: "Milestone factory fee withdrawal".asComment()
        });

        self.totalFeesCollected = self.totalFeesCollected - withdrawable;
    }

    get fun config(): MilestoneFactoryConfig {
        return MilestoneFactoryConfig{
            owner:               self.owner,
            totalVaultsDeployed: self.totalVaultsDeployed,
            deploymentFee:       self.deploymentFee,
            arbitratorFee:       self.arbitratorFee,
            minTradeValue:       self.minTradeValue,
            operationalReserve:  self.operationalReserve,
            totalFeesCollected:  self.totalFeesCollected,
            timelockDelay:       self.timelockDelay,
            pendingParam:        self.pendingParam,
            pendingValue:        self.pendingValue,
            pendingEffectiveAt:  self.pendingEffectiveAt
        };
    }

    get fun totalVaults(): Int {
        return self.totalVaultsDeployed;
    }

    get fun nextId(): Int {
        return self.nextTradeId;
    }

    // Compute vault address for a given tradeId (deterministic)
    get fun vaultAddress(tradeId: Int): Address {
        let vaultInit: StateInit = initOf EscrowVaultMilestone(myAddress(), tradeId);
        return contractAddress(vaultInit);
    }

    // Number of vaults a wallet is registered in (as buyer or seller)
    get fun walletVaultCount(wallet: Address, isBuyer: Bool): Int {
        if (isBuyer) {
            if (self.buyerVaultCount.exists(wallet)) {
                return self.buyerVaultCount.get(wallet)!!;
            }
            return 0;
        }
        if (self.sellerVaultCount.exists(wallet)) {
            return self.sellerVaultCount.get(wallet)!!;
        }
        return 0;
    }

    // TradeId at a given 0-based index for a wallet (buyer or seller)
    get fun walletVaultAtIndex(wallet: Address, isBuyer: Bool, index: Int): Int {
        if (isBuyer) {
            let key: Int = self._buyerKey(wallet, index);
            if (self.buyerVaults.exists(key)) {
                return self.buyerVaults.get(key)!!;
            }
            return 0;
        }
        let key: Int = self._sellerKey(wallet, index);
        if (self.sellerVaults.exists(key)) {
            return self.sellerVaults.get(key)!!;
        }
        return 0;
    }

    // Number of vaults a referrer is registered in
    get fun referrerVaultCount(wallet: Address): Int {
        if (self.referrerVaultCount.exists(wallet)) {
            return self.referrerVaultCount.get(wallet)!!;
        }
        return 0;
    }

    // TradeId at a given 0-based index for a referrer wallet
    get fun referrerVaultAtIndex(wallet: Address, index: Int): Int {
        let key: Int = self._referrerKey(wallet, index);
        if (self.referrerVaults.exists(key)) {
            return self.referrerVaults.get(key)!!;
        }
        return 0;
    }
}
