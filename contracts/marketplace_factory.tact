import "@stdlib/ownable";
import "./marketplace_listing";

// ============================================================
// MarketplaceFactory (V3) — DAO-owned deployer of MarketplaceListings
// ============================================================
//
// The top tier of the V3 marketplace:
//   MarketplaceFactory (DAO)  →  MarketplaceListing (per seller/product)  →  EscrowOracleVault (per purchase)
//
// A seller calls CreateListing; the factory deploys a MarketplaceListing seeded
// with the protocol params (jettonMaster, oracleRegistry, commissionaires DAO,
// arbitrator DAO) and immediately configures it (the factory is the listing's
// Ownable admin, so its ConfigureListing passes requireOwner). The listing seeds
// each spawned vault with `dao` = the arbitrator, NOT the factory — so disputes
// still resolve through the DAO multisig.
//
// Mirrors EscrowJettonFactory: deterministic listing address, ListingConfigured
// ack finalizes bookkeeping, bounce clears pending.
// See V3_ORACLE_MARKETPLACE_DESIGN.md §4.2.
// ============================================================

message(0x6101) CreateListing {
    pricePerUnit: Int as coins;     // vault tradeValue PER UNIT (jetton minimal units)
    initialSupply: Int as uint64;   // V3.1: widened uint32 -> uint64; supply is in the listing's own unit
    minOrderQty: Int as uint64;     // V3.1: on-chain MOQ. 0 => 1
    maxOrderQty: Int as uint64;     // V3.1: per-purchase cap. 0 => uncapped
    validationType: Int as uint8;
    settlementMode: Int as uint8;   // 0 = oracle-only, 1 = manual-only (doc-hash)
    agreementCID: Cell?;
    nonce: Int as uint256;          // seller idempotency key
}

// V3.1 Tier 2: owner retunes the protocol params seeded into FUTURE listings
// (existing listings keep what they were configured with). A 0 in any field
// leaves that param unchanged.
message(0x6108) UpdateListingParams {
    guaranteePercent: Int as uint8;      // 1..20 ; 0 = unchanged
    commissionPercent: Int as uint8;     // 0..10 ; sentinel 255 = unchanged (0 is a valid value)
    deadlineWindow: Int as uint32;       // 0 = unchanged
    listingWindow: Int as uint32;        // 0 = unchanged
    objectionWindow: Int as uint32;      // 0 = unchanged
    disputeTimeoutWindow: Int as uint32; // 0 = unchanged
    destroyGraceWindow: Int as uint32;   // 0 = unchanged
}

message(0x6102) UpdateOracleRegistry {
    newRegistry: Address;           // owner-only; future listings point at this registry
}

message(0x6103) UpdateCommissionairesDao {
    newCommissionairesDao: Address;
}

message(0x6104) UpdateDeploymentFee {
    newFee: Int as coins;            // owner-only; the fee sellers pay to create a listing
}

message(0x6105) WithdrawFees {}

message(0x6106) UpdateOperationalReserve {
    newOperationalReserve: Int as coins;
}

// Owner-only marketplace-wide kill switch. When paused, CreateListing is refused
// so no NEW listings (and therefore no new vaults) can enter. Existing listings
// and their in-flight trades are independent contracts and keep settling — to stop
// an individual listing the DAO calls DestroyListing on it. This is the on-chain
// counterpart to the frontend launch-config kill switch.
message(0x6107) SetMarketplacePaused {
    paused: Bool;
}

message(0xF104) EvtListingDeployed {
    listingId:      Int as uint64;
    listingAddress: Address;
    seller:         Address;
    pricePerUnit:   Int as coins;
    initialSupply:  Int as uint64;  // V3.1 widened
    minOrderQty:    Int as uint64;  // V3.1
    maxOrderQty:    Int as uint64;  // V3.1
    validationType: Int as uint8;   // so an indexer knows the oracle report kind without a separate listing read
    settlementMode: Int as uint8;   // 0 = oracle-only, 1 = manual-only (doc-hash)
}

struct MarketplaceFactoryConfig {
    owner:              Address;
    jettonMaster:       Address;
    oracleRegistry:     Address;
    commissionairesDao: Address;
    totalListings:      Int as uint32;
    nextListingId:      Int as uint64;
    deploymentFee:      Int as coins;
    totalFeesCollected: Int as coins;
    operationalReserve: Int as coins;
    paused:             Bool;
    // V3.1 Tier 2: protocol params seeded into new listings
    guaranteePercent:     Int as uint8;
    commissionPercent:    Int as uint8;
    deadlineWindow:       Int as uint32;
    listingWindow:        Int as uint32;
    objectionWindow:      Int as uint32;
    disputeTimeoutWindow: Int as uint32;
    destroyGraceWindow:   Int as uint32;
}

