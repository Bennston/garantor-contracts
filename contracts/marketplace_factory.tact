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
    pricePerUnit: Int as coins;     // vault tradeValue per unit (jetton minimal units)
    initialSupply: Int as uint32;
    validationType: Int as uint8;
    settlementMode: Int as uint8;   // 0 = oracle-only, 1 = manual-only (doc-hash)
    agreementCID: Cell?;
    nonce: Int as uint256;          // seller idempotency key
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

message(0xF104) EvtListingDeployed {
    listingId:      Int as uint64;
    listingAddress: Address;
    seller:         Address;
    pricePerUnit:   Int as coins;
    initialSupply:  Int as uint32;
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

    // TON forwarded to each new listing at deploy (storage + config gas). Buyers
    // fund the per-vault gas budget later at purchase time.
    const ListingGasBudget: Int = ton("0.1");

    // Seller discovery registry (hash(seller,index) → listingId), same shape as
    // the vault registry in EscrowJettonFactory.
    sellerListingCount: map<Address, Int as uint32>;
    sellerListings:     map<Int, Int as uint64>;

    // Pending until the listing acks ListingConfigured.
    pendingSeller:      map<Int, Address>;
    pendingPrice:       map<Int, Int as coins>;
    pendingSupply:      map<Int, Int as uint32>;
    pendingByListing:   map<Address, Int as uint64>;
    pendingRefund:      map<Int, Int as coins>;
    seenNonce:          map<Int, Bool>;

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
    }

    // Empty-body deploy handler.
    receive() {}

    // ========================================
    // CreateListing (seller self-serves)
    // ========================================
    receive(msg: CreateListing) {
        let seller: Address = sender();
        let nonceKey: Int = beginCell().storeAddress(seller).storeUint(msg.nonce, 256).endCell().hash();
        require(!self.seenNonce.exists(nonceKey), "Duplicate listing submission");

        require(msg.pricePerUnit > 0, "Price must be positive");
        require(msg.initialSupply > 0, "Supply must be positive");

        let msgValue: Int = context().value;
        require(msgValue >= self.deploymentFee + self.ListingGasBudget, "Insufficient deployment fee + gas");

        self.seenNonce.set(nonceKey, true);

        let listingId: Int = self.nextListingId;
        self.nextListingId = self.nextListingId + 1;

        // owner = this factory (so our ConfigureListing passes requireOwner);
        // dao = self.owner (the arbitrator seeded into every vault).
        let listingInit: StateInit = initOf MarketplaceListing(
            myAddress(),
            self.owner,
            self.jettonMaster,
            self.oracleRegistry,
            self.commissionairesDao,
            listingId
        );
        let listingAddress: Address = contractAddress(listingInit);

        self.pendingSeller.set(listingId, seller);
        self.pendingPrice.set(listingId, msg.pricePerUnit);
        self.pendingSupply.set(listingId, msg.initialSupply);
        self.pendingByListing.set(listingAddress, listingId);
        self.pendingRefund.set(listingId, msgValue);

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
                pricePerUnit: msg.pricePerUnit,
                initialSupply: msg.initialSupply,
                validationType: msg.validationType,
                settlementMode: msg.settlementMode,
                agreementCID: msg.agreementCID
            }.toCell()
        });
    }

    receive(msg: ListingConfigured) {
        let listingAddress: Address = sender();
        require(self.pendingByListing.exists(listingAddress), "Only a deployed listing");
        require(self.pendingByListing.get(listingAddress)!! == msg.listingId, "Mismatched pending listing");

        let seller: Address = self.pendingSeller.get(msg.listingId)!!;
        let price: Int = self.pendingPrice.get(msg.listingId)!!;
        let supply: Int = self.pendingSupply.get(msg.listingId)!!;

        self._registerSellerListing(seller, msg.listingId);
        self.totalListings = self.totalListings + 1;
        self.totalFeesCollected = self.totalFeesCollected + self.deploymentFee;

        emit(EvtListingDeployed{
            listingId:      msg.listingId,
            listingAddress: listingAddress,
            seller:         seller,
            pricePerUnit:   price,
            initialSupply:  supply
        }.toCell());

        self._clearPending(msg.listingId, listingAddress);
    }

    bounced(msg: Slice) {
        let listingAddress: Address = sender();
        if (!self.pendingByListing.exists(listingAddress)) { return; }
        let listingId: Int = self.pendingByListing.get(listingAddress)!!;
        let seller: Address = self.pendingSeller.get(listingId)!!;

        // Listing deploy failed → refund the seller. deploymentFee was kept back
        // (never forwarded), and the bounce returns most of what was forwarded
        // minus gas actually burned at the destination.
        let refundableBalance: Int = self.deploymentFee + context().value - ton("0.02");
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
        self.pendingByListing.del(listingAddress);
        self.pendingRefund.del(listingId);
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
            operationalReserve: self.operationalReserve
        };
    }

    get fun totalListings(): Int { return self.totalListings; }

    get fun deploymentFee(): Int { return self.deploymentFee; }

    get fun totalFeesCollected(): Int { return self.totalFeesCollected; }

    get fun operationalReserve(): Int { return self.operationalReserve; }

    get fun listingAddress(listingId: Int): Address {
        return contractAddress(initOf MarketplaceListing(
            myAddress(), self.owner, self.jettonMaster, self.oracleRegistry, self.commissionairesDao, listingId
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
