import "@stdlib/ownable";
import "./escrow_vault";

// ============================================================
// Factory Messages
// ============================================================

message(0x2001) CreateEscrow {
    buyer: Address;
    seller: Address;
    tradeValue: Int as coins;
    tradeId: Int as uint64;    // ignored by factory — included for ABI compatibility; factory assigns its own sequential ID
    deadline: Int as uint32;   // unix timestamp; REQUIRED, must be >1h in the future
}

message(0x2005) WithdrawFees {}

message(0x2007) UpdateArbitratorFee {
    newArbitratorFee: Int as coins;
}

message(0x2009) UpdateCommissionairesDao {
    newCommissionairesDao: Address;
}

message(0x200A) UpdateOperationalReserve {
    newOperationalReserve: Int as coins;
}

// ─── Time-lock messages ───────────────────────────────────────────────────────
// Critical parameter changes (deploymentFee, minTradeValue, commissionPercent,
// guaranteePercent) require a two-step process: schedule → wait → apply.
// Param opcodes: 1=deploymentFee  2=minTradeValue  3=commissionPercent  4=guaranteePercent

message(0x200B) ScheduleParamChange {
    param:  Int as uint8;
    value:  Int as coins;  // uint8 percents are also stored here (cast on apply)
}

message(0x200C) ApplyParamChange {}

message(0x200D) CancelParamChange {}

message(0x200E) UpdateTimelockDelay {
    newDelay: Int as uint32;  // seconds; minimum 3600 enforced
}

// ============================================================
// Factory Events
// ============================================================

message(0xF001) EvtVaultDeployed {
    vaultAddress: Address;
    buyer: Address;
    seller: Address;
    tradeValue: Int as coins;
    tradeId: Int as uint64;
}

// ============================================================
// Getter structs
// ============================================================

struct FactoryConfig {
    owner: Address;
    deploymentFee: Int as coins;
    commissionairesDao: Address;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    totalVaultsDeployed: Int as uint32;
    totalFeesCollected: Int as coins;
    operationalReserve: Int as coins;
    timelockDelay: Int as uint32;
    pendingParam: Int as uint8;
    pendingValue: Int as coins;
    pendingEffectiveAt: Int as uint32;
}

// ============================================================
// EscrowFactory Contract
// ============================================================
//
// The factory creates new EscrowVault instances.
// Creating an escrow requires paying a bond fee in TON.
// The factory tracks all vaults via a sequential ID.
//
// Wallet Registry:
//   Per-wallet index maps allow O(walletVaults) discovery
//   instead of scanning all vaults. Each wallet's involvement
//   (as buyer or seller) is recorded at creation time.
//
// Owner = Garantor DAO (can update fees, withdraw collected fees)
// ============================================================

