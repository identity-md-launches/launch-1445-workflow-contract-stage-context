// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Game} from "../src/Game.sol";
import {ArcadeRewardVault} from "../src/ArcadeRewardVault.sol";

/// @dev A minimal smart-contract wallet that forwards a claim. Players may be contracts; the
/// vault only requires `msg.sender == player`.
contract ContractWallet {
    function claim(Game game, bytes memory data) external returns (bool ok) {
        (ok,) = address(game).call(data);
    }
}

/// @dev Adversarial inputs the implementation did not pick: boundaries of the base vault's
/// constructor, malleated and random signatures, every single-field tampering, contract players
/// and session-id collisions. Numbers from the approved workflow context.
/// forge-config: default.fuzz.runs = 1000
contract GameAdversarialTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant REWARD_TYPEHASH = keccak256(
        "Reward(bytes32 session,address player,bytes32 releaseHash,bytes32 rulesHash,uint256 amount,uint64 deadline)"
    );
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    bytes32 internal constant RULES_HASH = 0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8;
    uint256 internal constant MAX_REWARD = 100 ether;
    uint64 internal constant CLOSING_DELAY = 365 days;
    uint256 internal constant START = 1_800_000_000;

    uint256 internal signerKey = 0xA11CE;
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

    function setUp() public {
        vm.chainId(1);
        vm.warp(START);
        vm.prank(factory);
        token = new LaunchToken();
        vm.prank(factory);
        game = new Game(owner, address(token), signer, RULES_HASH);
        closesAt = game.closesAt();
        vm.prank(factory);
        token.transfer(address(game), 10_000 ether);
    }

    // ----------------------------------------------------------------- helpers

    function _digest(
        address vault,
        bytes32 session_,
        address player_,
        bytes32 release_,
        bytes32 rules_,
        uint256 amount,
        uint64 deadline
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PepeArcadeRewards")),
                keccak256(bytes("1")),
                block.chainid,
                vault
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(REWARD_TYPEHASH, session_, player_, release_, rules_, amount, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signRaw(address player_, bytes32 session_, uint256 amount, uint64 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(signerKey, _digest(address(game), session_, player_, releaseHash, RULES_HASH, amount, deadline));
    }

    function _voucher(address player_, bytes32 session_, uint256 amount, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = _signRaw(player_, session_, amount, deadline);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------- base vault constructor

    /// @dev `Game` fixes `perPoint` and `closesAt`, so the base vault's own boundaries are only
    /// reachable by deploying it directly. They must be inclusive where the template says so.
    function test_baseVaultAcceptsThePerPointCapAndRefusesOneMore() public {
        uint64 closes = uint64(block.timestamp + 30 days);
        ArcadeRewardVault v = new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1_000 ether, closes);
        assertEq(v.rewardPerPoint(), 1_000 ether);
        assertEq(v.maxReward(), 100_000 ether);

        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1_000 ether + 1, closes);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 0, closes);
    }

    function test_baseVaultClosingWindowIsInclusiveAt14And366Days() public {
        uint64 now_ = uint64(block.timestamp);
        ArcadeRewardVault lo = new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1 ether, now_ + 14 days);
        assertEq(lo.closesAt(), now_ + 14 days);
        ArcadeRewardVault hi =
            new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1 ether, now_ + 366 days);
        assertEq(hi.closesAt(), now_ + 366 days);

        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1 ether, now_ + 14 days - 1);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1 ether, now_ + 366 days + 1);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        new ArcadeRewardVault(owner, address(token), signer, RULES_HASH, 1 ether, 0);
    }

    /// @dev The derived window must sit inside the base vault's accepted range at every clock
    /// the launch checks might use, and recovery opens strictly after it.
    function testFuzz_gameClosingWindowIsAlwaysValid(uint64 deployAt) public {
        deployAt = uint64(bound(deployAt, 1, type(uint64).max - 366 days));
        vm.warp(deployAt);
        Game g = new Game(owner, address(token), signer, RULES_HASH);
        assertEq(g.closesAt(), deployAt + CLOSING_DELAY);
        assertGe(g.closesAt(), deployAt + 14 days);
        assertLe(g.closesAt(), deployAt + 366 days);

        vm.warp(g.closesAt());
        vm.prank(owner);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        g.recoverExpired();
        vm.warp(uint256(g.closesAt()) + 1);
        vm.prank(owner);
        g.recoverExpired(); // nothing to move, but it is now permitted
    }

    // -------------------------------------------------------------- signatures

    /// @dev The same voucher with its `s` flipped to the high half of the curve is a second valid
    /// ECDSA signature for the same key. OpenZeppelin's ECDSA refuses it; the vault must too, or
    /// `claimed[session]` would not be the only replay protection a session has.
    function test_malleatedHighSSignatureIsRejected() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = _signRaw(player, session, 5 ether, deadline);
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory malleated = abi.encodePacked(r, sHigh, vFlip);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, malleated);
        assertFalse(game.claimed(session));

        // And after an honest claim, the malleated twin is still refused (session spent first).
        vm.prank(player);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, abi.encodePacked(r, s, v));
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, malleated);
        assertEq(token.balanceOf(player), 5 ether);
    }

    function test_signatureWithWrongVIsRejected() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        (, bytes32 r, bytes32 s) = _signRaw(player, session, 5 ether, deadline);
        vm.prank(player);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, abi.encodePacked(r, s, uint8(29)));
        vm.prank(player);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, abi.encodePacked(r, s, uint8(0)));
    }

    function test_emptyAnd64ByteSignaturesAreRejected() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, "");
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, new bytes(64));
    }

    /// @dev A random 65-byte blob never pays. Whatever `ecrecover` returns for it, it is not the
    /// signer, and the call reverts without spending the session.
    function testFuzz_randomSignatureNeverPays(bytes32 r, bytes32 s, uint8 v) public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(player);
        (bool ok,) = address(game)
            .call(
                abi.encodeCall(
                    ArcadeRewardVault.claimReward, (session, player, releaseHash, RULES_HASH, 5 ether, deadline, sig)
                )
            );
        assertFalse(ok, "random signature accepted");
        assertEq(token.balanceOf(player), 0);
        assertFalse(game.claimed(session));
    }

    /// @dev Sign a valid voucher, then change exactly one of its six fields (or the submitter) to
    /// a fuzzed value. Every such change must be refused and must leave the session unspent.
    function testFuzz_anySingleFieldTamperingIsRejected(uint8 field, bytes32 noise, uint64 noise64, uint256 noise256)
        public
    {
        field = uint8(bound(field, 0, 6));
        Claim memory c = Claim({
            sender: player,
            session: session,
            player: player,
            release: releaseHash,
            rules: RULES_HASH,
            amount: bound(noise256, 1, MAX_REWARD),
            deadline: uint64(bound(noise64, block.timestamp, closesAt))
        });
        bytes memory sig = _voucher(player, session, c.amount, c.deadline);
        // A value copy: memory struct assignment would alias `c` and follow its mutation.
        Claim memory honest = Claim(c.sender, c.session, c.player, c.release, c.rules, c.amount, c.deadline);

        if (field == 0) {
            c.session = noise == session ? keccak256(abi.encode(noise)) : noise;
        } else if (field == 1) {
            // Submitted by, and for, a different address than the one signed.
            c.player = mallory;
            c.sender = mallory;
        } else if (field == 2) {
            c.release = noise == releaseHash ? keccak256(abi.encode(noise)) : noise;
        } else if (field == 3) {
            c.rules = noise == RULES_HASH ? keccak256(abi.encode(noise)) : noise;
        } else if (field == 4) {
            c.amount = c.amount == MAX_REWARD ? c.amount - 1 : c.amount + 1;
        } else if (field == 5) {
            c.deadline = c.deadline == closesAt ? c.deadline - 1 : c.deadline + 1;
        } else {
            // Right voucher, wrong submitter.
            c.sender = mallory;
        }

        assertFalse(_submit(c, sig), "tampered voucher accepted");
        assertEq(token.balanceOf(player), 0);
        assertEq(token.balanceOf(mallory), 0);
        assertFalse(game.claimed(session));
        assertEq(token.balanceOf(address(game)), 10_000 ether);

        // The untouched voucher still works afterwards: a failed attempt costs the player nothing.
        assertTrue(_submit(honest, sig), "honest voucher refused after a failed attempt");
        assertEq(token.balanceOf(player), honest.amount);
    }

    struct Claim {
        address sender;
        bytes32 session;
        address player;
        bytes32 release;
        bytes32 rules;
        uint256 amount;
        uint64 deadline;
    }

    function _submit(Claim memory c, bytes memory sig) internal returns (bool ok) {
        vm.prank(c.sender);
        (ok,) = address(game)
            .call(
                abi.encodeCall(
                    ArcadeRewardVault.claimReward, (c.session, c.player, c.release, c.rules, c.amount, c.deadline, sig)
                )
            );
    }

    /// @dev A voucher signed over a different chain id or vault address never clears, for any such pair.
    function testFuzz_voucherIsBoundToChainAndVault(uint64 otherChain, address otherVault) public {
        otherChain = uint64(bound(otherChain, 2, type(uint64).max));
        if (otherVault == address(game)) otherVault = address(uint160(address(game)) + 1);
        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.chainId(otherChain);
        bytes memory wrongChain = _voucher(player, session, 5 ether, deadline);
        vm.chainId(1);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, _digest(otherVault, session, player, releaseHash, RULES_HASH, 5 ether, deadline));
        bytes memory wrongVault = abi.encodePacked(r, s, v);

        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, wrongChain);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, deadline, wrongVault);
        assertFalse(game.claimed(session));
    }

    // ---------------------------------------------------------- deadline edges

    function test_zeroAndMaxDeadlinesAreRejected() public {
        bytes memory zero = _voucher(player, session, 5 ether, 0);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, 0, zero);

        bytes memory max = _voucher(player, session, 5 ether, type(uint64).max);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, type(uint64).max, max);
        assertFalse(game.claimed(session));
    }

    /// @dev For any deadline, the voucher is valid up to and including it and invalid one second
    /// later, independently of how far the deadline lies before `closesAt`.
    function testFuzz_deadlineIsInclusiveThenExpires(uint64 deadline, uint64 claimAt) public {
        deadline = uint64(bound(deadline, block.timestamp, closesAt));
        bytes memory sig = _voucher(player, session, 1 ether, deadline);

        claimAt = uint64(bound(claimAt, block.timestamp, deadline));
        vm.warp(claimAt);
        vm.prank(player);
        game.claimReward(session, player, releaseHash, RULES_HASH, 1 ether, deadline, sig);
        assertEq(token.balanceOf(player), 1 ether);

        bytes32 other = keccak256("session-2");
        bytes memory late = _voucher(player, other, 1 ether, deadline);
        vm.warp(uint256(deadline) + 1);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(other, player, releaseHash, RULES_HASH, 1 ether, deadline, late);
        assertEq(token.balanceOf(player), 1 ether);
    }

    // ---------------------------------------------------------- amount edges

    function test_oneWeiRewardIsPayable() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(player);
        game.claimReward(session, player, releaseHash, RULES_HASH, 1, deadline, _voucher(player, session, 1, deadline));
        assertEq(token.balanceOf(player), 1);
    }

    /// @dev The vault does not enforce point granularity: any raw amount up to the cap is paid.
    /// Rounding to whole points is the signer's job, not the contract's.
    function testFuzz_amountIsNotRoundedToPoints(uint256 amount) public {
        amount = bound(amount, 1, MAX_REWARD);
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(player);
        game.claimReward(
            session, player, releaseHash, RULES_HASH, amount, deadline, _voucher(player, session, amount, deadline)
        );
        assertEq(token.balanceOf(player), amount);
    }

    /// @dev Above the cap is refused regardless of how far above, including values that would
    /// overflow a naive multiplication.
    function testFuzz_anyAmountAboveCapIsRejected(uint256 amount) public {
        amount = bound(amount, MAX_REWARD + 1, type(uint256).max);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(player, session, amount, deadline);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, amount, deadline, sig);
    }

    // ------------------------------------------------------ players and sessions

    function test_contractWalletCanClaimItsOwnVoucher() public {
        ContractWallet wallet = new ContractWallet();
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(address(wallet), session, 3 ether, deadline);
        bytes memory data = abi.encodeCall(
            ArcadeRewardVault.claimReward, (session, address(wallet), releaseHash, RULES_HASH, 3 ether, deadline, sig)
        );
        assertTrue(wallet.claim(game, data), "contract player refused");
        assertEq(token.balanceOf(address(wallet)), 3 ether);

        // An EOA holding a voucher issued to the wallet cannot redirect it.
        bytes32 other = keccak256("session-2");
        bytes memory sig2 = _voucher(address(wallet), other, 3 ether, deadline);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(other, address(wallet), releaseHash, RULES_HASH, 3 ether, deadline, sig2);
    }

    /// @dev `claimed` is keyed by session only. If the service ever issued the same session id to
    /// two players, the second honest voucher would be refused. That is the template's design
    /// (sessions are unique run ids), and the service must guarantee uniqueness.
    function test_sessionIdIsSpentGloballyNotPerPlayer() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(player);
        game.claimReward(
            session, player, releaseHash, RULES_HASH, 2 ether, deadline, _voucher(player, session, 2 ether, deadline)
        );
        bytes memory forMallory = _voucher(mallory, session, 2 ether, deadline);
        vm.prank(mallory);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, mallory, releaseHash, RULES_HASH, 2 ether, deadline, forMallory);
        assertEq(token.balanceOf(mallory), 0);
    }

    /// @dev Many players, many sessions: the vault pays each once and holds the exact remainder.
    function testFuzz_manyClaimsConserveTheVaultBalance(uint8 count, uint256 seed) public {
        count = uint8(bound(count, 1, 40));
        uint256 paidOut;
        for (uint256 i; i < count; ++i) {
            paidOut += _claimNth(seed, i);
        }
        assertEq(token.balanceOf(address(game)), 10_000 ether - paidOut);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function _claimNth(uint256 seed, uint256 i) internal returns (uint256 amount) {
        address p = makeAddr(string.concat("p", vm.toString(i)));
        bytes32 s = keccak256(abi.encode(seed, i));
        amount = bound(uint256(keccak256(abi.encode(seed, i, "amt"))), 1, MAX_REWARD);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _voucher(p, s, amount, deadline);
        vm.prank(p);
        game.claimReward(s, p, releaseHash, RULES_HASH, amount, deadline, sig);
        assertEq(token.balanceOf(p), amount);
    }

    // -------------------------------------------------------------- recovery

    /// @dev Recovery after close takes the whole balance even if an unclaimed voucher with
    /// deadline == closesAt exists: that voucher is already unredeemable, so nothing live is lost.
    function test_recoveryAfterCloseLeavesNoLiveClaimBehind() public {
        bytes memory sig = _voucher(player, session, 5 ether, closesAt);
        vm.warp(uint256(closesAt) + 1);
        vm.prank(player);
        vm.expectRevert(ArcadeRewardVault.InvalidReward.selector);
        game.claimReward(session, player, releaseHash, RULES_HASH, 5 ether, closesAt, sig);

        vm.prank(owner);
        game.recoverExpired();
        assertEq(token.balanceOf(owner), 10_000 ether);
        assertEq(token.balanceOf(address(game)), 0);
    }

    /// @dev Recovery is not payable and takes no arguments; extra calldata or value is refused.
    function test_recoveryRefusesValue() public {
        vm.warp(uint256(closesAt) + 1);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(game).call{value: 1}(abi.encodeCall(ArcadeRewardVault.recoverExpired, ()));
        assertFalse(ok, "recoverExpired accepted ETH");
        assertEq(token.balanceOf(address(game)), 10_000 ether);
    }
}
