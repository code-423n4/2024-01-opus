# Opus audit details
- Total Prize Pool: $130,000 in USDC
  - HM awards: $69,712.50 in USDC
  - Analysis awards: $4,225 in USDC
  - QA awards: $2,112.50 in USDC
  - Bot Race awards: $6,337.50 in USDC
  - Gas awards: $2,112.50 in USDC
  - Judge awards: $9,000 in USDC
  - Lookout awards: $6,000 in USDC
  - Scout awards: $500 USDC
- Join [C4 Discord](https://discord.gg/code4rena) to register
- Submit findings [using the C4 form](https://code4rena.com/contests/2024-01-opus/submit)
- [Read our guidelines for more details](https://docs.code4rena.com/roles/wardens)
- Starts January 9, 2024 20:00 UTC
- Ends February 6, 2024 20:00 UTC

## Automated Findings / Publicly Known Issues

The 4naly3er report can be found [here](https://github.com/code-423n4/2024-01-opus/blob/main/4naly3er-report.md).

Automated findings output for the audit can be found [here](https://github.com/code-423n4/2024-01-opus/blob/main/bot-report.md) within 24 hours of audit opening.

_Note for C4 wardens: Anything included in this `Automated Findings / Publicly Known Issues` section is considered a publicly known issue and is ineligible for awards._

**Known issues and risks**
- The protocol relies on a trusted and honest admin with superuser privileges for all modules with access control at launch.
- There is currently no fallback oracle. This is planned once more oracles are live on Starknet.
- Interest is not accrued on redistributed debt until they have been attributed to a trove. This is intended as the alternative would be too computationally intensive.
- Interest that have not been accrued at the time of shutdown will result in a permanent loss of debt surplus i.e. income. This is intended as the alternative to charge interest on all troves would be too expensive.

# Overview

## About Opus

Opus is a cross margin autonomous credit protocol that lets you borrow against your portfolio of carefully curated, sometimes yield-bearing, collateral. With minimal human intervention, the interest rates, maximum loan-to-value ratios and liquidation thresholds are dynamically determined by each user's collateral profile.

## Links

- [**Technical Documentation**](https://demo-35.gitbook.io/untitled/)
- [**Website**](https://opus.money/)
- [**Twitter**](https://twitter.com/OpusMoney)
- [**Discord**](https://discord.com/invite/raJYHwrmQ8)


# Scope

| Contract | SLOC | Purpose | Libraries used |
| ----------- | ----------- | ----------- | ----------- |
|_Contracts (13)_|
| [src/core/abbot.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/abbot.cairo) | 144 | The Abbot module acts as the sole interface for users to open and manage troves. Further, the Abbot plays an important role in enforcing that trove IDs are issued in a sequential manner to users, starting from one. | [`wadray`](https://github.com/lindy-labs/wadray) |
| [src/core/absorber.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/absorber.cairo) | 617 | The Absorber is Opus' implementation of a stability pool that allows yin holders to provide their yin and participate in liquidations (i.e. absorptions) as a consolidated pool. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/allocator.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/allocator.cairo) | 78 | The Allocator module provides to the Equalizer a list of recipient addresses for minted debt surpluses and their respective percentage entitlements. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/caretaker.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/caretaker.cairo) | 193 | The Caretaker module is responsible for deprecating the entire protocol, and particularly the Shrine,  in a graceful manner by allowing yin holders to claim collateral backing their yin. Note that, in the future, other modules may have their own shutdown mechanisms that fall outside the purview of the Caretaker. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/controller.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/controller.cairo) | 188 | The Controller module autonomously adjusts the value of a global interest rate multiplier for troves based on the deviation of the spot market price from the peg price. Its goal is to minimize the peg error by adjusting the interest rate multiplier to influence the behaviour of trove owners. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/equalizer.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/equalizer.cairo) | 120 | The Equalizer balances the budget of the Shrine by allowing the budget to be reset to zero from time to time, either by minting debt surpluses or by paying down debt deficits. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/flash_mint.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/flash_mint.cairo) | 78 | The Flash Mint module is an implementation of EIP-3156 that lets user borrow and repay yin in the same transaction. | [`wadray`](https://github.com/lindy-labs/wadray) |
| [src/core/gate.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/gate.cairo) | 120 | The Gate module acts as an adapter and custodian for collateral tokens. When users deposit collateral into a trove, the underlying collateral token is sent to the Gate module. Each collateral token will have its own Gate module. | [`wadray`](https://github.com/lindy-labs/wadray) |
| [src/core/purger.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/purger.cairo) | 361 | The Purger module is the primary interface for the multi-layered liquidation system of Opus, allowing anyone to liquidate unhealthy troves and protect the solvency of the protocol. Users can either liquidate an unhealthy trove using their own yin or using the Absorber's yin deposited by providers. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/seer.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/seer.cairo) | 154 | The Seer module acts as a coordinator of individual oracle modules, reading the price of the underlying collateral tokens of yangs from the adapter modules of oracles and submitting them to the Shrine. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/sentinel.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/sentinel.cairo) | 173 | The Sentinel module acts as the internal interface for other modules to interact with Gates. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/core/shrine.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/shrine.cairo) | 1313 | The Shrine module is the core accounting module and performs various bookkeeping functions. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
| [src/external/pragma.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/external/pragma.cairo) | 129 | This module is an adapter to read prices from the Pragma oracle. | [`wadray`](https://github.com/lindy-labs/wadray) [`access_control`](https://github.com/lindy-labs/access_control) |
|_Types and roles (2)_|
| [src/types.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/types.cairo) | 196 | Custom types used in Opus. | [`wadray`](https://github.com/lindy-labs/wadray) |
| [src/core/roles.cairo](https://github.com/code-423n4/2024-01-opus/blob/src/core/roles.cairo) | 192 | This module sets out the access control roles for the admin and modules. | |

## Out of scope

- `src/core/transmuter.cairo`
- `src/core/transmuter_registry.cairo`
- `src/interfaces`
- `src/tests`
- `src/mock`
- `src/utils/`
- The implementation of `Display` trait in `src/types.cairo`

# Additional Context

Tokens expected to be used as collateral at launch are WBTC, ETH and wstETH.

**Access control**

Opus as a protocol hinges on the critical assumption that the admin for its smart contracts is honest. Other than the admin, access control should be granted to smart contracts of Opus only (as set out in `src/core/roles.cairo`), and not to any other users.

**Negative budget**

Note that it is not possible for the budget to be negative based on the contracts within the scope of the audit.


## Scoping Details

```
- If you have a public code repo, please share it here: Not yet public
- How many contracts are in scope?: 13
- Total SLoC for these contracts?: 4119
- How many external imports are there?: 0
- How many separate interfaces and struct definitions are there for the contracts within scope?: 32
- Does most of your code generally use composition or inheritance?: Composition
- How many external calls?: 2
- What is the overall line coverage percentage provided by your tests?: 90
- Is this an upgrade of an existing system?: False
- Check all that apply (e.g. timelock, NFT, AMM, ERC20, rollups, etc.): ERC-20 Token, Uses L2, Timelock function
- Is there a need to understand a separate part of the codebase / get context in order to audit this part of the protocol?: False
- Please describe required context:
- Does it use an oracle?: Others - Pragma
- Describe any novel or unique curve logic or mathematical models your code uses: PID controller
- Is this either a fork of or an alternate implementation of another project?: False
- Does it use a side-chain?:
- Describe any specific areas you would like addressed:
```

# Tests

1. Install [Scarb](https://docs.swmansion.com/scarb/download.html) v2.4.0 by running:
```
curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh | sh -s -- -v 2.4.0
```
2. Install [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry) v0.13.1 by running:
```
curl -L https://raw.githubusercontent.com/foundry-rs/starknet-foundry/master/scripts/install.sh | sh

snfoundryup -v 0.13.1
```
3. Run `scarb test`.
