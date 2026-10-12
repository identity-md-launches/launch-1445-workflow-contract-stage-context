// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArcadeRewardVault} from "./ArcadeRewardVault.sol";

/// @title SKYLINE HEIST reward vault (pepe-arcade/1).
/// @notice The application contract of the SKYLINE HEIST launch. It is the unmodified
/// `ArcadeRewardVault` from the pepe2pepe game template with the launch's fixed policy folded in:
/// one LOOT token (1e18 raw units) per verified point, at most 100 points per run, and a reward
/// window that closes 365 days after deployment.
/// @dev The constructor makes no external calls and does not require any address to have code, so
/// it executes on an empty chain. `closesAt` is derived from `block.timestamp` at deployment rather
/// than passed in, because the launch checks run this constructor on a chain whose clock is not the
/// launch clock; a fixed timestamp argument could fall outside the vault's 14..366 day window there.
/// Read the exact value from `closesAt()` after deployment.
contract Game is ArcadeRewardVault {
    /// @notice Raw token units paid per verified point. Fixed by the signed launch plan.
    uint256 public constant REWARD_PER_POINT = 1 ether;

    /// @notice Seconds between deployment and `closesAt`. Within the vault's accepted 14..366 days.
    uint64 public constant CLOSING_DELAY = 365 days;

    /// @param creator The creator who administers the vault (`$owner`). Only this address can
    /// recover unused tokens, and only after `closesAt`.
    /// @param launchToken The launch token paid as rewards (`$token`, the `LaunchToken`).
    /// @param verifier The unfunded signer that signs reward vouchers. It holds no other power.
    /// @param rules The keccak256 of the approved arcade engine (`rulesHash`).
    constructor(address creator, address launchToken, address verifier, bytes32 rules)
        ArcadeRewardVault(
            creator, launchToken, verifier, rules, REWARD_PER_POINT, uint64(block.timestamp) + CLOSING_DELAY
        )
    {}
}
