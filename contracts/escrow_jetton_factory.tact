import "@stdlib/ownable";
import "./escrow_jetton_vault";

// ============================================================
// EscrowJettonFactory (V2) — deploys EscrowJettonVault instances
// ============================================================
//
// Mirrors EscrowFactory (V1): sequential tradeId, deterministic vault address,
// wallet registry, time-locked critical params, bond-fee accounting.
//
// V2 additions:
//   • A configured `jettonMaster` (phase 1 = USDT). CreateJettonEscrow must name
//     this exact master (phase 2 will relax to a whitelist). tradeValue is in the
//     jetton's minimal units; the TON paid only covers the deployment fee + the
//     vault's TON gas budget (jetton transfers cost TON).
// ============================================================

message(0x2002) CreateJettonEscrow {
    buyer: Address;
    seller: Address;
    jettonMaster: Address;     // must equal the factory's configured master
    tradeValue: Int as coins;  // jetton minimal units
    tradeId: Int as uint64;    // ignored; factory assigns its own
    deadline: Int as uint32;
    nonce: Int as uint256;     // client idempotency key — one per trade FORM, reused on retry
}

message(0x2005) WithdrawFees {}

// NOTE: V1's UpdateArbitratorFee (op 0x2007) is intentionally absent here.
// V2 never charged a per-dispute arbitrator fee — the field existed but was
// never passed to the vault, so setting it did nothing while looking like it
// worked. Dispute compensation on the regular vault is the `daoFee` chosen at
// ResolveDispute (capped at 10% of the pool); the milestone vault uses a
// buyer-prefunded disputeFee. Op 0x2007 is left unused rather than recycled, so
// a stale client sending the old message fails loudly instead of hitting an
// unrelated handler.

message(0x2009) UpdateCommissionairesDao {
    newCommissionairesDao: Address;
}

message(0x200A) UpdateOperationalReserve {
    newOperationalReserve: Int as coins;
}

// Owner-only AND TIMELOCKED: point new vaults at a different jetton master
// (phase-2 whitelist will supersede this). Existing vaults keep the master they
// were created with.
//
// Timelocked because jettonMaster decides WHICH asset this factory escrows —
// the most consequential parameter here, so it gets at least the protection the
// numeric params already have (design doc §6.7). An instant switch would let a
// compromised owner silently redirect new vaults to a master it controls; that
// master can then hand each vault an attacker-owned "jetton wallet", whose
// forged transfer notifications the vault would credit as real deposits. The
// delay gives users and the remaining multisig signers a window to react.
message(0x2010) ScheduleJettonMaster {
    newJettonMaster: Address;
}
message(0x2011) ApplyJettonMaster {}
message(0x2012) CancelJettonMaster {}

message(0x200B) ScheduleParamChange {
    param:  Int as uint8;
    value:  Int as coins;
}

message(0x200C) ApplyParamChange {}
message(0x200D) CancelParamChange {}

message(0x200E) UpdateTimelockDelay {
    newDelay: Int as uint32;
}

message(0xF002) EvtJettonVaultDeployed {
    vaultAddress: Address;
    buyer: Address;
    seller: Address;
    jettonMaster: Address;
    tradeValue: Int as coins;
    tradeId: Int as uint64;
}

struct JettonFactoryConfig {
    owner: Address;
    jettonMaster: Address;
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
    // Pending jetton-master change; pendingJettonMasterAt == 0 means none.
    // Exposed so a scheduled asset switch is visible on-chain during the
    // timelock window rather than only at the moment it lands.
    pendingJettonMaster: Address;
    pendingJettonMasterAt: Int as uint32;
}

