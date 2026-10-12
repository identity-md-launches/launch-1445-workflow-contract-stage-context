# SKYLINE HEIST contracts

Contract stage of the SKYLINE HEIST launch: the Skyline Loot (LOOT) launch token and the
`Game` reward vault that pays verified arcade play, following the pepe2pepe
`ARCADE_REWARDS.md` (pepe-arcade/1) route the approved workflow names.

This repository is the Foundry project the launch builds from. The game website, the hosted
play service, the signer worker and the publication callback are later stages and are not here.

## Contents

| Path | What it is |
| --- | --- |
| `src/LaunchToken.sol` | `LaunchToken`: fixed-supply ERC-20 "Skyline Loot" / "LOOT", 18 decimals, 1,000,000,000 tokens minted once to its deployer. |
| `src/ArcadeRewardVault.sol` | The template's reward vault, copied verbatim except for the compiler pragma (see "Deviations"). |
| `src/Game.sol` | `Game`: the application contract. Inherits `ArcadeRewardVault` and folds in the launch policy (1 LOOT per point, 100 points max, closes 365 days after deployment). |
| `script/Deploy.s.sol` | Local dry-run deployment in manifest order. Configuration is in constants; it reads no environment. The real launch is done by the IMD ProjectFactory. |
| `test/` | Foundry tests (40 tests, success and failure paths, fuzzing). |
| `docs/abi/LaunchToken.json`, `docs/abi/Game.json` | ABI exports (`forge inspect <Contract> abi --json`). |
| `lib/` | Vendored dependencies as ordinary files: forge-std 1.17.0 and OpenZeppelin Contracts 5.2.0. No git submodules. |

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on (200 runs),
`bytecode_hash = "none"`, `ffi = false`, no filesystem permissions. Tests read no environment
variables and pass in any order and in parallel.

## Launch manifest values

These are for the manifest step, which writes `launch.json` after this work is accepted. They
come from the approved workflow context and the launch section of the assignment.

| Item | Value |
| --- | --- |
| Chain | Ethereum, chain id 1 |
| Launch token | `LaunchToken` (`src/LaunchToken.sol`), no constructor arguments |
| Application contracts, in order | `Game` |
| `Game` constructor | `(address creator, address launchToken, address verifier, bytes32 rules)` |
| `creator` | `$owner`: the launch owner. The assignment's launch section declares it as `0x0a5b0e232d47541eb503bc862a9db2672b8fba24`; the approved context labels that same address `platform` and names no separate creator wallet. See "Owner identity" below. |
| `launchToken` | `$token` (the deployed `LaunchToken`) |
| `verifier` | `0x345b9e44dc9ea841ea589fb7e0907139fa687a20` (the unfunded signer from the approved context) |
| `rules` | `0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8` (`rulesHash` of the approved `sdk/arcade-engine.mjs`) |
| pool.pairedCurrency | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD) |
| pool.fee | `12500` |
| pool.tickSpacing | `60` |
| pool.initialPrice | `"79228162514264337593543950336"` |

`Game` takes four constructor arguments, all of supported types, and its constructor makes no
external calls and needs no address to have code. Neither constructor is payable.

Runtime sizes: `LaunchToken` 1,754 bytes, `Game` 3,916 bytes (EIP-170 limit 24,576).

## What the contracts do

### LaunchToken

Plain OpenZeppelin ERC-20. The constructor mints the entire supply to `msg.sender`, which at
launch is the ProjectFactory. The factory splits it per policy (80% pool, 10% swarm via the
MerkleDistributor, 10% to the allocation receiver `0x67b31cfc35b477b8bcdf3458b713fac759a8b1b6`).
Nothing in this repository is allocated, reserved or sent any tokens at launch.

There is no owner, mint, burn-by-admin, pause, blocklist, transfer fee or upgrade path. The
brief asks for nothing the token refuses to do; "$LOOT earned from verified play" is paid by the
vault from tokens the creator deposits, not minted.

### Game (ArcadeRewardVault)

A funded, capped, player-claimed reward vault with an EIP-712 voucher signer.

- **Immutable policy**: `owner` (`$owner`, the vault administrator), `token` (LOOT), `signer`, `rulesHash`,
  `rewardPerPoint = 1e18`, `maxReward = 100e18`, `closesAt = deployment time + 365 days`.
- **`claimReward(session, player, releaseHash, rulesHash, amount, deadline, signature)`**:
  pays `amount` LOOT to `msg.sender`, who must equal `player`. Requires a non-zero session and
  release hash, the vault's rules hash, `0 < amount <= maxReward`, `deadline <= closesAt`,
  `block.timestamp <= deadline`, an unclaimed session, and a signature by `signer` over the
  EIP-712 struct `Reward(session, player, releaseHash, rulesHash, amount, deadline)` under domain
  `PepeArcadeRewards` / `1` / chain id / vault address. Marks the session claimed, transfers with
  `SafeERC20`, emits `RewardClaimed`. Guarded by `nonReentrant`.
