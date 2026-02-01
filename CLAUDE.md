# Papre Contracts — Claude Code Context

## CRITICAL: Network Environment

**ALWAYS use Fuji (Avalanche Testnet) unless explicitly told otherwise.**

- Contracts are deployed to Fuji
- Never suggest local Anvil unless specifically requested
- The papre-app connects to Fuji by default

This has been a recurring issue. DO NOT suggest Anvil/localhost chains.

---

## Start Here

**Before doing anything, read `BACKLOG.md`** — it's the shared Kanban board tracking current work, next priorities, and future features. Check "In Progress" for immediate tasks.

---

## Contributing Guidelines

**Always follow `CONTRIBUTING.md`** — it contains the git workflow, code standards, and documentation requirements. The same rules apply to AI and human contributors.

**Enforce these rules** when committing, pushing, or reviewing code:
1. Run `forge test` before any commit (must pass) — **automated via Husky pre-commit**
2. Run `npm run test:all` in `packages/builder` before committing builder changes (runs unit + e2e tests) — **unit tests automated via Husky pre-commit**
3. Run `./scripts/export-docs.sh` before any push — **automated via Husky pre-push**
4. Delete feature branches immediately after merge
5. Flag stale branches (>1 week old)

**Builder Testing Guide:** See `docs/builder-testing.md` for details on:
- Unit tests (Vitest) vs E2E tests (Playwright)
- How to write E2E tests with `data-testid` attributes
- When to add new tests

---

## Development Tools

The monorepo uses several tools to enforce workflow rules automatically:

### Husky (Git Hooks)

Git hooks are configured in `.husky/` and run automatically:

| Hook | Trigger | Actions |
|------|---------|---------|
| `pre-commit` | `git commit` | Runs `forge test` if `.sol` files changed; runs `npm run test:run` if builder files changed |
| `pre-push` | `git push` | Runs `export-docs.sh` and blocks push if docs have uncommitted changes |

**Result:** You no longer need to remember to run tests — commits are blocked if tests fail.

### Turborepo (Build Caching)

Turborepo caches build and test results across the monorepo:

```bash
npm run test        # Runs all tests, skips unchanged packages
npm run build       # Builds all packages with caching
npm run test:sol    # Forge tests only
npm run test:builder # Builder tests only
```

**Result:** Repeated test runs are instant for unchanged code. Particularly useful for Conductor parallel workspaces.

### Slither (Security Analysis)

Static analysis for Solidity security vulnerabilities:

```bash
# One-time setup (requires Python 3.8+)
./scripts/setup-slither.sh

# Run security analysis
npm run slither             # Analyze all packages
npm run slither:primitives  # Analyze primitives only
slither packages/primitives # Direct command
```

**When to run:** Before major releases, after security-sensitive changes, or periodically during development. Not enforced automatically (too noisy for every commit).

**Configuration:** `slither.config.json` excludes test files and dependencies.

### Anvil State Persistence

Anvil state should be preserved across development sessions to avoid redeploying contracts.

**State file location:** `.anvil/state.json` (gitignored)

**When to save state:**
- Before any `git commit` or `git merge`
- Before shutting down Anvil
- After significant contract deployments

**When to load state:**
- When starting Anvil for development

**Commands:**
```bash
# Save current Anvil state
mkdir -p .anvil && curl -X POST --data '{"jsonrpc":"2.0","method":"anvil_dumpState","params":[],"id":1}' \
  -H "Content-Type: application/json" http://localhost:8545 | jq -r '.result' | xxd -r -p > .anvil/state.json

# Start Anvil with saved state
anvil --load-state .anvil/state.json

# Start fresh Anvil (no state)
anvil
```

**Workflow integration:**
- Before committing: Save Anvil state so you can resume after switching branches
- Before merging: Save state in case merge introduces breaking contract changes
- After pulling: Consider whether to load old state or redeploy fresh

**Note:** Anvil runs as a background process and survives editor restarts. Check with `ps aux | grep anvil` if unsure whether it's running.

### Quick Commands