contract EscrowFactory with Ownable {

    // === Ownable ===
    owner: Address;

    // === Config ===
    deploymentFee: Int as coins;            // Minimum deployment fee (default 0.5 TON)
    commissionairesDao: Address;            // DAO that receives trade commissions
    guaranteePercent: Int as uint8;         // Default seller guarantee (e.g. 2%)
    commissionPercent: Int as uint8;        // Default platform commission (e.g. 1%)
    arbitratorFee: Int as coins;            // Fee for dispute arbitration (default 0.1 TON)
    minTradeValue: Int as coins;            // Minimum trade value (default 1 TON)
    operationalReserve: Int as coins;       // TON kept in factory for storage rent (default 2 TON)

    // === Time-lock ===
    timelockDelay:      Int as uint32;      // seconds between schedule and apply (default 86400 = 24h)
    pendingParam:       Int as uint8;       // 0 = no pending change; 1-4 = param opcode
    pendingValue:       Int as coins;       // pending new value
    pendingEffectiveAt: Int as uint32;      // unix timestamp when change can be applied

    // === Counters ===
    totalVaultsDeployed: Int as uint32;
    totalFeesCollected: Int as coins;
    nextTradeId: Int as uint64;

    // === Wallet Registry ===
    // Tracks how many vaults each wallet participates in (as buyer or seller).
    // Uses hash-indexed maps for (address, index) → tradeId lookups.
    buyerVaultCount:  map<Address, Int as uint32>;
    sellerVaultCount: map<Address, Int as uint32>;
    buyerVaults:      map<Int, Int as uint64>;   // hash(address || index) → tradeId
    sellerVaults:     map<Int, Int as uint64>;    // hash(address || index) → tradeId
    pendingBuyer:     map<Int, Address>;
    pendingSeller:    map<Int, Address>;
    pendingCreator:   map<Int, Address>;
    pendingTradeValue: map<Int, Int as coins>;
    pendingRefund:    map<Int, Int as coins>;
    pendingTradeByVault: map<Address, Int as uint64>;

    // ========================================
    // Constructor
    // ========================================

    init(
        owner: Address,
        commissionairesDao: Address,
    ) {
        self.owner = owner;
        self.deploymentFee = ton("0.5");      // Minimum deployment fee
        self.commissionairesDao = commissionairesDao;
        self.guaranteePercent = 2;
        self.commissionPercent = 1;
        self.arbitratorFee = ton("0.1");      // Arbitration fee
        self.minTradeValue = ton("1");        // Minimum trade value
        self.operationalReserve = ton("2");   // Kept as rent buffer; never withdrawn
        self.timelockDelay      = 86400;      // 24 hours default
        self.pendingParam       = 0;
        self.pendingValue       = 0;
        self.pendingEffectiveAt = 0;
        self.totalVaultsDeployed = 0;
        self.totalFeesCollected = 0;
        self.nextTradeId = 1;
    }

    // ========================================
    // Receiver: CreateEscrow
    receive(msg: CreateEscrow) {
        // Validate
        require(msg.tradeValue >= self.minTradeValue, "Trade value below minimum");
        require(msg.tradeValue > 0, "Trade value must be positive");
        require(msg.buyer != msg.seller, "Buyer and seller must differ");
        // SECURITY: require a real future deadline. deadline == 0 (or past) leaves the
        // vault with no CheckExpiry path, so a ghosting seller forces every exit through
        // a dispute. Minimum 1 hour in the future.
        require(msg.deadline > now() + 3600, "Deadline must be at least 1 hour in the future");

        // Check deployment fee payment
        let msgValue: Int = context().value;
        require(msgValue >= self.deploymentFee + ton("0.35"), "Insufficient deployment fee + gas");

        // Assign trade ID
        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        // Compute vault init state (deterministic address)
        let vaultInit: StateInit = initOf EscrowVault(
            myAddress(),        // factory address
            self.owner,         // DAO address (owner of vault for dispute resolution)
            tradeId             // unique seqno for deterministic address
        );
        let vaultAddress: Address = contractAddress(vaultInit);

        self.pendingBuyer.set(tradeId, msg.buyer);
        self.pendingSeller.set(tradeId, msg.seller);
        self.pendingCreator.set(tradeId, sender());
        self.pendingTradeValue.set(tradeId, msg.tradeValue);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingTradeByVault.set(vaultAddress, tradeId);

        // Deploy vault and initialize it in a single send
        send(SendParameters{
            to: vaultAddress,
            value: msgValue - self.deploymentFee,  // forward remaining value after collecting deployment fee
            mode: 0,
            bounce: true,
            code: vaultInit.code,
            data: vaultInit.data,
            body: InitVault{
                tradeId: tradeId,
                buyer: msg.buyer,
                seller: msg.seller,
                tradeValue: msg.tradeValue,
                guaranteePercent: self.guaranteePercent,
                commissionPercent: self.commissionPercent,
                commissionairesDao: self.commissionairesDao,
                deadline: msg.deadline
            }.toCell()
        });
    }

    receive(msg: VaultInitOk) {
        let vaultAddress: Address = sender();
        require(self.pendingTradeByVault.exists(vaultAddress), "Only deployed vault");
        require(self.pendingTradeByVault.get(vaultAddress)!! == msg.tradeId, "Mismatched pending vault");
        require(self.pendingCreator.exists(msg.tradeId), "Unknown pending trade");

        let buyer: Address = self.pendingBuyer.get(msg.tradeId)!!;
        let seller: Address = self.pendingSeller.get(msg.tradeId)!!;
        let tradeValue: Int = self.pendingTradeValue.get(msg.tradeId)!!;

        self.totalFeesCollected = self.totalFeesCollected + self.deploymentFee;
        self._registerBuyerVault(buyer, msg.tradeId);
        self._registerSellerVault(seller, msg.tradeId);
        self.totalVaultsDeployed = self.totalVaultsDeployed + 1;

        emit(EvtVaultDeployed{
            vaultAddress: vaultAddress,
            buyer: buyer,
            seller: seller,
            tradeValue: tradeValue,
            tradeId: msg.tradeId
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
            body: "Escrow vault deployment failed".asComment()
        });

        self.clearPendingTrade(tradeId);
    }

    // ========================================
    // Wallet Registry: internal helpers
    // ========================================

    fun _buyerKey(wallet: Address, index: Int): Int {
        return beginCell()
            .storeUint(0, 1)              // 0 = buyer namespace
            .storeAddress(wallet)
            .storeUint(index, 32)
            .endCell()
            .hash();
    }

    fun _sellerKey(wallet: Address, index: Int): Int {
        return beginCell()
            .storeUint(1, 1)              // 1 = seller namespace
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

    fun clearPendingTrade(tradeId: Int) {
        let vaultAddress: Address = contractAddress(initOf EscrowVault(myAddress(), self.owner, tradeId));
        self.pendingBuyer.del(tradeId);
        self.pendingSeller.del(tradeId);
        self.pendingCreator.del(tradeId);
        self.pendingTradeValue.del(tradeId);
        self.pendingRefund.del(tradeId);
        self.pendingTradeByVault.del(vaultAddress);
    }

    // ========================================
    // Admin: Time-lock — schedule a critical parameter change
    // ========================================
    // Param opcodes: 1=deploymentFee  2=minTradeValue  3=commissionPercent  4=guaranteePercent

    receive(msg: ScheduleParamChange) {
        self.requireOwner();
        require(msg.param >= 1 && msg.param <= 4, "Unknown param opcode");
        // Validate the incoming value before scheduling
        if (msg.param == 1) { require(msg.value >= ton("0.1"), "deploymentFee too low"); }
        if (msg.param == 2) { require(msg.value > 0, "minTradeValue must be positive"); }
        if (msg.param == 3) { require(msg.value <= 10, "commissionPercent max 10"); }
        if (msg.param == 4) { require(msg.value > 0 && msg.value <= 20, "guaranteePercent must be 1-20"); }
        self.pendingParam       = msg.param;
        self.pendingValue       = msg.value;
        self.pendingEffectiveAt = now() + self.timelockDelay;
        cashback(sender());
    }

    // ========================================
    // Admin: Time-lock — apply a scheduled change (after delay has passed)
    // ========================================

    receive(msg: ApplyParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0,              "No pending change");
        require(now() >= self.pendingEffectiveAt,    "Timelock not yet expired");
        if (self.pendingParam == 1) { self.deploymentFee    = self.pendingValue; }
        if (self.pendingParam == 2) { self.minTradeValue    = self.pendingValue; }
        if (self.pendingParam == 3) { self.commissionPercent = self.pendingValue; }
        if (self.pendingParam == 4) { self.guaranteePercent  = self.pendingValue; }
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
    // Admin: Update arbitrator fee (instant — operational, not user-facing)
    // ========================================

    receive(msg: UpdateArbitratorFee) {
        self.requireOwner();
        require(msg.newArbitratorFee >= 0, "Arbitrator fee cannot be negative");
        self.arbitratorFee = msg.newArbitratorFee;
        cashback(sender());
    }

    // ========================================
    // Admin: Update commissionaires DAO wallet
    // ========================================

    receive(msg: UpdateCommissionairesDao) {
        self.requireOwner();
        self.commissionairesDao = msg.newCommissionairesDao;
        cashback(sender());
    }

    // ========================================
    // Admin: Withdraw collected bond fees
    // ========================================

    receive(msg: WithdrawFees) {
        self.requireOwner();
        let withdrawable: Int = min(myBalance() - self.operationalReserve, self.totalFeesCollected);
        require(withdrawable > 0, "No fees to withdraw");

        send(SendParameters{
            to: sender(),
            value: withdrawable,
            mode: 0,
            bounce: false,
            body: "Factory fee withdrawal".asComment()
        });

        self.totalFeesCollected = self.totalFeesCollected - withdrawable;
    }

    // ========================================
    // Admin: Update operational reserve
    // ========================================

    receive(msg: UpdateOperationalReserve) {
        self.requireOwner();
        require(msg.newOperationalReserve >= ton("0.5"), "Operational reserve too low");
        self.operationalReserve = msg.newOperationalReserve;
        cashback(sender());
    }

    // ========================================
    // Getters
    // ========================================

    get fun factoryConfig(): FactoryConfig {
        return FactoryConfig{
            owner: self.owner,
            deploymentFee: self.deploymentFee,
            commissionairesDao: self.commissionairesDao,
            guaranteePercent: self.guaranteePercent,
            commissionPercent: self.commissionPercent,
            totalVaultsDeployed: self.totalVaultsDeployed,
            totalFeesCollected: self.totalFeesCollected,
            operationalReserve: self.operationalReserve,
            timelockDelay: self.timelockDelay,
            pendingParam: self.pendingParam,
            pendingValue: self.pendingValue,
            pendingEffectiveAt: self.pendingEffectiveAt
        };
    }

    get fun totalVaults(): Int {
        return self.totalVaultsDeployed;
    }

    get fun deploymentFeeAmount(): Int {
        return self.deploymentFee;
    }

    // Compute the vault address for a given tradeId (useful for off-chain lookups)
    get fun vaultAddress(tradeId: Int): Address {
        let vaultInit: StateInit = initOf EscrowVault(myAddress(), self.owner, tradeId);
        return contractAddress(vaultInit);
    }

    // ── Wallet Registry Getters ──────────────────────────────────

    // Returns the number of vaults a wallet is involved in as buyer or seller.
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

    // Returns the tradeId at a given index for a wallet's buyer or seller registry.
    // Index is 0-based: 0 = first vault, 1 = second, etc.
    // Returns 0 if index is out of range (no vault at that slot).
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
}
