# Papre Contracts

Composable agreement smart contracts for the Papre Protocol.

## Overview

Papre is a modular smart contract protocol for creating composable legal agreements on-chain. The architecture separates concerns into:

- **Clauses** - Reusable logic primitives (signatures, escrow, streaming, arbitration, etc.)
- **Agreements** - Templates that compose clauses for specific use cases
- **Adapters** - Bridge clauses for atomic cross-clause operations
- **Factory** - Creates minimal proxy instances of agreement templates

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AgreementFactoryV3                       │
│         Creates ERC-1167 minimal proxy instances            │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                   Agreement Templates                        │
│  FreelanceService │ Retainer │ SafetyNet │ MilestonePayment │
└─────────────────────────┬───────────────────────────────────┘
                          │ compose via delegatecall
┌─────────────────────────▼───────────────────────────────────┐
│                      Clause Logic                            │
│  Signature │ Escrow │ Streaming │ Arbitration │ Milestone   │
│  Declarative │ Deadline │ PartyRegistry │ CrossChain        │
└─────────────────────────────────────────────────────────────┘
```

## Contracts

### Agreements

| Contract | Description | Clauses Used |
|----------|-------------|--------------|
| `FreelanceServiceAgreement` | Simple freelance work escrow | Signature, Escrow, Declarative |
| `RetainerAgreement` | Ongoing retainer with streaming payments | Signature, Escrow |
| `SubcontractorSafetyNetAgreement` | Subcontractor protection with arbitration | Signature, Escrow, Arbitration |
| `MilestonePaymentAgreement` | Multi-milestone projects | Signature, Escrow, Milestone |

### Clauses

| Category | Contract | Purpose |
|----------|----------|---------|
| Attestation | `SignatureClauseLogicV3` | Collect and verify signatures |
| Financial | `EscrowClauseLogicV3` | Hold/release/refund funds |
| Financial | `StreamingClauseLogicV3` | Continuous payment streaming |
| Content | `DeclarativeClauseLogicV3` | Store immutable agreement metadata |
| Access | `PartyRegistryClauseLogicV3` | Party/role management |
| Governance | `ArbitrationClauseLogicV3` | Dispute resolution |
| Orchestration | `MilestoneClauseLogicV3` | Multi-milestone coordination |
| State | `DeadlineClauseLogicV3` | Time-based triggers |
| CrossChain | `CrossChainClauseLogicV3` | CCIP messaging |

## Getting Started

### Prerequisites

- **Foundry** - Solidity development toolkit
- **Node.js 18+** - For npm dependencies (Chainlink)

### Installing Foundry

If you don't have Foundry installed:

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash

# Reload your shell, then run:
foundryup
```

Verify installation:
```bash
forge --version
```

### Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/papre-demo-2/papre-contracts.git
cd papre-contracts

# 2. Install Foundry dependencies (OpenZeppelin, forge-std)
forge install

# 3. Install npm dependencies (Chainlink CCIP)
npm install

# 4. Build contracts
forge build

# 5. Run tests
forge test
```

### Environment Variables (for deployment)

For deploying to testnets/mainnet, create a `.env` file:

```bash
# Private key for deployments (never commit this!)
DEPLOYER_PRIVATE_KEY=0x...

# RPC URLs
FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc

# Verification (optional)
SNOWTRACE_API_KEY=...
```

Then source it:
```bash
source .env
```

## Development

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run tests with gas report
forge test --gas-report

# Run specific test
forge test --match-test testFunctionName

# Run with verbosity
forge test -vvvv
```

### Coverage

```bash
forge coverage
```

## Deployment

### Local (Anvil)

```bash
# Start Anvil in one terminal
anvil

# Deploy in another terminal
forge script script/DeployLocal.s.sol --broadcast --rpc-url http://localhost:8545
```

### Fuji Testnet

```bash
# Make sure .env is sourced
source .env

# Deploy
forge script script/DeployFuji.s.sol --rpc-url $FUJI_RPC_URL --broadcast -vvvv

# With verification
forge script script/DeployFuji.s.sol --rpc-url $FUJI_RPC_URL --broadcast --verify -vvvv
```

## Current Deployments

### Avalanche Fuji Testnet

| Contract | Address |
|----------|---------|
| AgreementFactoryV3 | See papre-app `src/lib/contracts.ts` |
| FreelanceServiceAgreement | See papre-app `src/lib/contracts.ts` |
| MilestonePaymentAgreement | See papre-app `src/lib/contracts.ts` |
| RetainerAgreement | See papre-app `src/lib/contracts.ts` |

## Troubleshooting

### "Stack too deep" errors
The project uses `via_ir = true` in `foundry.toml` which should prevent this. If you still see issues, ensure you're using Solidity 0.8.28+.

### Chainlink import errors
Make sure you ran `npm install` for the Chainlink CCIP dependencies.

### OpenZeppelin import errors
Make sure you ran `forge install` for the Foundry dependencies.

## License

MIT
