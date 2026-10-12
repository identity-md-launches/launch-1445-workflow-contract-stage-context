// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Skyline Loot (LOOT), the SKYLINE HEIST launch token.
/// @notice Plain fixed-supply ERC-20. The whole supply is minted once to the deployer (the launch
/// factory), which splits it according to the launch policy. There is no owner, no mint, no pause,
/// no blocklist, no transfer fee and no upgrade path.
contract LaunchToken is ERC20 {
    /// @notice 1,000,000,000 tokens at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Skyline Loot", "LOOT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