- **`recoverExpired()`**: owner only, only when `block.timestamp > closesAt`. Sends the vault's
  whole LOOT balance to the owner. Since no voucher may carry a deadline later than `closesAt`,
  recovery can never take a token a live claim could still use.
- **Nothing else changes state.** No mint, pause, signer change, ownership transfer, early
  withdrawal, upgrade or ETH receipt. Any other selector reverts.

Exposed ABI (as the route requires): `owner`, `token`, `signer`, `rulesHash`, `rewardPerPoint`,
`maxReward`, `closesAt`, `claimed(bytes32)`, `claimReward(...)`, `recoverExpired`, plus
`REWARD_TYPEHASH`, `eip712Domain`, and the `Game` constants `REWARD_PER_POINT` and
`CLOSING_DELAY`. See `docs/abi/Game.json`.

## Deviations from the template, and why

1. **Compiler pragma.** The template's `ArcadeRewardVault.sol` declares `pragma solidity ^0.8.37`.
   This launch must build with the pinned `solc = "0.8.26"` (the offline verifier carries
   0.8.20 to 0.8.30), so the pragma line reads `pragma solidity 0.8.26;`. That is the only
   change; `diff` against upstream shows one line. The file is excluded from `forge fmt` so it
   stays byte-comparable with upstream. Upstream: `adaki2004/pepe2pepe-game-template` at commit
   `024e1134e97d3d2fc86adbd74043a16660e1d7c3`, file sha256
   `679c56245a271394bcf0e16f643a185783b08c0c07cf8de1fdaf4747e9d80139`. Nothing in the contract
   uses a feature newer than 0.8.26.