| Task | Command |
|------|---------|
| Run all tests | `npm run test` |
| Run Solidity tests only | `npm run test:sol` |
| Run builder tests only | `npm run test:builder` |
| Build everything | `npm run build` |
| Export docs | `npm run export-docs` |
| Security analysis | `npm run slither` |
| Start builder dev server | `npm run dev` |
| Save Anvil state | `mkdir -p .anvil && curl -X POST --data '{"jsonrpc":"2.0","method":"anvil_dumpState","params":[],"id":1}' -H "Content-Type: application/json" http://localhost:8545 \| jq -r '.result' \| xxd -r -p > .anvil/state.json` |
| Start Anvil with state | `anvil --load-state .anvil/state.json` |

---

## Parallel Work with Conductor

For large features that can be split into independent tasks, use **Conductor** to run multiple Claude agents in parallel via git worktrees.

### Conductor vs Agent Delegation

There are two ways to parallelize work:

| Term | Tool | How It Works |
|------|------|--------------|
| **Conductor** | External program | Claude produces a `WORKSPACES.md` file with detailed instructions. The user runs Conductor, which creates git worktrees and spawns Claude Code instances in each as sandboxed workspaces. |
| **Agent** | Task tool | Claude directly spawns subagents using the Task tool. Agents run immediately and report back. Claude merges their work. |

**When the user says:**
- "Use Conductor" → Produce a `WORKSPACES.md` document; the user will run Conductor separately
- "Use agents" or "delegate" → Use the Task tool to spawn parallel agents directly

**See `docs/conductor-workflow.md`** for:
- When to use Conductor (3+ independent tasks)
- Workspace document structure (stages, separators, shared types)
- Post-merge workflow (verify, cleanup, push)
- Branch naming conventions

**Workspace docs live in:** `packages/{package}/workspaces/*.md`

---

## Workflow Rules

**Before any `git push`**: Always run `papre-docs` (or the full path `./scripts/export-docs.sh`) to sync documentation from the Obsidian vault to `docs/`. Commit any changes from the export before pushing.

**After any major change**: Update the changelog by prepending a summary to the TOP of the vault's `CHANGELOG.md` (located in iCloud at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/papre-vault/CHANGELOG.md`). Major changes include:
- New clauses or agreements
- Significant refactors
- Test suite restructuring
- Architecture changes
- New features or capabilities

The changelog entry should include:
1. Date and title (e.g., `## 2024-11-28: Test Suite Restructuring`)
2. Brief summary of what changed
3. Detailed breakdown with tables/lists as appropriate
4. Key categories or features affected

Example format:
```markdown
## YYYY-MM-DD: Title of Change

**Summary:** One-line description of the change.

### Details
- Bullet points or tables describing specifics
- Include file names, test counts, etc. where relevant

---
```

The changelog is exported to `docs/CHANGELOG.md` via the export script.

---

## Conductor Workflow (Parallel Workspaces)

For large features, use **Conductor** to run multiple workspace agents in parallel. Workspace definitions are in `packages/builder/WORKSPACES.md`.

### When to Use Conductor

- Multi-file features that can be split into independent tasks
- Building out a new package with multiple components
- Any work that can be parallelized across 4+ tasks

### Workflow

1. **Define workspaces** in a `WORKSPACES.md` file with:
   - Clear task boundaries (what files each workspace owns)
   - Code conventions section (naming, types, available imports)
   - "BEFORE YOU START" sections with commands to check existing code
   - Commit instructions (workspaces MUST commit their work)

2. **Run workspaces in stages** (parallel within stage, sequential across stages):
   ```
   Stage 1: Foundation (no dependencies) → run in parallel
   Stage 2: Features (depends on Stage 1) → run in parallel after Stage 1 merges
   Stage 3: Integration (depends on Stage 2) → run in parallel after Stage 2 merges
   Stage 4: Final polish → Claude does this directly (not via workspace)
   ```

3. **After each stage completes**:
   - Merge all workspace branches to main
   - Run `npx tsc --noEmit` to check for integration errors
   - Fix any type mismatches, missing exports, convention violations
   - Commit fixes, push, then start next stage

4. **Final integration** (Stage 4): Do this yourself, not via workspace agent. You can see all the pieces and fix issues immediately.

### Reducing Integration Errors

