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

## Installation

```bash
# Clone the repo
git clone https://github.com/papre-demo-2/papre-contracts.git
cd papre-contracts

# Install dependencies
forge install
npm install

# Build
forge build

# Test
forge test
```

## Deployment

### Local (Anvil)

```bash
forge script script/DeployLocal.s.sol --broadcast
```

### Fuji Testnet

```bash
# Set environment variables
export DEPLOYER_PRIVATE_KEY=<your-key>
export FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc

# Deploy
forge script script/DeployFuji.s.sol --rpc-url $FUJI_RPC_URL --broadcast -vvvv
```

## Development

```bash
# Run tests with gas report
forge test --gas-report

# Run specific test
forge test --match-test testFunctionName

# Coverage
forge coverage
```

## License

MIT
