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

**Independent external security audits run on a regular, continuous cadence, and
reports are published in this repo as they complete.**

**Internal audit (2026-11):** the complete contract set — V1 native-TON escrow
(factories, vaults, milestone), V2 USDT-jetton escrow (regular + milestone), and
V3 (oracle registry, oracle vault, marketplace factory + listing) — passed a full
internal security audit. Every finding, one High through all Medium and Low items,
was remediated and then **independently re-verified against the code**. The report,
including the verification record, is published in
[`audit_v3/`](./audit_v3/Garantor_V1_V2_V3_Audit_Report.md) — this repo's source
matches the audited and remediated code. The full internal suite runs 17 test
packages / 267 sandbox tests, fully green; the contract specs mirrored here are
part of that suite.

**Deployment status:**
- **V1 (native-TON escrow)** — live on TON Mainnet.
- **V2 (USDT jetton escrow)** — live on TON Mainnet.
- **V3 (oracle + marketplace)** — live on TON Mainnet. The shipping-attestation
  data provider (IoT/DON) is not yet activated; trades settle via buyer
  confirmation and the dispute/arbitration path until it is. The accepted
  single-attestor trust model and objection window are documented in the audit
  report.

This repo is updated as audit status changes.

## Scope of this repo

This is the contracts-only slice of the Garantor DAO codebase — it does not include the frontend, backend, or deployment/ops tooling, which remain in private repos.

## License

MIT — see [LICENSE](LICENSE).

## Community

- App: https://app.garantor.io
- Telegram: https://t.me/garantor_dao
- Discord: https://discord.gg/6pG9gqBzH