Add these to workspace instructions:
- **Conventions**: Naming rules, case conventions, type patterns
- **Type structure reference**: Show actual shapes (e.g., "inputs is a flat array, not grouped")
- **Available exports**: What functions/types exist to import
- **Available UI components**: What's already built vs needs creation

### Example Stage Workflow

```bash
# After Stage 2 workspaces complete:
git worktree list                    # See workspace branches
git merge workspace-branch-1         # Merge each branch
git merge workspace-branch-2
npx tsc --noEmit                     # Check for errors
# Fix any errors...
git add . && git commit -m "Fix Stage 2 integration"
git worktree remove .conductor/...   # Clean up worktrees
git branch -d workspace-branch-1     # Delete merged branches
git push                             # Push before Stage 3
```

---

## Project Vision

Composable agreement infrastructure for trustless coordination.
Backend infrastructure where agreements are compositions of atomic clauses.

**Core insight**: Agreements are minimal data containers; Clauses are single-purpose primitives with standardized interfaces. The microkernel pattern — Agreements delegate all behavior to Clauses.

## Architecture Principles

- **Microkernel**: Agreements hold no logic, only compose Clauses
- **Pure Lego Brick**: Each Clause is self-contained, stateless where possible, composable by design
- **Port interfaces**: Standardized input/output signatures for Clause interoperability
- **Separation of concerns**: Interfaces, implementations, and tests live apart
- **OpenZeppelin first**: Use battle-tested contracts, don't reinvent
- **Minimal surface area**: Each clause does one thing well

## Current Implementation Focus

Building toward: **50 audited, reusable Clauses powering 100 production Agreements**

### Core Clauses (in development)
- `SignatureClause` — ERC-191, EIP-712, ERC-1271 signature verification
- `EscrowClause` — Value custody with conditional release
- `MultisigClause` — M-of-N approval patterns
- `TimeLockClause` — Time-based constraints
- `PartyRegistryClause` — Agreement participant management
- `ExecutionClause` — Orchestration primitive

### Clause Interface Pattern
```solidity
interface IClause {
    function execute(bytes calldata context) external returns (bytes memory);
    function validate(bytes calldata context) external view returns (bool);
}
```

## Documentation Workflow

**Source of truth: Obsidian vault (iCloud)**

