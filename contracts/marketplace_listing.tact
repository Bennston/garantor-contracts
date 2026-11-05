import "@stdlib/ownable";
import "./escrow_oracle_vault";

// V3.1: resolve a period/window field — 0 means "use the protocol default" —
// and clamp it to a sane 5-minute..1-year band so a misconfigured factory can't
// seed a vault with a 1-second or 100-year dispute window.
inline fun resolveWindow(value: Int, fallback: Int): Int {
    let v: Int = value;
    if (v == 0) { v = fallback; }
    require(v >= 300 && v <= 31536000, "Window out of range (5m..1y)");
    return v;
}

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
    // dao / oracleRegistry / commissionairesDao are ALSO set here, not in init:
    // the factory can change oracleRegistry/commissionairesDao (and its own owner,
    // seeded as dao) at any time, so embedding them in init would make the
    // listing address re-derivation break for every existing listing after such
    // an update. Keeping them out means the address derives from (factory,
    // jettonMaster, listingId) alone — all immutable.
    dao: Address;                   // arbitrator seeded into each vault (dispute owner)
    oracleRegistry: Address;        // sole authority allowed to submit OracleReport to spawned vaults
    commissionairesDao: Address;    // commission recipient seeded into each vault
    pricePerUnit: Int as coins;     // vault tradeValue PER UNIT (jetton minimal units); a purchase's tradeValue = pricePerUnit * quantity
    initialSupply: Int as uint64;   // V3.1: widened uint32 -> uint64 (supply is now counted in the listing's own unit, e.g. m²/kg, not "lots")
    minOrderQty: Int as uint64;     // V3.1: minimum units per purchase (on-chain MOQ). 0 => 1
    maxOrderQty: Int as uint64;     // V3.1: maximum units per purchase. 0 => no cap
    validationType: Int as uint8;
    settlementMode: Int as uint8;   // 0 = oracle-only, 1 = manual-only (doc-hash); pinned per listing
    agreementCID: Cell?;            // IPFS CID of the signed terms (informational anchor)
    renewFee: Int as coins;         // TON cost of a RenewListing call; also kept out of init() for the same reason
    // ── V3.1 Tier 2: per-listing protocol params (previously frozen in init()) ──
    // The factory always sends explicit percents; a 0 in any *Window field means
    // "use the contract default" so a minimal ConfigureListing still works.
    guaranteePercent: Int as uint8;      // seller bond %. 1..20
    commissionPercent: Int as uint8;     // commissionaires cut %. 0..10 (0 is a valid, explicit "no commission")
    deadlineWindow: Int as uint32;       // per-trade settlement window baked into each vault. 0 => 30d
    listingWindow: Int as uint32;        // listing lifetime before it needs RenewListing. 0 => 30d
    objectionWindow: Int as uint32;      // forwarded to each vault (post-report dispute window). 0 => 48h
    disputeTimeoutWindow: Int as uint32; // forwarded to each vault (dispute auto-timeout). 0 => 30d
    destroyGraceWindow: Int as uint32;   // forwarded to each vault (self-destruct grace). 0 => 1h
}

message(0x6002) PurchaseListing {
    nonce: Int as uint256;          // buyer idempotency key (double-click / rebroadcast guard)
    quantity: Int as uint64;        // V3.1: units to buy. minOrderQty <= quantity <= min(maxOrderQty || ∞, remainingSupply)
}

message(0x6003) SetListingActive {
    active: Bool;                   // owner emergency pause / resume
}

message(0x6005) DestroyListing {}   // seller or DAO tears the listing down + reclaims gas

message(0x6006) RenewListing {}     // seller pays renewFee to push expiresAt out another listingWindow

// ── V3.1 Tier 3: post-configuration mutation. Each affects FUTURE purchases only —
// vaults already deployed keep the price / terms / windows they were spawned with.
message(0x6008) UpdatePrice        { pricePerUnit: Int as coins; }   // seller-only
message(0x6009) RestockListing     { addSupply: Int as uint64; }     // seller-only; bumps initialSupply + remainingSupply
message(0x600A) UpdateAgreementCID { agreementCID: Cell?; }          // seller-only; e.g. fix a typo / swap the listing photo
message(0x600B) UpdateProtocolAddrs{ oracleRegistry: Address; commissionairesDao: Address; }  // owner (factory) only