2. **`closesAt` is derived, not passed.** The template's `Game` sketch forwards a `closingTime`
   argument. The vault's constructor rejects any `closingTime` outside 14..366 days of
   `block.timestamp`, and the launch checks execute the constructor on an empty chain whose
   clock is not the launch clock (the protected floor runs at Foundry's default timestamp). A
   fixed timestamp argument would revert there and park the launch. `Game` therefore computes
   `closesAt = block.timestamp + 365 days` inside its constructor, which is exactly "approximately
   365 days after deployment" and is valid at any clock. The exact closing timestamp is read from
   `closesAt()` after deployment and must be disclosed to players as the claim expiry bound.
3. **OpenZeppelin version.** The template does not pin one; this project vendors 5.2.0, whose
   `SafeERC20`, `EIP712`, `ECDSA` and `ReentrancyGuard` match the vault's imports.

Everything else (no upgrades, proxy, extra withdrawal path, additional claims, minting,
replacement token, paid entry or player stakes) is as the route requires.

## Trust assumptions and operational responsibilities

- **Owner identity.** `owner` is the vault's only privileged role: the sole `recoverExpired()`
  caller and its sole beneficiary. It is immutable, and the template gives it no transfer path.
  The route (`ARCADE_REWARDS.md`) requires this role to be the game's creator, not the factory,
  the sponsor or the platform. The launch fills it with `$owner`, and the assignment's launch
  section resolves `$owner` to `0x0a5b0e232d47541eb503bc862a9db2672b8fba24`. The approved
  context lists that address only as `platform` and gives no creator wallet, so this repository
  cannot confirm that the two are the same party, and it does not invent a creator address.
  Whoever controls `$owner` at deployment is the party that must fund the vault and the only
  party that can recover unused LOOT after `closesAt`. **Admission condition for the manifest and
  review steps:** if the creator's wallet is not `0x0a5b…ba24`, the launch request must name the
  creator's wallet as owner before `launch.json` is written; deploying with another owner cannot
  be corrected afterwards. The local `script/Deploy.s.sol` constant `OWNER` mirrors the declared
  launch value and is a dry-run setting, not the source of the deployed owner.
- **The signer is a trusted-results service, not trustless validation.** The vault caps each
  claim at 100 LOOT and rejects duplicates, replays across vaults and chains, and expired
  vouchers, but it cannot tell an honest voucher from a dishonest one. A compromised signer key
  can drain whatever the vault holds, one capped claim per session. Keep the vault's balance
  bounded to what the owner is willing to lose; top it up rather than pre-funding a year.
- **The signer has no other power.** It cannot recover, pause, mint or change anything. It is an
  unfunded EOA that signs vouchers and never sends transactions.
- **The owner funds the vault** by transferring LOOT to the `Game` address. There is no
  deposit function; a plain `transfer` is the funding path, and any address can send tokens in,
  but only `owner` can ever take unused tokens out. The launch sends the requester's 10% to the
  allocation receiver `0x67b31cfc35b477b8bcdf3458b713fac759a8b1b6`, which is not the owner
  address: LOOT deposited from there, or from anyone else, is recoverable only by `owner` after
  `closesAt`. Fund the vault only from a party that accepts that. Unfunded or underfunded vaults make
  claims revert (`ERC20InsufficientBalance`); the session stays unclaimed and the voucher can be
  retried once funded, until its deadline. The host must not show a reward as available when the
  pool is empty.
- **The owner can recover only after `closesAt`**, and then recovers everything, including any
  tokens deposited later. The owner cannot withdraw earlier, change the signer, or alter
  terms. After `closesAt` the vault is finished; a new season needs a new vault.
- **Vouchers expire.** The service chooses each voucher's deadline (at most `closesAt`). Players
  must be shown the deadline before confirming, and the host's "My reward" control must support
  recovery of an unclaimed voucher after a refresh.
- **Players pay gas** for `claimReward`. Entry is free. No player funds ever enter the vault.
- **Not prevented, by design**: bots, offline optimisation, multiple wallets, automated legal
  play. Do not advertise cheat-proof or human-only rewards. The economy is bounded by the cap per
  run, the host's admission limits (one active run, 20 runs per hour per wallet) and the vault
  balance.
- **Pool and fees** belong to the factory and the launch policy. The pool opens with IMD at the
  network trading fee of 1.25%, read from the chain's LaunchFees contract. No fee logic exists in
  these contracts.

## After launch

Owner-settable values: none. Every value the vault needs is a constructor argument the brief
gives, so nothing is left unset. What the owner and services must do:

0. **Confirm the owner before the manifest is written.** `Game.owner()` must be the creator's
   wallet (see "Owner identity"). If the creator is not `0x0a5b…ba24`, the request must name the
   creator as owner first; there is no way to change the owner after deployment.
1. **Fund the vault.** Transfer LOOT to the deployed `Game` address. The requester's share of the
   supply arrives at the allocation receiver `0x67b3…b1b6`; tokens sent from there become
   recoverable only by `Game.owner()` after `closesAt`. Check `token.balanceOf(Game)`.
2. **Disclose `closesAt()`.** Read it from the deployed vault and publish it as the final claim
   expiry.
3. **Point the signer worker at the deployed vault**: it must sign with the EIP-712 domain
   (`PepeArcadeRewards`, `1`, chain id 1, the `Game` address) and the `rulesHash` above.
4. **Publication callback** (`dist/pepe-game.json` `onchain.rewards`): `protocol`
   `pepe-arcade/1`, `rulesId` `pepe-arcade-run/1`, the `rulesHash` and `signer` above,
   `rewardPerPoint` `"1000000000000000000"`, `hostedOnly` `true`. Later stage.
5. **Recovery.** After `closesAt`, `recoverExpired()` may be called only from the `Game.owner()`
   wallet, and the whole balance goes to that wallet.

## Tests

`test/LaunchToken.t.sol` (8): policy supply minted to the deployer, metadata, exact transfers,
supply conservation (fuzz), insufficient balance and allowance reverts, no admin surface
(mint, pause, upgrade and similar selectors all revert for anyone including the deployer),
runtime free of DELEGATECALL, CALLCODE and SELFDESTRUCT.

`test/Game.t.sol` (30): constructor policy and EIP-712 domain, zero-argument reverts,
constructor on an empty chain at timestamps 1 and far future, ETH rejected; successful claim
with event and balances, cap accepted and cap+1 refused, deadline equal to close accepted, fuzz
over amount, deadline and session; reverts for wrong caller, player substitution, wrong rules
hash, zero fields, deadline after close, expired deadline (and exactly-at-deadline accepted),
duplicate session with same and fresh signatures, wrong signer, tampered amount or deadline,
malformed signature, cross-vault replay, cross-chain replay, underfunded vault then retry once
funded, reentrant token cannot claim twice; recovery refused before and at close, refused for
signer, player and factory, full recovery after close, idempotent, no voucher claimable once
recovery opens, late deposits recoverable; signer has no other power, no other state-changing
entry points, runtime bounded and free of escape opcodes.

`test/Deploy.t.sol` (2): the script's `deploy(config)` wires the launch configuration and a
custom one.

The protected floor tests (`Token.protected.t.sol`, `Project.protected.t.sol`) were replayed
locally against a simulated factory CREATE2 deployment of both contracts at Foundry's default
timestamp; all nine passed. That replay is scaffolding and is not part of this tree.

Security checklist items from the eth-security reference were applied: reentrancy guard on both
state-changing functions, `SafeERC20`, EIP-712 with chain id and verifying contract in the
domain, strict access control on recovery, input validation on every claim field, no proxies or
delegatecall, no timestamp-derived randomness (there is none). Slither and Mythril were not run;
Foundry's fuzzer ran at 256 runs per fuzz test. Tests are not an audit: the independent review
step covers this work before release.

## Not in this stage

The HTML5 game, cover art, host SDK integration, the hosted verification service, IPFS and
GitHub publication, and `launch.json` are produced by later assignments and services.