Location: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/papre-vault/`

```
papre-vault/
├── Architecture/    → Core design (microkernel, clause families, binding modes)
├── Specs/           → Detailed specifications (clauses, agreements)
│   ├── Clauses/     → Individual clause specs
│   └── Agreements/  → Agreement specs
├── Process/         → How we work (workflows, tooling, team practices)
├── Philosophy/      → Internal: the "why" behind the "what"
├── Decisions/       → Internal: strategic decisions
└── Sessions/        → Internal: working notes
```

**Folder purposes:**
- **Specs/** — Technical *what* (interfaces, implementations, requirements)
- **Decisions/** — Strategic *what* and *why* (goals, roadmap, choices)
- **Process/** — Operational *how* (workflows, tooling, team practices)

**Export to GitHub:**
```bash
./scripts/export-docs.sh
```

This syncs Architecture/ and Specs/ to `docs/`, converting Obsidian wikilinks to standard markdown.

## Code Conventions

### File Organization
- **Primitives** (foundational building blocks):
  - Interfaces: `packages/primitives/src/interfaces/I{Name}.sol`
  - Clauses by family: `packages/primitives/src/clauses/{family}/{Name}Clause.sol`
  - Libraries: `packages/primitives/src/libraries/{Name}.sol`
  - Base contracts: `packages/primitives/src/base/PapreAgreement.sol`
  - Primitives tests: `packages/primitives/test/`

- **Agreements** (each agreement type gets its own folder):
  - `packages/agreements/signing/` — SigningAgreement, DependentSigningAgreement
  - `packages/agreements/milestone/` — MilestoneAgreement
  - Each has: `src/`, `test/`, `script/`

- **Clause Families** in primitives:
  - `clauses/financial/` — EscrowClause
  - `clauses/attestation/` — SignatureClause
  - `clauses/access/` — PartyRegistryClause, LitAccessClause
  - `clauses/state/` — TimeLockClause
  - `clauses/orchestration/` — SequentialExecutionClause
  - `clauses/governance/` — ArbitrationClause
  - `clauses/content/` — DeclarativeClause

### Foundry Configuration
All packages use `via_ir = true` in `foundry.toml` to enable IR-based code generation. This:
- Avoids "stack too deep" errors in complex contracts
- Enables better optimizer passes
- Is required for tests with many local variables

```toml
[profile.default]
solc = "0.8.28"
optimizer = true
optimizer_runs = 200
via_ir = true
```

### Solidity Style
- Solidity version: 0.8.28
- Use custom errors, not require strings
- Events for all state changes
- NatSpec documentation on all public/external functions
- Explicit visibility on all functions and state variables

### Comments
- File headers with purpose and author
- Section dividers for logical groupings
- Brief philosophical context where it illuminates intent
- Comments that acknowledge the rasa of building coordination infrastructure

### Testing

**Solidity (Foundry)**
- Unit tests cover isolated contract behavior
- Integration tests cover contract interactions
- Use Foundry's fuzzing for edge cases
- Test naming: `test_FunctionName_Condition_ExpectedResult`

**Builder (Vitest)**
- Run: `cd packages/builder && npm run test:run`
- Tests cover: validation rules, connection validation, engine logic
- Location: `src/lib/**/__tests__/*.test.ts`
- Focus on pure functions (validation helpers, cycle detection, interface compatibility)

## Key Dependencies

- OpenZeppelin Contracts: Access control, cryptography, security patterns
- Foundry: Build, test, deploy

## Quick Reference

### Clause Families
1. **FINANCIAL** — Hold, move, transform value
2. **ATTESTATION** — Record and verify claims
3. **STATE** — Track state transitions
4. **ACCESS** — Control capabilities
5. **CONTENT** — Anchor off-chain content
6. **ORCHESTRATION** — Coordinate other Clauses

### Binding Modes
- **PINNED** — Immutable forever
- **LATEST** — Auto-upgrade via beacon
- **RANGE** — Bounded version evolution
- **FORKED** — Custom implementation

### Context Pattern
Clauses receive execution context as `bytes calldata`. Decode with:
```solidity
(address agreement, address caller, bytes memory params) = abi.decode(context, (address, address, bytes));
```

### Multiplexer Library Pattern
Agreements can manage multiple concurrent instances (e.g., multiple document signings) using the embedded `Multiplexer` library. This replaces the old `MultiplexerClause` contract pattern.

**Key concepts:**
- `Multiplexer.Store` is embedded storage in the Agreement contract
- Instances are created via `agreement.createInstance(data)` returning a unique ID
- State transitions via `agreement.setInstanceState(instanceId, newState)`
- State machine: `CREATED → COUNTERSIGNED → EVALUATED → EXECUTED → CLOSED` (plus `CANCELLED` paths)

**Usage in Agreements:**
```solidity
import {Multiplexer} from "@papre/primitives/libraries/Multiplexer.sol";

contract MyAgreement is PapreAgreement {
    using Multiplexer for Multiplexer.Store;
    Multiplexer.Store private _instances;

    constructor(...) {
        _instances.initialize();
    }

    function createInstance(bytes calldata data) external onlyExecutionClause returns (uint256 id) {
        return _instances.create(data);
    }

    function setInstanceState(uint256 id, Multiplexer.State state) external onlyExecutionClause {
        _instances.setState(id, state);
    }

    function getInstanceState(uint256 id) external view returns (Multiplexer.State) {
        return _instances.getState(id);
    }
}
```

**Why embedded library vs external contract:**
- Single deployment (no separate Multiplexer contract per Agreement)
- Lower gas costs (no cross-contract calls)
- Simpler authorization (Agreement controls its own state)
- Prepares for v2 proxy pattern where Agreements become minimal proxies

## Microkernel Architecture (v2)

The `packages/microkernel/` contains the v2 architecture with proxy-based agreements and delegatecall execution.

### Core Components

**AgreementCoreV1** (`src/core/AgreementCoreV1.sol`)
- The singleton implementation for all Agreement proxies
- Uses ERC-7201 namespaced storage for collision-free storage
- Ports map to clause selectors via `ClauseRoute`
- Supports `executePort()` for state changes and `queryPort()` for reads

**AgreementFactory** (`src/core/AgreementFactory.sol`)
- Creates minimal proxies (EIP-1167 clones) pointing to AgreementCoreV1
- Deterministic addresses via CREATE2 with salt
- Tracks all deployed agreements

**ClauseRegistry** (`src/registry/ClauseRegistry.sol`)
- Central registry of clause implementations
- Supports deprecation, reactivation, and removal
- Type compatibility checking via inputTypeId/outputTypeId

### Port Pattern

Ports are named entry points that route to clause functions:

```solidity
// Define ports as keccak256 hashes
bytes32 constant INIT_PORT = keccak256("port.init");
bytes32 constant SIGN_PORT = keccak256("port.sign");
bytes32 constant STATUS_PORT = keccak256("port.status");

// Routes map ports to clause selectors
IAgreementCore.ClauseRoute memory route = IAgreementCore.ClauseRoute({
    clauseId: keccak256("SignatureClause.v1"),
    selector: SignatureClauseLogic.run.selector,
    nextPorts: emptyNext
});
```

### Port Function Naming Conventions

Port functions follow strict naming conventions for consistency across all clauses:

| Prefix | Use Case | Example |
|--------|----------|---------|
| `get{Entity}Port` | Retrieve single entity or value | `getStatusPort`, `getBalancePort`, `getProposalPort` |
| `is{Condition}Port` | Boolean state condition check | `isUnlockedPort`, `isInitializedPort`, `isQuorumReachedPort` |
| `has{Thing}Port` | Boolean existence/occurrence check | `hasVotedPort`, `hasSignedPort`, `hasMinReputationPort` |
| `can{Action}Port` | Permission/capability check | `canAppealPort`, `canExecutePort`, `canWithdrawPort` |
| `list{Entities}Port` | Array/collection enumeration | `listProposalsPort`, `listConditionsPort`, `listDisputesPort` |
| `verify{Thing}Port` | Validation with result | `verifyConditionHashPort`, `verifyDataPort`, `verifyContentPort` |
| `calculate{Value}Port` | Computed values | `calculateProportionPort`, `calculateRewardsPort`, `calculateOwedPort` |

**Distinction between `is` and `has`:**
- `is{Condition}Port` — checks a **state condition** (isUnlocked, isInitialized, isExpired)
- `has{Thing}Port` — checks if something **exists or has occurred** (hasVoted, hasSigned, hasMinReputation)

### Context Pattern (PapreContext)

All clause calls receive a `PapreContext.Context` struct:

```solidity
struct Context {
    address agreement;   // The Agreement proxy address
    bytes32 purpose;     // Domain identifier (e.g., keccak256("signing"))
    bytes32 refHash;     // Content/document hash
    bytes32 salt;        // Uniqueness salt for multiple instances
}

// Instance isolation: each unique context creates independent state
bytes32 instanceId = keccak256(abi.encode(ctx.agreement, ctx.purpose, ctx.refHash, ctx.salt));
```

### SignatureClauseLogic (v2)

Full cryptographic signature verification with 4 schemes:

| Scheme | Description | Use Case |
|--------|-------------|----------|
| `EIP191` | personal_sign / eth_sign | EOA wallets |
| `EIP712` | Typed structured data | EOA with rich UX |
| `ERC1271_EIP191` | Contract wallet + EIP-191 | Smart contract wallets |
| `ERC1271_EIP712` | Contract wallet + EIP-712 | Smart contract wallets |

**Signing payload format:**
```solidity
bytes memory payload = abi.encode(
    signer,                              // address
    SignatureClauseLogic.Scheme.EIP191,  // scheme enum
    signature                            // bytes (65 bytes for ECDSA)
);
```

**Digest helpers for frontend:**
```solidity
// Get the digest to sign
bytes32 digest = clause.getEIP191Digest(ctx, signer);
// or
bytes32 digest = clause.getEIP712Digest(ctx, signer);

// Domain separator for EIP-712
bytes32 domain = clause.getDomainSeparator(agreementAddress);
```

**Key functions:**
- `initializeSigners(ctx, abi.encode(address[] signers))` - Set required signers
- `run(ctx, payload)` - Submit cryptographic signature
- `getStatusPort(ctx, "")` - Query (initialized, signedCount, requiredCount, completed)
- `getRequiredSignersPort(ctx, "")` - Get list of required signers
- `hasSignedPort(ctx, abi.encode(address))` - Check if address has signed
- `isCompletePort(ctx, "")` - Check completion status

### Testing Microkernel

```bash
cd packages/microkernel
forge test                    # All tests
forge test --match-test Sign  # Signature tests only
forge test -vvvv             # Verbose traces
```

## Directory Reference

```
papre/
├── packages/
│   ├── microkernel/             # v2 architecture (proxy-based)
│   │   ├── src/
│   │   │   ├── core/            # AgreementCoreV1, AgreementFactory, PapreContext
│   │   │   ├── registry/        # ClauseRegistry
│   │   │   ├── clauses/         # Clause implementations (attestation, etc.)
│   │   │   └── interfaces/      # IAgreementCore, IClauseRegistry
│   │   ├── test/
│   │   │   ├── clauses/         # Unit tests per clause
│   │   │   ├── integration/     # Full flow tests
│   │   │   └── security/        # Attack vector tests
│   │   └── script/              # Deployment scripts
│   ├── primitives/              # v1 foundational building blocks
│   │   ├── src/
│   │   │   ├── base/            # PapreAgreement base contract
│   │   │   ├── clauses/         # Clause implementations by family
│   │   │   │   ├── access/      # PartyRegistryClause, LitAccessClause
│   │   │   │   ├── attestation/ # SignatureClause (v1)
│   │   │   │   ├── content/     # DeclarativeClause
│   │   │   │   ├── financial/   # EscrowClause
│   │   │   │   ├── governance/  # ArbitrationClause
│   │   │   │   ├── orchestration/ # SequentialExecutionClause
│   │   │   │   └── state/       # TimeLockClause
│   │   │   ├── interfaces/      # All interface definitions
│   │   │   └── libraries/       # Multiplexer, utilities
│   │   └── test/
│   └── agreements/              # All agreement implementations
│       ├── signing/             # SigningAgreement, DependentSigningAgreement
│       │   ├── src/
│       │   ├── test/
│       │   └── script/
│       └── milestone/           # MilestoneAgreement
│           ├── src/
│           ├── test/
│           └── script/
├── .env                         # Environment variables (root level)
├── docs/                        # Auto-generated from vault
├── scripts/
│   └── export-docs.sh           # Vault → docs sync
└── (papre-vault in iCloud)      # ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/papre-vault/
```

## Design Reminders

When implementing new Clauses:
1. Does it do exactly one thing?
2. Can it compose with other Clauses without modification?
3. Is state minimized or externalized?
4. Are the port interfaces standardized?
5. Would this make sense as a reusable primitive for others?

### Agreement Evolution Philosophy

**Create new Agreements rather than modifying existing ones.**

When making significant changes to an Agreement:
- Create a **new Agreement contract** (e.g., `MilestoneAgreementV2`, `EscrowMilestoneAgreement`)
- Keep the original Agreement intact and deployable
- Each Agreement variant becomes part of our **reusable library**

Why? Agreements are meant to be reused. Different use cases call for different configurations:
- `MilestoneAgreement` — Basic milestone payments
- `ArbitratedMilestoneAgreement` — With dispute resolution built-in
- `TimeboundMilestoneAgreement` — With deadline enforcement
- `EscrowedSigningAgreement` — Signing with payment on completion

The goal: **50 audited Clauses powering 100 production Agreements**. Each materially different Agreement adds to the library. Don't collapse variations—celebrate them.

---

## Multi-Agent Workflow

This repo uses a coordinated multi-tool AI development workflow with Linear as the source of truth.

### Branch Naming

```
{tool}-{LINEAR-ID}-{description}
```

Examples:
- `claude-PAP-80-escrow-clause-fix`
- `codex-PAP-81-test-coverage`

### Before Ending Session

1. Update `AI_HANDOFF.md` with current state
2. Push all changes
3. Update Linear issue status
4. Add `needs:review` label if complex task

### Linear Labels

- Add `agent:claude-code` or `agent:codex` when starting work
- Add `needs:review` when ready for reviewer agent
- Add `complexity:simple` or `complexity:complex` during triage

### Handoff File

See `AI_HANDOFF.md` in repo root for session context tracking between agents.
