import "@stdlib/ownable";
import "./escrow_oracle_vault";

// ============================================================
// MarketplaceListing (V3) — inventory layer over EscrowOracleVault
// ============================================================
//
// One listing = one seller offering N units of a product at a fixed price. Each
// purchase decrements remainingSupply and deploys ONE seeded EscrowOracleVault
// (V3, DON-oracle-settled). Vaults are deterministic from (listing, tradeId), so
// the buyer can predict the vault address and deposit the jetton into it.
//
// Mirrors the EscrowJettonFactory deploy pattern (deterministic address,
// VaultInitOk ack, bounce restore). Protocol params (fees, DAO, oracleRegistry)
// come from the owner (DAO); in production a MarketplaceFactory would deploy and
// configure listings — this slice lets the owner configure directly.
// See V3_ORACLE_MARKETPLACE_DESIGN.md §4.2.
// ============================================================

message(0x6001) ConfigureListing {
    seller: Address;                // set here (not in init) so the listing address derives from listingId alone
    pricePerUnit: Int as coins;     // vault tradeValue per unit (jetton minimal units)
    initialSupply: Int as uint32;
    validationType: Int as uint8;
    settlementMode: Int as uint8;   // 0 = oracle-only, 1 = manual-only (doc-hash); pinned per listing
    agreementCID: Cell?;            // IPFS CID of the signed terms (informational anchor)
}

message(0x6002) PurchaseListing {
    nonce: Int as uint256;          // buyer idempotency key (double-click / rebroadcast guard)
}

message(0x6003) SetListingActive {
    active: Bool;                   // owner emergency pause / resume
}

message(0x6005) DestroyListing {}   // seller or DAO tears the listing down + reclaims gas

// Ack sent to the owner (a MarketplaceFactory, or a wallet) once configured/active.
message(0x6004) ListingConfigured {
    listingId: Int as uint64;
    seller:    Address;
}

message(0xF103) EvtListingVaultDeployed {
    listingId:    Int as uint64;
    tradeId:      Int as uint64;
    vaultAddress: Address;
    buyer:        Address;
    seller:       Address;
    pricePerUnit: Int as coins;
}

struct ListingConfig {
    owner:              Address;
    dao:                Address;
    seller:             Address;
    jettonMaster:       Address;
    oracleRegistry:     Address;
    commissionairesDao: Address;
    listingId:          Int as uint64;
    pricePerUnit:       Int as coins;
    validationType:     Int as uint8;
    settlementMode:     Int as uint8;
    guaranteePercent:   Int as uint8;
    commissionPercent:  Int as uint8;
    deadlineWindow:     Int as uint32;
    active:             Bool;
    remainingSupply:    Int as uint32;
    vaultsDeployed:     Int as uint32;
}

