// ============================================================
// mock_jetton.tact — minimal TEP-74 jetton (master + wallet)
// FOR TESTS ONLY. Not for deployment. Models the standard transfer /
// internal_transfer / transfer_notification + ProvideWalletAddress flow so the
// EscrowJettonVault can be exercised against a realistic jetton in sandbox.
// ============================================================

message(0x0f8a7ea5) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(0x178d4519) JettonInternalTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    from: Address;
    responseAddress: Address;
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

message(0x42000001) MockMint {
    to: Address;
    amount: Int as coins;
}

struct JettonWalletData {
    balance: Int as coins;
    owner: Address;
    master: Address;
    walletCode: Cell;            // TEP-74 get_wallet_data field #4
}

struct JettonMasterData {
    totalSupply: Int as coins;
    mintable: Bool;
    adminAddress: Address;
    jettonContent: Cell;
    jettonWalletCode: Cell;
}

// ─── Master ───────────────────────────────────────────────────────────────────

contract MockJettonMaster {
    totalSupply: Int as coins;
    owner: Address;
    jettonContent: Cell;          // TEP-64 metadata cell (built off-chain at deploy)

    init(owner: Address, content: Cell) {
        self.totalSupply = 0;
        self.owner = owner;
        self.jettonContent = content;
    }

    // TEP-89 jetton metadata so wallets show symbol/decimals + read balances.
    get fun get_jetton_data(): JettonMasterData {
        return JettonMasterData{
            totalSupply:      self.totalSupply,
            mintable:         true,
            adminAddress:     self.owner,
            jettonContent:    self.jettonContent,
            jettonWalletCode: initOf MockJettonWallet(myAddress(), myAddress()).code,
        };
    }

    // Test helper: mint `amount` to `to` by deploying/crediting their wallet.
    receive(msg: MockMint) {
        require(sender() == self.owner, "Only owner can mint");
        self.totalSupply = self.totalSupply + msg.amount;

        let winit: StateInit = initOf MockJettonWallet(msg.to, myAddress());
        send(SendParameters{
            to:     contractAddress(winit),
            value:  ton("0.05"),
            mode:   SendPayGasSeparately,
            bounce: false,
            code:   winit.code,
            data:   winit.data,
            body:   JettonInternalTransfer{
                queryId:          0,
                amount:           msg.amount,
                from:             myAddress(),
                responseAddress:  self.owner,
                forwardTonAmount: 0,
                forwardPayload:   beginCell().storeUint(0, 1).endCell().asSlice()
            }.toCell()
        });
    }

    // TEP-89 wallet-address discovery.
    receive(msg: ProvideWalletAddress) {
        let winit: StateInit = initOf MockJettonWallet(msg.ownerAddress, myAddress());
        send(SendParameters{
            to:     sender(),
            value:  0,
            mode:   SendRemainingValue,
            bounce: false,
            body:   TakeWalletAddress{
                queryId:       msg.queryId,
                walletAddress: contractAddress(winit),
                ownerAddress:  beginCell().storeUint(0, 1).endCell().asSlice()  // Maybe = none
            }.toCell()
        });
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf MockJettonWallet(owner, myAddress()));
    }

    get fun totalSupply(): Int { return self.totalSupply; }
}

// ─── Wallet ─────────────────────────────────────────────────────────────────

contract MockJettonWallet {
    balance: Int as coins;
    owner: Address;
    master: Address;

    init(owner: Address, master: Address) {
        self.balance = 0;
        self.owner = owner;
        self.master = master;
    }

    // Owner initiates an outbound transfer.
    receive(msg: JettonTransfer) {
        require(sender() == self.owner, "Not wallet owner");
        require(self.balance >= msg.amount, "Insufficient jetton balance");
        self.balance = self.balance - msg.amount;

        let winit: StateInit = initOf MockJettonWallet(msg.destination, self.master);
        send(SendParameters{
            to:     contractAddress(winit),
            value:  0,
            mode:   SendRemainingValue,
            bounce: false,
            code:   winit.code,
            data:   winit.data,
            body:   JettonInternalTransfer{
                queryId:          msg.queryId,
                amount:           msg.amount,
                from:             self.owner,
                responseAddress:  msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload:   msg.forwardPayload
            }.toCell()
        });
    }

    // Credit from the master (mint) or a sibling wallet (transfer in).
    receive(msg: JettonInternalTransfer) {
        let expectedSibling: Address = contractAddress(initOf MockJettonWallet(msg.from, self.master));
        require(sender() == self.master || sender() == expectedSibling, "Unauthorized internal transfer");
        self.balance = self.balance + msg.amount;

        if (msg.forwardTonAmount > 0) {
            send(SendParameters{
                to:     self.owner,
                value:  msg.forwardTonAmount,
                mode:   SendPayGasSeparately,
                bounce: false,
                body:   JettonTransferNotification{
                    queryId:        msg.queryId,
                    amount:         msg.amount,
                    sender:         msg.from,
                    forwardPayload: msg.forwardPayload
                }.toCell()
            });
        }
    }

    get fun get_wallet_data(): JettonWalletData {
        return JettonWalletData{ balance: self.balance, owner: self.owner, master: self.master, walletCode: myCode() };
    }

    get fun balance(): Int { return self.balance; }
}
