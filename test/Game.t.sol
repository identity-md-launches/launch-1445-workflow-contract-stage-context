// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Game} from "../src/Game.sol";
import {ArcadeRewardVault} from "../src/ArcadeRewardVault.sol";

/// @dev A token whose transfer re-enters the vault. The launch token is plain and cannot do this;
/// the mock shows that the guard holds even if it could.
contract ReentrantToken is IERC20 {
    Game public vault;
    bytes public replay;
    bool public attempted;
    bool public reentered;
    bytes public reentryError;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;

    function arm(Game vault_, bytes calldata replay_) external {
        vault = vault_;
        replay = replay_;
    }

    function fund(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (address(vault) != address(0) && msg.sender == address(vault)) {
            // Attempt once, so a missing guard produces an observable nested success rather
            // than recursion that eventually reverts for an unrelated reason.
            Game target = vault;
            vault = Game(address(0));
            attempted = true;
            (reentered, reentryError) = address(target).call(replay);
        }
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

contract GameTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant REWARD_TYPEHASH = keccak256(
        "Reward(bytes32 session,address player,bytes32 releaseHash,bytes32 rulesHash,uint256 amount,uint64 deadline)"
    );

    /// @dev The launch's values, from the approved workflow context.
    bytes32 internal constant RULES_HASH = 0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8;
    uint256 internal constant PER_POINT = 1 ether;
    uint256 internal constant MAX_REWARD = 100 ether;
    uint64 internal constant CLOSING_DELAY = 365 days;
    uint256 internal constant START = 1_800_000_000;

    uint256 internal signerKey = 0xA11CE;
    uint256 internal strangerKey = 0xB0B;
    address internal signer = vm.addr(signerKey);
    address internal owner = makeAddr("creator");
    address internal factory = makeAddr("factory");
    address internal player = makeAddr("player");
    address internal mallory = makeAddr("mallory");

    LaunchToken internal token;
    Game internal game;
    uint64 internal closesAt;

    bytes32 internal session = keccak256("session-1");
    bytes32 internal releaseHash = keccak256("release-cid");

    event RewardClaimed(bytes32 indexed session, address indexed player, bytes32 indexed releaseHash, uint256 amount);

    function setUp() public {
        vm.chainId(1);
        vm.warp(START);
        vm.prank(factory);
        token = new LaunchToken();
        vm.prank(factory);
        game = new Game(owner, address(token), signer, RULES_HASH);
        closesAt = game.closesAt();

        // The creator funds the vault by transferring LOOT into it (they receive their share from
        // the factory's allocation receiver after launch; here the factory stands in).
        vm.prank(factory);
        token.transfer(address(game), 10_000 ether);
    }

    // ----------------------------------------------------------------- helpers

    function _domainSeparator(address vault, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes("PepeArcadeRewards")), keccak256(bytes("1")), chainId, vault
            )
        );
    }

    function _digest(
        address vault,
        uint256 chainId,
        bytes32 session_,
        address player_,
        bytes32 release_,
        bytes32 rules_,
        uint256 amount,
        uint64 deadline
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(REWARD_TYPEHASH, session_, player_, release_, rules_, amount, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(vault, chainId), structHash));
    }

    function _voucher(uint256 key, address vault, uint256 chainId, bytes32 session_, uint256 amount, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, _digest(vault, chainId, session_, player, releaseHash, RULES_HASH, amount, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _voucher(uint256 amount, uint64 deadline) internal view returns (bytes memory) {
        return _voucher(signerKey, address(game), 1, session, amount, deadline);
    }

    function _claim(bytes32 session_, uint256 amount, uint64 deadline, bytes memory sig) internal {
        vm.prank(player);
        game.claimReward(session_, player, releaseHash, RULES_HASH, amount, deadline, sig);
    }

    function _signedDigest(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------- constructor

    function test_constructorSetsTheLaunchPolicy() public view {
        assertEq(game.owner(), owner);
        assertEq(address(game.token()), address(token));
        assertEq(game.signer(), signer);
        assertEq(game.rulesHash(), RULES_HASH);
        assertEq(game.rewardPerPoint(), PER_POINT);
        assertEq(game.REWARD_PER_POINT(), PER_POINT);
        assertEq(game.maxReward(), MAX_REWARD);
        assertEq(game.CLOSING_DELAY(), CLOSING_DELAY);
        assertEq(game.closesAt(), uint64(START) + CLOSING_DELAY);
        assertEq(game.REWARD_TYPEHASH(), REWARD_TYPEHASH);
    }

    function test_eip712DomainBindsNameVersionChainAndVault() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            game.eip712Domain();
        assertEq(name, "PepeArcadeRewards");
        assertEq(version, "1");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(game));
    }

    function test_constructorRevertsOnZeroArguments() public {
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new Game(address(0), address(token), signer, RULES_HASH);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new Game(owner, address(0), signer, RULES_HASH);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new Game(owner, address(token), address(0), RULES_HASH);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new Game(owner, address(token), signer, bytes32(0));
    }

    /// @dev The launch checks run the constructor on an empty chain: no token code and an arbitrary
    /// clock. The constructor must not depend on either.
    function test_constructorRunsOnAnEmptyChainAtAnyTimestamp() public {
        address codelessToken = address(0x1234);
        assertEq(codelessToken.code.length, 0);
        vm.warp(1);
        Game early = new Game(owner, codelessToken, signer, RULES_HASH);
        assertEq(early.closesAt(), 1 + CLOSING_DELAY);
        vm.warp(type(uint48).max);
        Game late = new Game(owner, codelessToken, signer, RULES_HASH);
        assertEq(late.closesAt(), uint64(type(uint48).max) + CLOSING_DELAY);
    }

    function test_constructorIsNotPayableAndVaultRejectsEth() public {
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertFalse(ok, "vault must not accept ETH");
    }

    // ------------------------------------------------------------------- claims

    function test_claimPaysExactlyThePlayer() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(42 ether, deadline);

        vm.expectEmit(true, true, true, true, address(game));
        emit RewardClaimed(session, player, releaseHash, 42 ether);
        _claim(session, 42 ether, deadline, sig);

        assertEq(token.balanceOf(player), 42 ether);
        assertEq(token.balanceOf(address(game)), 10_000 ether - 42 ether);
        assertTrue(game.claimed(session));
    }

    function test_claimAcceptsTheMaximumAndRefusesOneMore() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        _claim(session, MAX_REWARD, deadline, _voucher(MAX_REWARD, deadline));
        assertEq(token.balanceOf(player), MAX_REWARD);

        bytes32 other = keccak256("session-2");
        bytes memory sig = _voucher(signerKey, address(game), 1, other, MAX_REWARD + 1, deadline);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(other, MAX_REWARD + 1, deadline, sig);
    }

    function test_claimAcceptsDeadlineEqualToClose() public {
        _claim(session, 1 ether, closesAt, _voucher(1 ether, closesAt));
        assertEq(token.balanceOf(player), 1 ether);
    }

    function testFuzz_claimAnyAmountWithinTheCap(uint256 amount, uint64 deadline, bytes32 session_) public {
        amount = bound(amount, 1, MAX_REWARD);
        deadline = uint64(bound(deadline, block.timestamp, closesAt));
        vm.assume(session_ != bytes32(0));
        bytes memory sig = _voucher(signerKey, address(game), 1, session_, amount, deadline);
        _claim(session_, amount, deadline, sig);
        assertEq(token.balanceOf(player), amount);
        assertTrue(game.claimed(session_));
    }

    function test_claimRevertsWhenCallerIsNotTheSignedPlayer() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline);
        vm.prank(mallory);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        // Nor can mallory claim it for themselves by changing the player field.
        vm.prank(mallory);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, mallory, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        assertEq(token.balanceOf(mallory), 0);
        assertFalse(game.claimed(session));
    }

    function test_claimRevertsOnWrongRulesHash() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, keccak256("other-rules"), 5 ether, deadline, sig);
    }

    function test_claimRevertsOnZeroFields() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(bytes32(0), player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, bytes32(0), RULES_HASH, 5 ether, deadline, sig);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 0, deadline, sig);
    }

    function test_claimRevertsWhenDeadlineIsAfterClose() public {
        uint64 deadline = closesAt + 1;
        bytes memory sig = _voucher(5 ether, deadline);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline, sig);
    }

    function test_claimRevertsAfterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _voucher(5 ether, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline, sig);
        // Exactly at the deadline is still valid.
        vm.warp(deadline);
        _claim(session, 5 ether, deadline, sig);
        assertEq(token.balanceOf(player), 5 ether);
    }

    function test_claimRevertsOnDuplicateSession() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline);
        _claim(session, 5 ether, deadline, sig);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline, sig);
        // A fresh signature for the same session does not help either.
        bytes memory again = _voucher(1 ether, deadline);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 1 ether, deadline, again);
        assertEq(token.balanceOf(player), 5 ether);
    }

    function test_claimRevertsOnWrongSigner() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(strangerKey, address(game), 1, session, 5 ether, deadline);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline, sig);
    }

    function test_claimRevertsOnTamperedAmountOrDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 6 ether, deadline, sig);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline + 1, sig);
        assertFalse(game.claimed(session));
    }

    function test_claimRevertsOnMalformedSignature() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, hex"010203");
    }

    function test_claimRevertsAcrossVaults() public {
        vm.prank(factory);
        Game otherVault = new Game(owner, address(token), signer, RULES_HASH);
        vm.prank(factory);
        token.transfer(address(otherVault), 1_000 ether);

        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline); // bound to `game`
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        otherVault.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
    }

    function test_claimRevertsAcrossChains() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(5 ether, deadline); // signed for chain id 1
        vm.chainId(10);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, deadline, sig);
        vm.chainId(1);
        _claim(session, 5 ether, deadline, sig);
        assertEq(token.balanceOf(player), 5 ether);
    }

    function test_claimRevertsWhenUnderfundedAndSucceedsOnceFunded() public {
        vm.prank(factory);
        Game empty = new Game(owner, address(token), signer, RULES_HASH);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(signerKey, address(empty), 1, session, 5 ether, deadline);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(empty), 0, 5 ether)
        );
        empty.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        assertFalse(empty.claimed(session), "a failed claim is not spent");

        vm.prank(factory);
        token.transfer(address(empty), 5 ether);
        vm.prank(player);
        empty.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        assertEq(token.balanceOf(player), 5 ether);
        assertEq(token.balanceOf(address(empty)), 0);
    }

    function test_reentrantTokenCannotClaimAnotherVoucher() public {
        ReentrantToken evil = new ReentrantToken();
        Game evilVault = new Game(owner, address(evil), signer, RULES_HASH);
        evil.fund(address(evilVault), 1_000 ether);

        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(signerKey, address(evilVault), 1, session, 5 ether, deadline);
        // A fresh session, signed for the token that actually makes the callback. Without
        // nonReentrant this would pass every caller, signature, funding and replay check.
        bytes32 nestedSession = keccak256("nested-session");
        bytes memory nestedSig = _signedDigest(
            _digest(address(evilVault), 1, nestedSession, address(evil), releaseHash, RULES_HASH, 3 ether, deadline)
        );
        bytes memory replay = abi.encodeCall(
            ArcadeRewardVault.claimReward,
            (nestedSession, address(evil), releaseHash, RULES_HASH, 3 ether, deadline, nestedSig)
        );
        evil.arm(evilVault, replay);

        vm.prank(player);
        evilVault.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig);
        assertTrue(evil.attempted(), "token never attempted the callback");
        assertFalse(evil.reentered(), "guard let the token re-enter");
        assertEq(evil.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(evil.balanceOf(player), 5 ether, "paid exactly once");
        assertEq(evil.balanceOf(address(evil)), 0, "nested claim moved tokens");
        assertEq(evil.balanceOf(address(evilVault)), 995 ether);
        assertTrue(evilVault.claimed(session));
        assertFalse(evilVault.claimed(nestedSession), "rejected callback consumed its session");

        // The same callback works outside the outer claim, proving its inputs were valid and
        // that the guard resets after the successful outer call.
        vm.prank(address(evil));
        evilVault.claimReward(nestedSession, address(evil), releaseHash, RULES_HASH, 3 ether, deadline, nestedSig);
        assertEq(evil.balanceOf(address(evil)), 3 ether);
        assertEq(evil.balanceOf(address(evilVault)), 992 ether);
        assertTrue(evilVault.claimed(nestedSession));
    }

    function test_reentrantOwnerCannotRecoverDuringRecovery() public {
        ReentrantToken evil = new ReentrantToken();
        // The token must also be the owner or the callback would fail access control even
        // without the guard. This mock probes the guard, not the plain launch token's behavior.
        Game evilVault = new Game(address(evil), address(evil), signer, RULES_HASH);
        evil.fund(address(evilVault), 1_000 ether);
        evil.arm(evilVault, abi.encodeCall(ArcadeRewardVault.recoverExpired, ()));
        vm.warp(uint256(evilVault.closesAt()) + 1);

        vm.prank(address(evil));
        evilVault.recoverExpired();
        assertTrue(evil.attempted(), "token never attempted the callback");
        assertFalse(evil.reentered(), "recovery guard let the owner re-enter");
        assertEq(evil.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(evil.balanceOf(address(evil)), 1_000 ether);
        assertEq(evil.balanceOf(address(evilVault)), 0);

        // Recovery stays usable after the callback is rejected, including for a later deposit.
        evil.fund(address(evilVault), 1);
        vm.prank(address(evil));
        evilVault.recoverExpired();
        assertEq(evil.balanceOf(address(evil)), 1_000 ether + 1);
        assertEq(evil.balanceOf(address(evilVault)), 0);
    }

    // ----------------------------------------------------------------- recovery

    function test_ownerCannotRecoverBeforeOrAtClose() public {
        vm.prank(owner);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.recoverExpired();
        vm.warp(closesAt);
        vm.prank(owner);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.recoverExpired();
        assertEq(token.balanceOf(owner), 0);
    }

    function test_onlyOwnerCanRecover() public {
        vm.warp(closesAt + 1);
        address[3] memory others = [signer, player, factory];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
            game.recoverExpired();
        }
        assertEq(token.balanceOf(address(game)), 10_000 ether);
    }

    function test_ownerRecoversEverythingAfterClose() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        _claim(session, 7 ether, deadline, _voucher(7 ether, deadline));

        vm.warp(closesAt + 1);
        vm.prank(owner);
        game.recoverExpired();
        assertEq(token.balanceOf(owner), 10_000 ether - 7 ether);
        assertEq(token.balanceOf(address(game)), 0);

        // Idempotent: a second recovery moves nothing and does not revert.
        vm.prank(owner);
        game.recoverExpired();
        assertEq(token.balanceOf(owner), 10_000 ether - 7 ether);
    }

    /// @dev No voucher outlives the vault: the latest deadline a voucher may carry is `closesAt`,
    /// and recovery opens only after it, so recovery can never take a token a live claim needs.
    function test_noVoucherIsClaimableOnceRecoveryOpens() public {
        bytes memory sig = _voucher(5 ether, closesAt);
        vm.warp(closesAt + 1);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        _claim(session, 5 ether, closesAt, sig);
    }

    /// @dev Tokens deposited after recovery are recoverable again; nothing is stranded.
    function test_lateDepositsRemainRecoverable() public {
        vm.warp(closesAt + 1);
        vm.prank(owner);
        game.recoverExpired();
        vm.prank(factory);
        token.transfer(address(game), 3 ether);
        vm.prank(owner);
        game.recoverExpired();
        assertEq(token.balanceOf(owner), 10_000 ether + 3 ether);
    }

    // ------------------------------------------------------------ trust surface

    function test_signerHasNoOtherPower() public {
        vm.warp(closesAt + 1);
        vm.prank(signer);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.recoverExpired();
    }

    function test_noOtherStateChangingEntryPoints() public {
        string[6] memory signatures = [
            "withdraw(uint256)",
            "setSigner(address)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "mint(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], owner, uint256(1));
            vm.prank(owner);
            (bool ok,) = address(game).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(address(game)), 10_000 ether);
    }

    function test_runtimeIsBoundedAndHasNoEscapeOpcodes() public view {
        bytes memory runtime = address(game).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
