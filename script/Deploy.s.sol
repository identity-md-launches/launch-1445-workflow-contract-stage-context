// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Game} from "../src/Game.sol";

/// @title Local dry-run deployment of the SKYLINE HEIST contracts.
/// @notice The real launch is performed by the IMD ProjectFactory from the launch manifest, not by
/// this script. It exists so reviewers can reproduce the deployment order and constructor wiring
/// on a local chain. It reads no environment variables: the configuration is in constants.
contract Deploy is Script {
    struct Config {
        address owner;
        address signer;
        bytes32 rulesHash;
    }

    /// @dev Dry-run values mirroring the launch: `OWNER` is what the assignment's launch section
    /// declares as the owner that `$owner` resolves to (the approved context labels the same address
    /// `platform`; it names no separate creator wallet). The deployed owner is set by the manifest's
    /// `$owner`, not by this constant. `SIGNER` and `RULES_HASH` are the approved context's values.
    address public constant OWNER = 0x0A5b0e232d47541eB503bC862a9DB2672b8fBa24;
    address public constant SIGNER = 0x345b9E44DC9Ea841ea589Fb7E0907139fa687a20;
    bytes32 public constant RULES_HASH = 0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8;

    function launchConfig() public pure returns (Config memory) {
        return Config({owner: OWNER, signer: SIGNER, rulesHash: RULES_HASH});
    }

    /// @notice Deploys the token then the vault, in manifest order. On a local chain the whole
    /// supply goes to the caller instead of the factory.
    function deploy(Config memory config) public returns (LaunchToken token, Game game) {
        token = new LaunchToken();
        game = new Game(config.owner, address(token), config.signer, config.rulesHash);
    }

    function run() external returns (LaunchToken token, Game game) {
        vm.startBroadcast();
        (token, game) = deploy(launchConfig());
        vm.stopBroadcast();
    }
}