contract EscrowJettonFactory with Ownable {

    owner: Address;

    // The jetton this factory escrows (phase 1: USDT master).
    jettonMaster: Address;

    deploymentFee: Int as coins;
    commissionairesDao: Address;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    minTradeValue: Int as coins;          // in jetton minimal units
    operationalReserve: Int as coins;

    // TON gas budget forwarded to each new vault (wallet discovery + refunds +
    // payouts the vault initiates). Withdrawers fund their own withdrawal gas.
    const VaultGasBudget: Int = ton("0.5");

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
    pendingTradeValue: map<Int, Int as coins>;
    pendingRefund:    map<Int, Int as coins>;
    pendingTradeByVault: map<Address, Int as uint64>;

    // Idempotency guard: hash(creator, nonce) → true once a create has been
    // accepted. A repeat of the SAME trade form (same nonce from the same
    // wallet — i.e. a double-click, wallet rebroadcast, or retry) is rejected
    // so the payment bounces instead of spawning a second vault.
    // Released again in bounced() if the vault deploy fails, so a genuine retry
    // of the same form still works — the guard exists to stop duplicate vaults,
    // not to permanently burn a form that never produced one.
    seenTradeNonce: map<Int, Bool>;
    // tradeId → nonceKey, so bounced() knows which guard entry to release.
    pendingNonceKey: map<Int, Int>;

    init(
        owner: Address,
        commissionairesDao: Address,
        jettonMaster: Address,
    ) {
        self.owner = owner;
        self.jettonMaster = jettonMaster;
        // 1.5 TON — the platform fee, accrued to the factory and withdrawable to
        // the DAO/stakers via WithdrawFees. Deliberately higher than V1's 0.5:
        // a jetton vault costs more to run than a native-TON one (wallet
        // discovery + every payout is a jetton transfer). Adjustable later via
        // the 24h timelock (ScheduleParamChange param=1).
        //
        // NOTE: creation requires msgValue >= deploymentFee + VaultGasBudget, so
        // this is coupled to the frontend's JETTON_CREATE_TON (must be >= 2.0).
        // Raising it without raising that makes every create fail.
        self.deploymentFee = ton("1.5");
        self.commissionairesDao = commissionairesDao;
        self.guaranteePercent = 2;
        self.commissionPercent = 1;
        self.minTradeValue = 1;               // 1 jetton minimal unit (set real min via timelock)
        self.operationalReserve = ton("2");
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

    // ========================================
    // CreateJettonEscrow
    // ========================================

    receive(msg: CreateJettonEscrow) {
        // Idempotency: reject a repeat of the same trade form from the same
        // wallet. The inbound message is bounceable, so throwing here returns
        // the TON (minus gas) to the creator instead of deploying a 2nd vault.
        let nonceKey: Int = beginCell().storeAddress(sender()).storeUint(msg.nonce, 256).endCell().hash();
        require(!self.seenTradeNonce.exists(nonceKey), "Duplicate trade submission");
        self.seenTradeNonce.set(nonceKey, true);

        require(msg.jettonMaster == self.jettonMaster, "Unsupported jetton");
        require(msg.tradeValue >= self.minTradeValue, "Trade value below minimum");
        require(msg.tradeValue > 0, "Trade value must be positive");
        require(msg.buyer != msg.seller, "Buyer and seller must differ");
        // L-3: the commissionairesDao receives the commission payout; it must not
        // also be a trade party or it gains an unfair double claim on the pool.
        require(msg.buyer != self.commissionairesDao && msg.seller != self.commissionairesDao, "Trade party cannot be commissionaires DAO");
        require(msg.deadline > now() + 3600, "Deadline must be at least 1 hour in the future");

        // TON paid must cover the deployment fee + the vault's gas budget.
        let msgValue: Int = context().value;
        require(msgValue >= self.deploymentFee + self.VaultGasBudget, "Insufficient deployment fee + gas");

        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        let vaultInit: StateInit = initOf EscrowJettonVault(
            myAddress(),
            tradeId
        );
        let vaultAddress: Address = contractAddress(vaultInit);

        self.pendingBuyer.set(tradeId, msg.buyer);
        self.pendingSeller.set(tradeId, msg.seller);
        self.pendingCreator.set(tradeId, sender());
        self.pendingTradeValue.set(tradeId, msg.tradeValue);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingTradeByVault.set(vaultAddress, tradeId);
        self.pendingNonceKey.set(tradeId, nonceKey);

        send(SendParameters{
            to: vaultAddress,
            value: msgValue - self.deploymentFee,   // forward gas budget to the vault
            mode: 0,
            bounce: true,
            code: vaultInit.code,
            data: vaultInit.data,
            body: InitVault{
                tradeId: tradeId,
                buyer: msg.buyer,
                seller: msg.seller,
                creator: sender(),   // funded the gas budget; gets the residual back
                owner: self.owner,   // DAO arbitrator, becomes vault.owner
                jettonMaster: self.jettonMaster,
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

        emit(EvtJettonVaultDeployed{
            vaultAddress: vaultAddress,
            buyer: buyer,
            seller: seller,
            jettonMaster: self.jettonMaster,
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

        // The vault never came into existence, so this trade form produced no
        // vault. Release the idempotency guard so the creator can retry the same
        // form; leaving it set would block that form forever.
        if (self.pendingNonceKey.exists(tradeId)) {
            self.seenTradeNonce.del(self.pendingNonceKey.get(tradeId)!!);
        }

        // L-5: credit the ~0.02 TON bounce-handling overhead to fees so the
        // accounting stays accurate (the factory absorbed this gas cost).
        let bounceDust: Int = ton("0.02");
        self.totalFeesCollected = self.totalFeesCollected + bounceDust;

        let refundableBalance: Int = self.deploymentFee + context().value - bounceDust;
        if (refundableBalance < 0) {
            refundableBalance = 0;
        }
        let refundAmount: Int = min(self.pendingRefund.get(tradeId)!!, refundableBalance);

        send(SendParameters{
            to: creator,
            value: refundAmount,
            mode: 0,
            bounce: false,
            body: "Jetton escrow vault deployment failed".asComment()
        });

        self.clearPendingTrade(tradeId);
    }

    // ========================================
    // Wallet Registry helpers (identical to V1)
    // ========================================

    fun _buyerKey(wallet: Address, index: Int): Int {
        return beginCell().storeUint(0, 1).storeAddress(wallet).storeUint(index, 32).endCell().hash();
    }

    fun _sellerKey(wallet: Address, index: Int): Int {
        return beginCell().storeUint(1, 1).storeAddress(wallet).storeUint(index, 32).endCell().hash();
    }

    fun _registerBuyerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.buyerVaultCount.exists(wallet)) {
            count = self.buyerVaultCount.get(wallet)!!;
        }
        self.buyerVaults.set(self._buyerKey(wallet, count), tradeId);
        self.buyerVaultCount.set(wallet, count + 1);
    }

    fun _registerSellerVault(wallet: Address, tradeId: Int) {
        let count: Int = 0;
        if (self.sellerVaultCount.exists(wallet)) {
            count = self.sellerVaultCount.get(wallet)!!;
        }
        self.sellerVaults.set(self._sellerKey(wallet, count), tradeId);
        self.sellerVaultCount.set(wallet, count + 1);
    }

    fun clearPendingTrade(tradeId: Int) {
        let vaultAddress: Address = contractAddress(initOf EscrowJettonVault(myAddress(), tradeId));
        self.pendingBuyer.del(tradeId);
        self.pendingSeller.del(tradeId);
        self.pendingCreator.del(tradeId);
        self.pendingTradeValue.del(tradeId);
        self.pendingRefund.del(tradeId);
        self.pendingTradeByVault.del(vaultAddress);
        // Note: only the tradeId→nonceKey lookup is dropped here. The
        // seenTradeNonce entry itself is deliberately KEPT on the success path
        // (VaultInitOk) — that form did produce a vault and must not be
        // replayable. bounced() releases it explicitly before calling this.
        self.pendingNonceKey.del(tradeId);
    }

    // ========================================
    // Admin
    // ========================================

    receive(msg: ScheduleJettonMaster) {
        self.requireOwner();
        require(msg.newJettonMaster != self.jettonMaster, "Already the active jetton master");
        self.pendingJettonMaster   = msg.newJettonMaster;
        self.pendingJettonMasterAt = now() + self.timelockDelay;
        cashback(sender());
    }

    receive(msg: ApplyJettonMaster) {
        self.requireOwner();
        require(self.pendingJettonMasterAt != 0,           "No pending jetton master change");
        require(now() >= self.pendingJettonMasterAt,       "Timelock not yet expired");
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
        require(msg.param >= 1 && msg.param <= 4, "Unknown param opcode");
        if (msg.param == 1) { require(msg.value >= ton("0.1"), "deploymentFee too low"); }
        if (msg.param == 2) { require(msg.value > 0, "minTradeValue must be positive"); }
        if (msg.param == 3) { require(msg.value <= 10, "commissionPercent max 10"); }
        if (msg.param == 4) { require(msg.value > 0 && msg.value <= 20, "guaranteePercent must be 1-20"); }
        self.pendingParam       = msg.param;
        self.pendingValue       = msg.value;
        self.pendingEffectiveAt = now() + self.timelockDelay;
        cashback(sender());
    }

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

    receive(msg: CancelParamChange) {
        self.requireOwner();
        require(self.pendingParam != 0, "No pending change");
        self.pendingParam       = 0;
        self.pendingValue       = 0;
        self.pendingEffectiveAt = 0;
        cashback(sender());
    }

    receive(msg: UpdateTimelockDelay) {
        self.requireOwner();
        require(msg.newDelay >= 86400, "Timelock delay minimum is 24h");
        self.timelockDelay = msg.newDelay;
        cashback(sender());
    }

    receive(msg: UpdateCommissionairesDao) {
        self.requireOwner();
        self.commissionairesDao = msg.newCommissionairesDao;
        cashback(sender());
    }

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

    receive(msg: UpdateOperationalReserve) {
        self.requireOwner();
        require(msg.newOperationalReserve >= ton("0.5"), "Operational reserve too low");
        self.operationalReserve = msg.newOperationalReserve;
        cashback(sender());
    }

    // ========================================
    // Getters
    // ========================================

    get fun factoryConfig(): JettonFactoryConfig {
        return JettonFactoryConfig{
            owner: self.owner,
            jettonMaster: self.jettonMaster,
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
            pendingEffectiveAt: self.pendingEffectiveAt,
            pendingJettonMaster: self.pendingJettonMaster,
            pendingJettonMasterAt: self.pendingJettonMasterAt
        };
    }

    get fun totalVaults(): Int { return self.totalVaultsDeployed; }
    get fun deploymentFeeAmount(): Int { return self.deploymentFee; }
    get fun jettonMasterAddr(): Address { return self.jettonMaster; }
    // minTradeValue is already in factoryConfig(), but that's a struct getter;
    // this plain-Int getter mirrors EscrowFactory.minTradeValueAmount() so the
    // frontend can fetch both factories' live minimums with the same call shape.
    get fun minTradeValueAmount(): Int { return self.minTradeValue; }

    get fun vaultAddress(tradeId: Int): Address {
        let vaultInit: StateInit = initOf EscrowJettonVault(myAddress(), tradeId);
        return contractAddress(vaultInit);
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