contract MarketplaceListing with Ownable {

    owner: Address;                 // listing admin (a MarketplaceFactory, or the DAO directly)
    dao: Address;                   // arbitrator seeded into each vault (dispute owner)
    seller: Address;
    jettonMaster: Address;
    oracleRegistry: Address;
    commissionairesDao: Address;
    listingId: Int as uint64;

    pricePerUnit: Int as coins;
    validationType: Int as uint8;
    settlementMode: Int as uint8;
    agreementCID: Cell?;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    deadlineWindow: Int as uint32;

    active: Bool;
    remainingSupply: Int as uint32;
    nextTradeId: Int as uint64;
    vaultsDeployed: Int as uint32;

    // Purchases with a vault deploy still in flight (sent, not yet acked or
    // bounced). Blocks DestroyListing so a self-destructed listing can never
    // receive — and silently drop — a pending vault's ack/bounce.
    pendingCount: Int as uint32;

    // TON gas budget forwarded to each spawned vault (wallet discovery + payouts).
    const VaultGasBudget: Int = ton("0.5");

    pendingBuyer:   map<Int, Address>;
    pendingByVault: map<Address, Int as uint64>;
    pendingRefund:  map<Int, Int as coins>;
    seenNonce:      map<Int, Bool>;

    init(
        owner: Address,
        dao: Address,
        jettonMaster: Address,
        oracleRegistry: Address,
        commissionairesDao: Address,
        listingId: Int,
    ) {
        self.owner = owner;
        self.dao = dao;
        self.seller = owner;   // placeholder until ConfigureListing sets the real seller
        self.jettonMaster = jettonMaster;
        self.oracleRegistry = oracleRegistry;
        self.commissionairesDao = commissionairesDao;
        self.listingId = listingId;

        self.pricePerUnit = 0;
        self.validationType = 0;
        self.settlementMode = 0;
        self.agreementCID = null;
        self.guaranteePercent = 2;
        self.commissionPercent = 1;
        self.deadlineWindow = 2592000;   // 30 days

        self.active = false;
        self.remainingSupply = 0;
        self.nextTradeId = 1;
        self.vaultsDeployed = 0;
        self.pendingCount = 0;
    }

    // Empty-body deploy handler.
    receive() {}

    // ========================================
    // Owner: configure the product + inventory (one-time), then activate
    // ========================================
    receive(msg: ConfigureListing) {
        self.requireOwner();
        require(!self.active, "Already configured");
        require(msg.pricePerUnit > 0, "Price must be positive");
        require(msg.initialSupply > 0, "Supply must be positive");
        require(self.guaranteePercent > 0 && self.guaranteePercent <= 20, "Guarantee % must be 1-20");
        require(self.commissionPercent <= 10, "Commission cannot exceed 10%");
        require(msg.settlementMode <= 1, "Invalid settlement mode");

        self.seller = msg.seller;
        self.pricePerUnit = msg.pricePerUnit;
        self.validationType = msg.validationType;
        self.settlementMode = msg.settlementMode;
        self.agreementCID = msg.agreementCID;
        self.remainingSupply = msg.initialSupply;
        self.active = true;

        // Ack the owner (e.g. a MarketplaceFactory) that the listing is live.
        // A small fixed value — the listing RETAINS the rest of its deploy balance
        // as an operating buffer so mode-0 vault deploys on purchase have gas.
        send(SendParameters{
            to: sender(),
            value: ton("0.01"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: ListingConfigured{ listingId: self.listingId, seller: self.seller }.toCell()
        });
    }

    receive(msg: SetListingActive) {
        self.requireOwner();
        self.active = msg.active;
    }

    // ========================================
    // Delete / self-destruct (seller or DAO, anytime)
    // ========================================
    // Already-deployed vaults are independent contracts and keep settling on their
    // own — tearing down the listing only stops NEW purchases and returns the
    // listing's remaining gas to the seller who funded its creation.
    receive(msg: DestroyListing) {
        require(sender() == self.seller || sender() == self.dao, "Only seller or DAO");
        require(self.pendingCount == 0, "A purchase is still deploying its vault");
        self.active = false;
        self.remainingSupply = 0;
        send(SendParameters{
            to:     self.seller,
            value:  0,
            mode:   SendRemainingBalance + SendDestroyIfZero,
            bounce: false,
            body:   "Listing destroyed".asComment()
        });
    }

    // ========================================
    // Purchase: deploy one seeded EscrowOracleVault
    // ========================================
    receive(msg: PurchaseListing) {
        // Idempotency: a repeat of the same purchase form from the same wallet
        // bounces instead of spawning a second vault.
        let nonceKey: Int = beginCell().storeAddress(sender()).storeUint(msg.nonce, 256).endCell().hash();
        require(!self.seenNonce.exists(nonceKey), "Duplicate purchase submission");

        require(self.active, "Listing not active");
        require(self.remainingSupply > 0, "Sold out");
        let buyer: Address = sender();
        require(buyer != self.seller, "Buyer and seller must differ");

        let msgValue: Int = context().value;
        require(msgValue >= self.VaultGasBudget, "Insufficient gas budget for vault");

        self.seenNonce.set(nonceKey, true);
        self.remainingSupply = self.remainingSupply - 1;

        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        let vaultInit: StateInit = initOf EscrowOracleVault(myAddress(), self.dao, tradeId);
        let vaultAddress: Address = contractAddress(vaultInit);

        self.pendingBuyer.set(tradeId, buyer);
        self.pendingByVault.set(vaultAddress, tradeId);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingCount = self.pendingCount + 1;

        send(SendParameters{
            to: vaultAddress,
            value: msgValue,
            mode: 0,
            bounce: true,
            code: vaultInit.code,
            data: vaultInit.data,
            body: InitVault{
                tradeId: tradeId,
                buyer: buyer,
                seller: self.seller,
                jettonMaster: self.jettonMaster,
                tradeValue: self.pricePerUnit,
                guaranteePercent: self.guaranteePercent,
                commissionPercent: self.commissionPercent,
                commissionairesDao: self.commissionairesDao,
                deadline: now() + self.deadlineWindow,
                oracleRegistry: self.oracleRegistry,
                validationType: self.validationType,
                agreementCID: self.agreementCID,
                settlementMode: self.settlementMode
            }.toCell()
        });
    }

    receive(msg: VaultInitOk) {
        let vaultAddress: Address = sender();
        require(self.pendingByVault.exists(vaultAddress), "Only a deployed vault");
        require(self.pendingByVault.get(vaultAddress)!! == msg.tradeId, "Mismatched pending vault");

        let buyer: Address = self.pendingBuyer.get(msg.tradeId)!!;
        self.vaultsDeployed = self.vaultsDeployed + 1;

        emit(EvtListingVaultDeployed{
            listingId:    self.listingId,
            tradeId:      msg.tradeId,
            vaultAddress: vaultAddress,
            buyer:        buyer,
            seller:       self.seller,
            pricePerUnit: self.pricePerUnit
        }.toCell());

        self.pendingBuyer.del(msg.tradeId);
        self.pendingByVault.del(vaultAddress);
        self.pendingRefund.del(msg.tradeId);
        self.pendingCount = self.pendingCount - 1;
    }

    bounced(msg: Slice) {
        let vaultAddress: Address = sender();
        if (!self.pendingByVault.exists(vaultAddress)) { return; }
        let tradeId: Int = self.pendingByVault.get(vaultAddress)!!;
        let buyer: Address = self.pendingBuyer.get(tradeId)!!;

        // Vault deploy failed → return the unit to inventory, clear pending, and
        // refund the buyer's purchase value. The bounce returns most of what we
        // forwarded (msgValue) minus gas actually burned at the destination.
        self.remainingSupply = self.remainingSupply + 1;
        self.pendingCount = self.pendingCount - 1;

        let refundableBalance: Int = context().value - ton("0.02");
        if (refundableBalance < 0) { refundableBalance = 0; }
        let refundAmount: Int = min(self.pendingRefund.get(tradeId)!!, refundableBalance);

        self.pendingBuyer.del(tradeId);
        self.pendingByVault.del(vaultAddress);
        self.pendingRefund.del(tradeId);

        if (refundAmount > 0) {
            send(SendParameters{
                to:     buyer,
                value:  refundAmount,
                mode:   0,
                bounce: false,
                body:   "Purchase refund — vault deploy failed".asComment()
            });
        }
    }

    // ========================================
    // Getters
    // ========================================
    get fun config(): ListingConfig {
        return ListingConfig{
            owner:              self.owner,
            dao:                self.dao,
            seller:             self.seller,
            jettonMaster:       self.jettonMaster,
            oracleRegistry:     self.oracleRegistry,
            commissionairesDao: self.commissionairesDao,
            listingId:          self.listingId,
            pricePerUnit:       self.pricePerUnit,
            validationType:     self.validationType,
            settlementMode:     self.settlementMode,
            guaranteePercent:   self.guaranteePercent,
            commissionPercent:  self.commissionPercent,
            deadlineWindow:     self.deadlineWindow,
            active:             self.active,
            remainingSupply:    self.remainingSupply,
            vaultsDeployed:     self.vaultsDeployed
        };
    }

    get fun remainingSupply(): Int { return self.remainingSupply; }
    get fun vaultsDeployed(): Int { return self.vaultsDeployed; }
    get fun pendingCount(): Int { return self.pendingCount; }
    get fun active(): Bool { return self.active; }
    get fun vaultAddress(tradeId: Int): Address {
        return contractAddress(initOf EscrowOracleVault(myAddress(), self.dao, tradeId));
    }

    // Single-value getters (in addition to config()) so RPC clients can read one
    // field at a time without depending on how a >14-field struct is boxed over
    // the wire — mirrors the milestone vault's individual-getter pattern.
    get fun listingSeller(): Address { return self.seller; }
    get fun listingPrice(): Int { return self.pricePerUnit; }
    get fun listingValidationType(): Int { return self.validationType; }
    get fun listingSettlementMode(): Int { return self.settlementMode; }
    get fun listingJettonMaster(): Address { return self.jettonMaster; }
    get fun listingOracleRegistry(): Address { return self.oracleRegistry; }
    get fun listingDao(): Address { return self.dao; }
    get fun listingCommissionairesDao(): Address { return self.commissionairesDao; }
    get fun listingAgreementCID(): Cell? { return self.agreementCID; }
}
