# Garantor Contracts

On-chain escrow, milestone, jetton, and oracle-marketplace smart contracts powering [Garantor DAO](https://app.garantor.io), a non-custodial escrow protocol on TON.

Written in [Tact](https://tact-lang.org/), TON's typed smart contract language. Built and tested with [Blueprint](https://github.com/ton-org/blueprint).

## What's here

| Contract | Purpose |
|---|---|
| `escrow_factory.tact` / `escrow_vault.tact` | V1 — regular native-TON escrow vaults, deployed per trade |
| `escrow_milestone_factory.tact` / `escrow_vault_milestone.tact` | V1 — milestone/phased escrow vaults |
| `escrow_jetton_factory.tact` / `escrow_jetton_vault.tact` | V2 — jetton (USDT, etc.) escrow vaults |
| `escrow_jetton_milestone_factory.tact` / `escrow_jetton_vault_milestone.tact` | V2 — jetton milestone escrow vaults |
| `oracle_registry.tact` / `escrow_oracle_vault.tact` | V3 — oracle-settled vaults for physical/commodity trades |
| `marketplace_factory.tact` / `marketplace_listing.tact` | V3 — oracle marketplace listings |
| `mock_jetton.tact` | Test-only mock jetton master, used in the test suite |

Design docs for each generation live alongside the contracts:
- [`contracts/V2_JETTON_ESCROW_DESIGN.md`](contracts/V2_JETTON_ESCROW_DESIGN.md)
- [`contracts/V3_ORACLE_MARKETPLACE_DESIGN.md`](contracts/V3_ORACLE_MARKETPLACE_DESIGN.md)
- [`contracts/V3_ORACLE_SETTLEMENT_FLOW.md`](contracts/V3_ORACLE_SETTLEMENT_FLOW.md)
- [`contracts/V3_SHIPPING_ORACLE.md`](contracts/V3_SHIPPING_ORACLE.md)

## Build & test

```bash
npm install
npm run build:all   # compile every contract
npm test            # run the sandbox test suite
```

## Audit status

The V1 escrow contracts are live on TON Mainnet. The V2 jetton contracts and V3 oracle marketplace are currently **testnet-only and have not yet completed an external security audit** — treat them as a preview, not production-ready, until that audit is complete. This repo will be updated as audit status changes.

## Scope of this repo

This is the contracts-only slice of the Garantor DAO codebase — it does not include the frontend, backend, or deployment/ops tooling, which remain in private repos.

## License

MIT — see [LICENSE](LICENSE).

## Community

- App: https://app.garantor.io
- Telegram: https://t.me/garantor_dao
- Discord: https://discord.gg/6pG9gqBzH
