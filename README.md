# Yolo (YOLO)

A fixed supply ERC-20 for Ethereum. The constructor mints **1,000,000,000 YOLO**
with **18 decimals** to its immediate deployer. All amounts in the contract's API
are in the smallest token units: one YOLO is `1000000000000000000` units.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `Yolo` |
| Source | `src/Yolo.sol` |
| Artifact | `out/Yolo.sol/Yolo.json` |
| Token name | `Yolo` |
| Symbol | `YOLO` |
| Decimals | `18` |
| Initial and permanent total supply | `1000000000000000000000000000` units (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Initial holder | `msg.sender` in the constructor |
| Intended launch chain | Ethereum, chain ID `1` |
| Compiler | Solidity `0.8.26` |
| Build settings | Cancun EVM, optimizer enabled with 200 runs, `bytecode_hash = "none"` |

Deploy the creation bytecode directly. A factory using CREATE or CREATE2 receives
the entire supply; the transaction origin and the caller of that factory receive
none from the constructor. There are no constructor calls to external contracts,
linked libraries, initialization calls, or subsequent configuration steps.

The launch service supplies the factory and handles distribution and liquidity
after deployment. The token needs no recipient, router, pool, owner, key, or oracle
address. The factory's allocation transfers use the ordinary ERC-20 interface.
No supply is reserved inside the token. This project adds no application contracts
and no launch manifest; the launch service produces that manifest separately.

## Behavior and assumptions

The requested custom behavior consists of the fixed metadata and constructor
supply. Other behavior follows the vendored OpenZeppelin ERC-20 implementation:

- `transfer`, `approve`, and `transferFrom` return `true` on success and revert on
  failure with ERC-6093 custom errors.
- Transfers deliver the exact amount. There are no transfer taxes, rebases,
  restrictions by holder or venue, or callbacks to recipients.
- Zero-value transfers between nonzero addresses are valid and emit `Transfer`.
  Sending to the zero address reverts, including when the amount is zero.
- `approve` replaces the allowance and emits `Approval`; approving zero revokes
  it. A zero spender is rejected. Approval does not require a token balance.
- Finite allowances decrease on `transferFrom`. An allowance of
  `type(uint256).max` is unlimited and does not decrease. Even a holder calling
  `transferFrom` on their own balance needs allowance for a positive amount.
- Allowance spending does not emit an additional `Approval` event in this
  implementation. Integrations should read `allowance` for its current value.
- There is no owner or other administrator, further minting, burning, pause,
  blacklist, confiscation, upgrade, or recovery function. Supply stays fixed.
- The contract has no payable entrypoints. Tokens sent to this contract itself,
  other ERC-20s sent here, and forcibly delivered ETH cannot be recovered.

## Build and test

Install Foundry and make Solidity `0.8.26` available to its compiler manager. The
project vendors all Solidity dependencies as ordinary source files under `lib/`;
no package installation, submodule, RPC, account, or network access is needed to
build and test once that compiler is available. FFI and filesystem cheatcode
permissions are not enabled. Tests do not read or change environment variables.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4e3cc249ff71113d9334ed5b6fe8885296d571a39d44bf0604795125543fb853 forge test
forge fmt --check
```

The seed is supplied to Foundry by the shell, rather than read by Solidity tests.
`foundry.toml` sets 512 cases per fuzz test and 128 invariant runs of depth 64.

`test/Yolo.t.sol` covers metadata, minting and its event, factory deployment,
exact distribution and claim transfers, approval isolation and revocation,
finite and unlimited allowances, self/zero/full-balance transfers, invalid
addresses, insufficient balance/allowance, rollback on failure, unauthorized
spending, absent privileged functions, rejected ETH, and deployment bytecode
constraints. Fuzz tests exercise transfers, approvals, and overspending.

`test/Yolo.invariant.t.sol` runs randomized transfers, approvals, revocations, and
delegated transfers across four holders. An independent balance and allowance
model checks successful calls and failures after each operation, together with
constant supply and conservation of all balances.

The allocation test exercises token transfer legs using test participants. It
does not simulate Uniswap or claim to test pool initialization or swaps. The
supplied protected launch tests belong to the launch service's separate harness;
their PoolManager, floor contracts, and launch-specific configuration are not
included here. The local test suite is self-contained.

## After launch

No token settings need to be set and no maintenance transaction is required.
The launch operator is responsible for deploying the reviewed bytecode through
the intended factory, verifying the deployed source, checking metadata and the
`10^27`-unit supply, and completing the launch's distribution and liquidity steps.
The factory receives tokens, not lasting administrative powers.

Holders control their balances and approvals. Wallets should use the verified
token address and display 18 decimals. Grant only the allowance needed, revoke
unused allowances, and set an existing allowance to zero before changing it to
another nonzero value to reduce the standard ERC-20 approval replacement race.
There is no operator capable of undoing transfers or restoring lost access.

## Dependencies and review

- OpenZeppelin Contracts **v5.0.2**, commit
  `dbb6104ce834628e473d2173bbc9d47f81a9eec3`: only ERC20 and its transitive source
  dependencies are vendored, with their MIT license.
- forge-std **v1.9.7**, commit
  `77041d2ce690e692d6e03cc812b57d1ddaa4d505`: test support sources and both upstream
  licenses are vendored.

See `dependencies.lock.json` for upstream URLs and SHA-256 digests of every
vendored file. These files are unmodified upstream sources. `remappings.txt`
resolves imports entirely within this repository.

The implementation was reviewed against the supplied security reference for
supply arithmetic, authorization, external calls, zero addresses, events,
deployment constraints, and privileged entrypoints. See `SECURITY_REVIEW.md`
for the review scope and test evidence. Local review and tests are not an
independent security audit; independent launch review remains the launch
service's responsibility.