contract MarketplaceFactory with Ownable {

    owner: Address;                 // DAO multisig — also the vault arbitrator seeded into listings
    jettonMaster: Address;
    oracleRegistry: Address;
    commissionairesDao: Address;

    deploymentFee: Int as coins;
    nextListingId: Int as uint64;
    totalListings: Int as uint32;
    totalFeesCollected: Int as coins;
    operationalReserve: Int as coins;

    // Marketplace-wide kill switch (owner-only). Blocks new listings when true.
    paused: Bool;

    // V3.1 Tier 2: protocol params seeded into every NEW listing. Retuned via
    // UpdateListingParams; changes never touch already-deployed listings.
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    deadlineWindow: Int as uint32;
    listingWindow: Int as uint32;
    objectionWindow: Int as uint32;
    disputeTimeoutWindow: Int as uint32;
    destroyGraceWindow: Int as uint32;

    // TON forwarded to each new listing at deploy (storage + config gas). Buyers
    // fund the per-vault gas budget later at purchase time.
    const ListingGasBudget: Int = ton("0.1");

    // Seller discovery registry (hash(seller,index) → listingId), same shape as
    // the vault registry in EscrowJettonFactory.
    sellerListingCount: map<Address, Int as uint32>;
    sellerListings:     map<Int, Int as uint64>;

    // Pending until the listing acks ListingConfigured.
    pendingSeller:         map<Int, Address>;
    pendingPrice:          map<Int, Int as coins>;
    pendingSupply:         map<Int, Int as uint64>;   // V3.1 widened
    pendingMinQty:         map<Int, Int as uint64>;   // V3.1
    pendingMaxQty:         map<Int, Int as uint64>;   // V3.1
    pendingValidationType: map<Int, Int as uint8>;
    pendingSettlementMode: map<Int, Int as uint8>;
    pendingByListing:      map<Address, Int as uint64>;
    pendingRefund:         map<Int, Int as coins>;
    // The deploymentFee actually withheld for THIS listing at CreateListing time.
    // Credited to totalFeesCollected on ack (and refunded on bounce) instead of
    // the live self.deploymentFee, so an UpdateDeploymentFee mid-flight can't make
    // the accounting over/under-count and let WithdrawFees dip into other sellers'
    // withheld fees.
    pendingFee:            map<Int, Int as coins>;
    seenNonce:             map<Int, Bool>;
    // MK-N2: listingId → nonceKey, so a bounced deploy can release the nonce.
    // The seenNonce entry itself is deliberately KEPT on the success path
    // (ListingConfigured) — that form produced a listing and must not be
    // replayable; bounced() releases it explicitly before _clearPending.
    pendingNonceKey:       map<Int, Int>;

    init(
        owner: Address,
        jettonMaster: Address,
        oracleRegistry: Address,
        commissionairesDao: Address,
    ) {
        self.owner = owner;
        self.jettonMaster = jettonMaster;
        self.oracleRegistry = oracleRegistry;
        self.commissionairesDao = commissionairesDao;
        self.deploymentFee = ton("4");   // listing creation costs more than a normal escrow/milestone vault; owner-retunable
        self.nextListingId = 1;
        self.totalListings = 0;
        self.totalFeesCollected = 0;
        self.operationalReserve = ton("2");
        self.paused = false;

        // V3.1 Tier 2 defaults (match the pre-V3.1 hard-coded values).
        self.guaranteePercent     = 2;
        self.commissionPercent    = 1;
        self.deadlineWindow       = 2592000;  // 30d per-trade settlement window
        self.listingWindow        = 2592000;  // 30d listing lifetime
        self.objectionWindow      = 172800;   // 48h
        self.disputeTimeoutWindow = 2592000;  // 30d
        self.destroyGraceWindow   = 3600;     // 1h
    }

    // Empty-body deploy handler.
    receive() {}

    // ========================================
    // CreateListing (seller self-serves)
    // ========================================
    receive(msg: CreateListing) {
        require(!self.paused, "Marketplace is paused — new listings disabled");
        let seller: Address = sender();
        let nonceKey: Int = beginCell().storeAddress(seller).storeUint(msg.nonce, 256).endCell().hash();
        require(!self.seenNonce.exists(nonceKey), "Duplicate listing submission");

        require(msg.pricePerUnit > 0, "Price must be positive");
        require(msg.initialSupply > 0, "Supply must be positive");
        // V3.1: order-size sanity (the listing re-checks these authoritatively).
        require(msg.maxOrderQty == 0 || msg.maxOrderQty >= msg.minOrderQty, "maxOrderQty below minOrderQty");

        let msgValue: Int = context().value;
        require(msgValue >= self.deploymentFee + self.ListingGasBudget, "Insufficient deployment fee + gas");

        self.seenNonce.set(nonceKey, true);

        let listingId: Int = self.nextListingId;
        self.nextListingId = self.nextListingId + 1;

        // owner = this factory (so our ConfigureListing passes requireOwner).
        // Only immutable params go into init — the listing address must derive
        // from (factory, jettonMaster, listingId) alone. dao / oracleRegistry /
        // commissionairesDao are seeded via ConfigureListing below, so a later
        // UpdateOracleRegistry / UpdateCommissionairesDao / ownership transfer
        // cannot break re-derivation of any existing listing's address.
        let listingInit: StateInit = initOf MarketplaceListing(
            myAddress(),
            self.jettonMaster,
            listingId
        );
        let listingAddress: Address = contractAddress(listingInit);

        self.pendingSeller.set(listingId, seller);
        self.pendingPrice.set(listingId, msg.pricePerUnit);
        self.pendingSupply.set(listingId, msg.initialSupply);
        self.pendingMinQty.set(listingId, msg.minOrderQty);
        self.pendingMaxQty.set(listingId, msg.maxOrderQty);
        self.pendingValidationType.set(listingId, msg.validationType);
        self.pendingSettlementMode.set(listingId, msg.settlementMode);
        self.pendingByListing.set(listingAddress, listingId);
        self.pendingRefund.set(listingId, msgValue);
        self.pendingFee.set(listingId, self.deploymentFee);   // fee withheld now; credited/refunded by this value, not the live one
        self.pendingNonceKey.set(listingId, nonceKey);        // MK-N2: released only if the deploy bounces

        // Deploy + configure in one message (first message to the listing is
        // ConfigureListing; sender() == factory == listing owner).
        send(SendParameters{
            to: listingAddress,
            value: msgValue - self.deploymentFee,
            mode: 0,
            bounce: true,
            code: listingInit.code,
            data: listingInit.data,
            body: ConfigureListing{
                seller: seller,
                dao: self.owner,                              // arbitrator seeded into every vault
                oracleRegistry: self.oracleRegistry,
                commissionairesDao: self.commissionairesDao,
                pricePerUnit: msg.pricePerUnit,
                initialSupply: msg.initialSupply,
                minOrderQty: msg.minOrderQty,
                maxOrderQty: msg.maxOrderQty,
                validationType: msg.validationType,
                settlementMode: msg.settlementMode,
                agreementCID: msg.agreementCID,
                renewFee: self.deploymentFee,  // renewal costs whatever CreateListing costs today
                // V3.1 Tier 2: seed the listing with the factory's current params
                guaranteePercent: self.guaranteePercent,
                commissionPercent: self.commissionPercent,
                deadlineWindow: self.deadlineWindow,
                listingWindow: self.listingWindow,
                objectionWindow: self.objectionWindow,
                disputeTimeoutWindow: self.disputeTimeoutWindow,
                destroyGraceWindow: self.destroyGraceWindow
            }.toCell()
        });
    }

    // V3.1 Tier 2: retune protocol params for FUTURE listings. 0 leaves a field
    // unchanged; commissionPercent uses 255 as its "unchanged" sentinel since 0
    // is a valid value ("no commission").
    receive(msg: UpdateListingParams) {
        self.requireOwner();
        if (msg.guaranteePercent != 0) {
            require(msg.guaranteePercent <= 20, "Guarantee % must be 1-20");
            self.guaranteePercent = msg.guaranteePercent;
        }
        if (msg.commissionPercent != 255) {
            require(msg.commissionPercent <= 10, "Commission cannot exceed 10%");
            self.commissionPercent = msg.commissionPercent;
        }
        // V3.1 review fix (L1): clamp here too, not just in ConfigureListing/InitVault.
        // Un-clamped, an out-of-range window silently sits in factory state until the
        // NEXT CreateListing bounces trying to resolveWindow() it — the owner finds out
        // from a stream of failed listings, not from this transaction. resolveWindow
        // (imported from marketplace_listing.tact) reverts immediately instead, and its
        // "0 => keep current" behavior for the fallback arg makes the unconditional call
        // equivalent to the old if-guarded assignment.
        self.deadlineWindow       = resolveWindow(msg.deadlineWindow, self.deadlineWindow);
        self.listingWindow        = resolveWindow(msg.listingWindow, self.listingWindow);
        self.objectionWindow      = resolveWindow(msg.objectionWindow, self.objectionWindow);
        self.disputeTimeoutWindow = resolveWindow(msg.disputeTimeoutWindow, self.disputeTimeoutWindow);
        self.destroyGraceWindow   = resolveWindow(msg.destroyGraceWindow, self.destroyGraceWindow);
    }

    receive(msg: ListingConfigured) {
        let listingAddress: Address = sender();
        require(self.pendingByListing.exists(listingAddress), "Only a deployed listing");
        require(self.pendingByListing.get(listingAddress)!! == msg.listingId, "Mismatched pending listing");

        let seller: Address = self.pendingSeller.get(msg.listingId)!!;
        let price: Int = self.pendingPrice.get(msg.listingId)!!;
        let supply: Int = self.pendingSupply.get(msg.listingId)!!;
        let minQty: Int = self.pendingMinQty.get(msg.listingId)!!;
        let maxQty: Int = self.pendingMaxQty.get(msg.listingId)!!;
        let validationType: Int = self.pendingValidationType.get(msg.listingId)!!;
        let settlementMode: Int = self.pendingSettlementMode.get(msg.listingId)!!;

        self._registerSellerListing(seller, msg.listingId);
        self.totalListings = self.totalListings + 1;
        // Credit the fee THIS listing actually paid (stashed at CreateListing),
        // not the current self.deploymentFee — see pendingFee.
        self.totalFeesCollected = self.totalFeesCollected + self.pendingFee.get(msg.listingId)!!;

        emit(EvtListingDeployed{
            listingId:      msg.listingId,
            listingAddress: listingAddress,
            seller:         seller,
            pricePerUnit:   price,
            initialSupply:  supply,
            minOrderQty:    minQty,
            maxOrderQty:    maxQty,
            validationType: validationType,
            settlementMode: settlementMode
        }.toCell());

        self._clearPending(msg.listingId, listingAddress);
    }

    bounced(msg: Slice) {
        let listingAddress: Address = sender();
        if (!self.pendingByListing.exists(listingAddress)) { return; }
        let listingId: Int = self.pendingByListing.get(listingAddress)!!;
        let seller: Address = self.pendingSeller.get(listingId)!!;

        // MK-N2: the listing never came into existence, so this form produced no
        // listing — release the idempotency guard so the seller's wallet can
        // auto-retry the exact same signed form. Without this the nonce stays
        // burned and every retry bounces on "Duplicate listing submission".
        if (self.pendingNonceKey.exists(listingId)) {
            self.seenNonce.del(self.pendingNonceKey.get(listingId)!!);
        }

        // Listing deploy failed → refund the seller. The fee withheld for THIS
        // listing (pendingFee, never forwarded) is returned along with the bounce,
        // minus gas actually burned at the destination. Uses the stashed fee, not
        // the live self.deploymentFee, in case it changed since CreateListing.
        let withheldFee: Int = self.pendingFee.get(listingId)!!;
        let refundableBalance: Int = withheldFee + context().value - ton("0.02");
        if (refundableBalance < 0) { refundableBalance = 0; }
        let refundAmount: Int = min(self.pendingRefund.get(listingId)!!, refundableBalance);

        self._clearPending(listingId, listingAddress);

        if (refundAmount > 0) {
            send(SendParameters{
                to:     seller,
                value:  refundAmount,
                mode:   0,
                bounce: false,
                body:   "Listing creation refund — deploy failed".asComment()
            });
        }
    }

    // A listing forwards its paid renewal fee here so renewal revenue is accounted
    // in the same place as creation fees. Authenticate that the sender really is a
    // listing THIS factory deployed (address derived from our immutable init params)
    // so a stranger can't touch the accounting, then credit the ACTUAL TON received
    // — never a claimed amount (cf. the pendingFee accounting fix) — which now sits
    // in this factory's balance backing WithdrawFees.
    receive(msg: CollectRenewalFee) {
        let expected: Address = contractAddress(initOf MarketplaceListing(
            myAddress(), self.jettonMaster, msg.listingId
        ));
        require(sender() == expected, "Only a listing of this factory");
        self.totalFeesCollected = self.totalFeesCollected + context().value;
    }

    // ========================================
    // Owner admin
    // ========================================
    receive(msg: UpdateOracleRegistry) {
        self.requireOwner();
        self.oracleRegistry = msg.newRegistry;
    }

    receive(msg: UpdateCommissionairesDao) {
        self.requireOwner();
        self.commissionairesDao = msg.newCommissionairesDao;
    }

    receive(msg: UpdateDeploymentFee) {
        self.requireOwner();
        require(msg.newFee >= ton("0.05"), "Fee too low");
        // MK-N7: a fat-fingered huge fee would DoS every new listing until
        // manually corrected — floor already existed, add the matching ceiling.
        require(msg.newFee <= ton("1000"), "Fee too high");
        self.deploymentFee = msg.newFee;
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
            body: "Marketplace fee withdrawal".asComment()
        });
        self.totalFeesCollected = self.totalFeesCollected - withdrawable;
    }

    receive(msg: UpdateOperationalReserve) {
        self.requireOwner();
        require(msg.newOperationalReserve >= ton("0.5"), "Operational reserve too low");
        self.operationalReserve = msg.newOperationalReserve;
    }

    receive(msg: SetMarketplacePaused) {
        self.requireOwner();
        self.paused = msg.paused;
    }

    // ========================================
    // Helpers
    // ========================================
    fun _sellerKey(seller: Address, index: Int): Int {
        return beginCell().storeAddress(seller).storeUint(index, 32).endCell().hash();
    }

    fun _registerSellerListing(seller: Address, listingId: Int) {
        let count: Int = 0;
        if (self.sellerListingCount.exists(seller)) {
            count = self.sellerListingCount.get(seller)!!;
        }
        self.sellerListings.set(self._sellerKey(seller, count), listingId);
        self.sellerListingCount.set(seller, count + 1);
    }

    fun _clearPending(listingId: Int, listingAddress: Address) {
        self.pendingSeller.del(listingId);
        self.pendingPrice.del(listingId);
        self.pendingSupply.del(listingId);
        self.pendingMinQty.del(listingId);
        self.pendingMaxQty.del(listingId);
        self.pendingValidationType.del(listingId);
        self.pendingSettlementMode.del(listingId);
        self.pendingByListing.del(listingAddress);
        self.pendingRefund.del(listingId);
        self.pendingFee.del(listingId);
        // MK-N2: drop only the listingId→nonceKey lookup here. The seenNonce entry
        // is released explicitly in bounced(); on the success path it is kept so a
        // form that produced a listing can never be replayed.
        self.pendingNonceKey.del(listingId);
    }

    // ========================================
    // Getters
    // ========================================
    get fun config(): MarketplaceFactoryConfig {
        return MarketplaceFactoryConfig{
            owner:              self.owner,
            jettonMaster:       self.jettonMaster,
            oracleRegistry:     self.oracleRegistry,
            commissionairesDao: self.commissionairesDao,
            totalListings:      self.totalListings,
            nextListingId:      self.nextListingId,
            deploymentFee:      self.deploymentFee,
            totalFeesCollected: self.totalFeesCollected,
            operationalReserve: self.operationalReserve,
            paused:             self.paused,
            guaranteePercent:     self.guaranteePercent,
            commissionPercent:    self.commissionPercent,
            deadlineWindow:       self.deadlineWindow,
            listingWindow:        self.listingWindow,
            objectionWindow:      self.objectionWindow,
            disputeTimeoutWindow: self.disputeTimeoutWindow,
            destroyGraceWindow:   self.destroyGraceWindow
        };
    }

    get fun totalListings(): Int { return self.totalListings; }
    get fun listingParams(): MarketplaceFactoryConfig { return self.config(); }  // V3.1 alias for clarity

    get fun deploymentFee(): Int { return self.deploymentFee; }

    get fun totalFeesCollected(): Int { return self.totalFeesCollected; }

    get fun operationalReserve(): Int { return self.operationalReserve; }

    get fun paused(): Bool { return self.paused; }

    get fun listingAddress(listingId: Int): Address {
        // Must mirror CreateListing's init exactly: (factory, jettonMaster,
        // listingId) — the mutable params are NOT part of the address.
        return contractAddress(initOf MarketplaceListing(
            myAddress(), self.jettonMaster, listingId
        ));
    }

    get fun sellerListingCount(seller: Address): Int {
        if (self.sellerListingCount.exists(seller)) {
            return self.sellerListingCount.get(seller)!!;
        }
        return 0;
    }

    get fun sellerListingAtIndex(seller: Address, index: Int): Int {
        return self.sellerListings.get(self._sellerKey(seller, index))!!;
    }
}