// Listing → owner (factory): forwards a paid renewal fee so it flows through the
// factory's fee accounting (totalFeesCollected / WithdrawFees), exactly like the
// creation fee. Carries listingId so the factory can authenticate the sender is a
// listing it actually deployed. Declared here (not in the factory) because the
// listing sends it; the factory imports this file and so sees the type.
message(0x6007) CollectRenewalFee {
    listingId: Int as uint64;
}

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
    quantity:     Int as uint64;   // V3.1
    tradeValue:   Int as coins;    // V3.1: pricePerUnit * quantity (the vault's escrowed amount)
}

message(0xF105) EvtListingRenewed {
    listingId: Int as uint64;
    seller:    Address;
    expiresAt: Int as uint32;
}

// V3.1 Tier 3 events
message(0xF106) EvtListingPriceUpdated { listingId: Int as uint64; pricePerUnit: Int as coins; }
message(0xF107) EvtListingRestocked    { listingId: Int as uint64; addSupply: Int as uint64; remainingSupply: Int as uint64; }
message(0xF108) EvtListingTermsUpdated { listingId: Int as uint64; }

struct ListingConfig {
    owner:                Address;
    dao:                  Address;
    seller:               Address;
    jettonMaster:         Address;
    oracleRegistry:       Address;
    commissionairesDao:   Address;
    listingId:            Int as uint64;
    pricePerUnit:         Int as coins;
    minOrderQty:          Int as uint64;   // V3.1
    maxOrderQty:          Int as uint64;   // V3.1 (0 = uncapped)
    validationType:       Int as uint8;
    settlementMode:       Int as uint8;
    guaranteePercent:     Int as uint8;
    commissionPercent:    Int as uint8;
    deadlineWindow:       Int as uint32;
    objectionWindow:      Int as uint32;   // V3.1
    disputeTimeoutWindow: Int as uint32;   // V3.1
    destroyGraceWindow:   Int as uint32;   // V3.1
    active:               Bool;
    initialSupply:        Int as uint64;   // V3.1 (explicit; was inferred client-side)
    remainingSupply:      Int as uint64;   // V3.1 widened uint32 -> uint64
    vaultsDeployed:       Int as uint32;
    expiresAt:            Int as uint32;
    renewFee:             Int as coins;
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
    minOrderQty: Int as uint64;          // V3.1: on-chain MOQ
    maxOrderQty: Int as uint64;          // V3.1: per-purchase cap (0 = uncapped)
    validationType: Int as uint8;
    settlementMode: Int as uint8;
    agreementCID: Cell?;
    guaranteePercent: Int as uint8;
    commissionPercent: Int as uint8;
    deadlineWindow: Int as uint32;
    // V3.1 Tier 2: forwarded into every spawned vault (previously vault consts).
    objectionWindow: Int as uint32;
    disputeTimeoutWindow: Int as uint32;
    destroyGraceWindow: Int as uint32;

    // Listing-level lifetime (distinct from deadlineWindow, which is the
    // per-trade settlement window baked into each spawned vault). A listing
    // stops accepting purchases once expired; the seller keeps it visible by
    // renewing — no redeploy, since buyers/frontends already hold this address.
    expiresAt: Int as uint32;
    listingWindow: Int as uint32;
    renewFee: Int as coins;

    active: Bool;
    initialSupply: Int as uint64;        // V3.1: stored explicitly (was inferred as remaining + sold)
    remainingSupply: Int as uint64;      // V3.1 widened uint32 -> uint64
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
    pendingQty:     map<Int, Int as uint64>;   // V3.1: tradeId -> units, so a bounce restores the right amount
    // MK-N1: the price actually charged at purchase time, so EvtListingVaultDeployed
    // reports what the buyer actually paid even if the seller re-prices the listing
    // before the vault's ack arrives.
    pendingPrice:      map<Int, Int as coins>;
    // MK-N2: the purchase's nonce key, so bounced() can release it — without this,
    // a bounced deploy leaves the nonce permanently "seen" and the buyer's wallet
    // can never auto-retry the identical signed purchase form.
    pendingNonceKey:   map<Int, Int>;
    seenNonce:      map<Int, Bool>;

