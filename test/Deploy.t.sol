// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Game} from "../src/Game.sol";

contract DeployTest is Test {
    function test_deployWiresTheLaunchConfiguration() public {
        vm.warp(1_800_000_000);
        Deploy script = new Deploy();
        Deploy.Config memory config = script.launchConfig();
        // The launch section's declared owner, which `$owner` resolves to; not a creator this tree chose.
        assertEq(config.owner, 0x0A5b0e232d47541eB503bC862a9DB2672b8fBa24, "declared launch owner");
        assertEq(config.signer, 0x345b9E44DC9Ea841ea589Fb7E0907139fa687a20);
        assertEq(config.rulesHash, 0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8);

        (LaunchToken token, Game game) = script.deploy(config);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(script)), token.totalSupply(), "deployer holds the supply locally");
        assertEq(game.owner(), config.owner);
        assertEq(address(game.token()), address(token));
        assertEq(game.signer(), config.signer);
        assertEq(game.rulesHash(), config.rulesHash);
        assertEq(game.rewardPerPoint(), 1 ether);
        assertEq(game.maxReward(), 100 ether);
        assertEq(game.closesAt(), 1_800_000_000 + 365 days);
        assertEq(token.balanceOf(address(game)), 0, "nothing is allocated to the vault at launch");
    }

    function test_deployWithCustomConfig() public {
        Deploy script = new Deploy();
        address customOwner = makeAddr("owner");
        address customSigner = makeAddr("signer");
        (, Game game) =
            script.deploy(Deploy.Config({owner: customOwner, signer: customSigner, rulesHash: keccak256("rules")}));
        assertEq(game.owner(), customOwner);
        assertEq(game.signer(), customSigner);
        assertEq(game.rulesHash(), keccak256("rules"));
    }
}