    // V3.1: hard ceiling on pricePerUnit * quantity (jetton minimal units), so a
    // pathological listing can't overflow the vault's `coins`-typed tradeValue.
    // 1e17 minimal units = 1e11 USDT at 6dp — far above any real trade.
    const MaxTradeValue: Int = 100000000000000000;
    // V3.1 review fix (L2): explicit ceiling for RestockListing's addition, so an
    // overflowing restock reverts with a clear message instead of an opaque
    // serialization failure when initialSupply/remainingSupply (uint64) are
    // written back at the end of the transaction. No fund-loss risk either way —
    // seller-only, and a failed transaction touches no state — this is purely
    // about a legible error.
    const MaxUint64: Int = 18446744073709551615;

    // Only immutable params live in init, so the listing address derives from
    // (factory-owner, jettonMaster, listingId) alone. dao / oracleRegistry /
    // commissionairesDao are mutable on the factory and are seeded via
    // ConfigureListing instead (see the message comment) — embedding them here
    // would break address re-derivation whenever the factory updates them.
    init(
        owner: Address,
        jettonMaster: Address,
        listingId: Int,
    ) {
        self.owner = owner;
        self.dao = owner;                  // placeholder until ConfigureListing sets the arbitrator
        self.seller = owner;               // placeholder until ConfigureListing sets the real seller
        self.jettonMaster = jettonMaster;
        self.oracleRegistry = owner;       // placeholder until ConfigureListing
        self.commissionairesDao = owner;   // placeholder until ConfigureListing
        self.listingId = listingId;

        self.pricePerUnit = 0;
        self.minOrderQty = 1;            // V3.1
        self.maxOrderQty = 0;            // V3.1 (uncapped)
        self.validationType = 0;
        self.settlementMode = 0;
        self.agreementCID = null;
        self.guaranteePercent = 2;
        self.commissionPercent = 1;
        self.deadlineWindow = 2592000;   // 30 days
        self.objectionWindow = 172800;   // V3.1: 48h  (vault default)
        self.disputeTimeoutWindow = 2592000; // V3.1: 30d (vault default)
        self.destroyGraceWindow = 3600;  // V3.1: 1h  (vault default)

        self.expiresAt = 0;              // set for real in ConfigureListing
        self.listingWindow = 2592000;    // 30 days
        self.renewFee = 0;               // set for real in ConfigureListing

        self.active = false;
        self.initialSupply = 0;          // V3.1
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
        require(msg.guaranteePercent > 0 && msg.guaranteePercent <= 20, "Guarantee % must be 1-20");
        require(msg.commissionPercent <= 10, "Commission cannot exceed 10%");
        require(msg.settlementMode <= 1, "Invalid settlement mode");
        // MK-N6 / V3-L3: a seller equal to the arbitrator (dao) or commissionairesDao
        // would pass requireOwner()'s arbitration checks in the vault it spawns, and
        // every purchase against such a listing bounces at vault init anyway — reject
        // it here instead of letting each buyer discover it one bounced purchase at a
        // time. dao is immutable per listing (this is the only configure call), so a
        // bad value here poisons every vault the listing would ever spawn.
        require(msg.seller != msg.dao && msg.seller != msg.commissionairesDao,
            "Seller cannot be the arbitrator or commissionaires DAO");

        // V3.1: order-size bounds. minOrderQty 0 normalises to 1; maxOrderQty 0
        // means "no cap". A set cap must sit between the floor and the supply.
        let minQ: Int = msg.minOrderQty;
        if (minQ == 0) { minQ = 1; }
        require(minQ <= msg.initialSupply, "minOrderQty exceeds supply");
        require(msg.maxOrderQty == 0 || msg.maxOrderQty >= minQ, "maxOrderQty below minOrderQty");
        require(msg.pricePerUnit <= self.MaxTradeValue, "pricePerUnit too large");

        self.seller = msg.seller;
        self.dao = msg.dao;
        self.oracleRegistry = msg.oracleRegistry;
        self.commissionairesDao = msg.commissionairesDao;
        self.pricePerUnit = msg.pricePerUnit;
        self.minOrderQty = minQ;
        self.maxOrderQty = msg.maxOrderQty;
        self.validationType = msg.validationType;
        self.settlementMode = msg.settlementMode;
        self.agreementCID = msg.agreementCID;
        self.initialSupply = msg.initialSupply;
        self.remainingSupply = msg.initialSupply;
        self.renewFee = msg.renewFee;

        // V3.1 Tier 2: adopt the per-listing params (explicit percents; 0 => default window).
        self.guaranteePercent = msg.guaranteePercent;
        self.commissionPercent = msg.commissionPercent;
        self.deadlineWindow = resolveWindow(msg.deadlineWindow, 2592000);
        self.listingWindow = resolveWindow(msg.listingWindow, 2592000);
        self.objectionWindow = resolveWindow(msg.objectionWindow, 172800);
        self.disputeTimeoutWindow = resolveWindow(msg.disputeTimeoutWindow, 2592000);
        self.destroyGraceWindow = resolveWindow(msg.destroyGraceWindow, 3600);

        self.expiresAt = now() + self.listingWindow;
        self.active = true;

        // Ack the owner (e.g. a MarketplaceFactory) that the listing is live.
        // A small fixed value — the listing RETAINS the rest of its deploy balance
        // as an operating buffer so mode-0 vault deploys on purchase have gas.
        // V3.1: bumped 0.01 -> 0.03 — the factory's ListingConfigured handler now
        // touches two extra pending maps + a larger EvtListingDeployed, and 0.01
        // no longer covers that compute (observed exit -14).
        send(SendParameters{
            to: sender(),
            value: ton("0.03"),
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
    // Renew: seller pays renewFee to extend the listing another listingWindow.
    // No upper bound on lateness — a lapsed (expired) listing can still be
    // renewed rather than forcing the seller to recreate it, so a missed month
    // doesn't strand the listing's address/history.
    // ========================================
    receive(msg: RenewListing) {
        require(self.active, "Listing not active");   // never renewable before ConfigureListing (renewFee still 0) or after destroy
        require(sender() == self.seller, "Only seller");
        require(context().value >= self.renewFee, "Insufficient renewal fee");

        let base: Int = now();
        if (self.expiresAt > base) { base = self.expiresAt; }
        self.expiresAt = base + self.listingWindow;

        // Fee flows through the OWNER (the factory) so all marketplace revenue —
        // creation AND renewal — is accounted in one place (totalFeesCollected)
        // and withdrawn via the factory's WithdrawFees. The factory credits the
        // actual TON it receives (see its CollectRenewalFee handler). When a
        // listing is instead configured directly by a wallet owner, this simply
        // pays that owner. Any excess above renewFee stays here as operating
        // buffer, same as ConfigureListing's ack pattern.
        send(SendParameters{
            to: self.owner,
            value: self.renewFee,
            mode: SendPayGasSeparately,
            bounce: false,
            body: CollectRenewalFee{ listingId: self.listingId }.toCell()
        });

        emit(EvtListingRenewed{
            listingId: self.listingId,
            seller:    self.seller,
            expiresAt: self.expiresAt
        }.toCell());
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
    // V3.1 Tier 3 — post-configuration edits (no destroy + recreate)
    // ========================================
    // All of these change only what FUTURE purchases inherit. Vaults already
    // deployed are independent contracts and keep the price / terms / windows they
    // were seeded with — a buyer's agreed deal never shifts under them.

    // Seller re-prices remaining inventory.
    receive(msg: UpdatePrice) {
        require(sender() == self.seller, "Only seller");
        require(self.active, "Listing not active");
        require(msg.pricePerUnit > 0, "Price must be positive");
        require(msg.pricePerUnit <= self.MaxTradeValue, "pricePerUnit too large");
        self.pricePerUnit = msg.pricePerUnit;
        emit(EvtListingPriceUpdated{ listingId: self.listingId, pricePerUnit: msg.pricePerUnit }.toCell());
    }

    // Seller adds inventory (e.g. after selling out) without a new listing address.
    receive(msg: RestockListing) {
        require(sender() == self.seller, "Only seller");
        require(self.active, "Listing not active");
        require(msg.addSupply > 0, "Restock must be positive");
        // remainingSupply <= initialSupply always, so bounding the initialSupply
        // sum covers both fields.
        require(self.initialSupply + msg.addSupply <= self.MaxUint64, "Restock overflow");
        self.initialSupply = self.initialSupply + msg.addSupply;
        self.remainingSupply = self.remainingSupply + msg.addSupply;
        emit(EvtListingRestocked{
            listingId:       self.listingId,
            addSupply:       msg.addSupply,
            remainingSupply: self.remainingSupply
        }.toCell());
    }

    // Seller updates the off-chain terms anchor — fix a typo, swap the listing
    // photo, revise the shipment window. Buyers of existing vaults are unaffected.
    receive(msg: UpdateAgreementCID) {
        require(sender() == self.seller, "Only seller");
        require(self.active, "Listing not active");
        self.agreementCID = msg.agreementCID;
        emit(EvtListingTermsUpdated{ listingId: self.listingId }.toCell());
    }

    // Owner (the factory) repoints protocol infra for this listing's FUTURE vaults —
    // e.g. after an OracleRegistry migration. Existing vaults keep their addresses.
    receive(msg: UpdateProtocolAddrs) {
        self.requireOwner();
        self.oracleRegistry = msg.oracleRegistry;
        self.commissionairesDao = msg.commissionairesDao;
        emit(EvtListingTermsUpdated{ listingId: self.listingId }.toCell());
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
        require(now() <= self.expiresAt, "Listing expired");

        // V3.1: buyer-chosen quantity, bounded by MOQ / per-order cap / stock.
        let qty: Int = msg.quantity;
        require(qty >= self.minOrderQty, "Below minimum order");
        require(self.maxOrderQty == 0 || qty <= self.maxOrderQty, "Above maximum order");
        require(qty <= self.remainingSupply, "Insufficient supply");

        let buyer: Address = sender();
        require(buyer != self.seller, "Buyer and seller must differ");

        let msgValue: Int = context().value;
        require(msgValue >= self.VaultGasBudget, "Insufficient gas budget for vault");

        let tradeValue: Int = self.pricePerUnit * qty;
        require(tradeValue > 0 && tradeValue <= self.MaxTradeValue, "Trade value out of range");

        self.seenNonce.set(nonceKey, true);
        self.remainingSupply = self.remainingSupply - qty;

        let tradeId: Int = self.nextTradeId;
        self.nextTradeId = self.nextTradeId + 1;

        let vaultInit: StateInit = initOf EscrowOracleVault(myAddress(), self.dao, tradeId);
        let vaultAddress: Address = contractAddress(vaultInit);

        self.pendingBuyer.set(tradeId, buyer);
        self.pendingByVault.set(vaultAddress, tradeId);
        self.pendingRefund.set(tradeId, msgValue);
        self.pendingQty.set(tradeId, qty);   // V3.1: restore this exact amount on bounce
        self.pendingPrice.set(tradeId, self.pricePerUnit);   // MK-N1
        self.pendingNonceKey.set(tradeId, nonceKey);          // MK-N2
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
                tradeValue: tradeValue,                 // V3.1: pricePerUnit * qty (was pricePerUnit)
                guaranteePercent: self.guaranteePercent,
                commissionPercent: self.commissionPercent,
                commissionairesDao: self.commissionairesDao,
                deadline: now() + self.deadlineWindow,
                oracleRegistry: self.oracleRegistry,
                validationType: self.validationType,
                agreementCID: self.agreementCID,
                settlementMode: self.settlementMode,
                // V3.1 Tier 2: per-listing dispute-timing windows (were vault consts)
                objectionWindow: self.objectionWindow,
                disputeTimeoutWindow: self.disputeTimeoutWindow,
                destroyGraceWindow: self.destroyGraceWindow
            }.toCell()
        });
    }

    receive(msg: VaultInitOk) {
        let vaultAddress: Address = sender();
        require(self.pendingByVault.exists(vaultAddress), "Only a deployed vault");
        require(self.pendingByVault.get(vaultAddress)!! == msg.tradeId, "Mismatched pending vault");

        let buyer: Address = self.pendingBuyer.get(msg.tradeId)!!;
        self.vaultsDeployed = self.vaultsDeployed + 1;

        let qty: Int = self.pendingQty.get(msg.tradeId)!!;
        // MK-N1: report the price actually charged at purchase time, not the
        // listing's CURRENT price — the seller can re-price between purchase and
        // this ack, which would otherwise misreport what the buyer actually paid.
        let price: Int = self.pendingPrice.get(msg.tradeId)!!;
        emit(EvtListingVaultDeployed{
            listingId:    self.listingId,
            tradeId:      msg.tradeId,
            vaultAddress: vaultAddress,
            buyer:        buyer,
            seller:       self.seller,
            pricePerUnit: price,
            quantity:     qty,
            tradeValue:   price * qty
        }.toCell());

        self.pendingBuyer.del(msg.tradeId);
        self.pendingByVault.del(vaultAddress);
        self.pendingRefund.del(msg.tradeId);
        self.pendingQty.del(msg.tradeId);
        self.pendingPrice.del(msg.tradeId);
        self.pendingNonceKey.del(msg.tradeId);
        self.pendingCount = self.pendingCount - 1;
    }

    bounced(msg: Slice) {
        let vaultAddress: Address = sender();
        if (!self.pendingByVault.exists(vaultAddress)) { return; }
        let tradeId: Int = self.pendingByVault.get(vaultAddress)!!;
        let buyer: Address = self.pendingBuyer.get(tradeId)!!;
        let qty: Int = self.pendingQty.get(tradeId)!!;

        // Vault deploy failed → return the units to inventory, clear pending, and
        // refund the buyer's purchase value. The bounce returns most of what we
        // forwarded (msgValue) minus gas actually burned at the destination.
        self.remainingSupply = self.remainingSupply + qty;
        if (self.remainingSupply > self.initialSupply) { self.remainingSupply = self.initialSupply; }
        self.pendingCount = self.pendingCount - 1;

        let refundableBalance: Int = context().value - ton("0.02");
        if (refundableBalance < 0) { refundableBalance = 0; }
        let refundAmount: Int = min(self.pendingRefund.get(tradeId)!!, refundableBalance);

        // MK-N2: release the nonce so the buyer's wallet can auto-retry the exact
        // same signed purchase form — without this a bounced deploy leaves it
        // permanently "seen" and every retry bounces on "Duplicate purchase submission".
        if (self.pendingNonceKey.exists(tradeId)) {
            self.seenNonce.del(self.pendingNonceKey.get(tradeId)!!);
            self.pendingNonceKey.del(tradeId);
        }
        self.pendingPrice.del(tradeId); // MK-N1

        self.pendingBuyer.del(tradeId);
        self.pendingByVault.del(vaultAddress);
        self.pendingRefund.del(tradeId);
        self.pendingQty.del(tradeId);

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
            listingId:            self.listingId,
            pricePerUnit:         self.pricePerUnit,
            minOrderQty:          self.minOrderQty,
            maxOrderQty:          self.maxOrderQty,
            validationType:       self.validationType,
            settlementMode:       self.settlementMode,
            guaranteePercent:     self.guaranteePercent,
            commissionPercent:    self.commissionPercent,
            deadlineWindow:       self.deadlineWindow,
            objectionWindow:      self.objectionWindow,
            disputeTimeoutWindow: self.disputeTimeoutWindow,
            destroyGraceWindow:   self.destroyGraceWindow,
            active:               self.active,
            initialSupply:        self.initialSupply,
            remainingSupply:      self.remainingSupply,
            vaultsDeployed:       self.vaultsDeployed,
            expiresAt:            self.expiresAt,
            renewFee:             self.renewFee
        };
    }

    get fun initialSupply(): Int { return self.initialSupply; }
    get fun remainingSupply(): Int { return self.remainingSupply; }
    get fun vaultsDeployed(): Int { return self.vaultsDeployed; }
    get fun pendingCount(): Int { return self.pendingCount; }
    get fun active(): Bool { return self.active; }
    get fun expiresAt(): Int { return self.expiresAt; }
    get fun renewFee(): Int { return self.renewFee; }
    get fun listingWindow(): Int { return self.listingWindow; }
    get fun minOrderQty(): Int { return self.minOrderQty; }
    get fun maxOrderQty(): Int { return self.maxOrderQty; }
    get fun listingGuaranteePercent(): Int { return self.guaranteePercent; }
    get fun listingCommissionPercent(): Int { return self.commissionPercent; }
    get fun listingObjectionWindow(): Int { return self.objectionWindow; }
    get fun listingDisputeTimeoutWindow(): Int { return self.disputeTimeoutWindow; }
    get fun listingDestroyGraceWindow(): Int { return self.destroyGraceWindow; }
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
