// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Game} from "../src/Game.sol";
import {ArcadeRewardVault} from "../src/ArcadeRewardVault.sol";

/// @dev Drives the vault with random, bounded sequences: funding, honest claims, replays, forged
/// vouchers, recovery attempts by the owner and by strangers, and time moving forward. It keeps a
/// ghost ledger of what the vault should hold and who should have been paid; the invariants below
/// compare the ledger with the chain after every call.
///
/// Every handler function uses try/catch and asserts that the call succeeded exactly when the
/// vault's rules say it should, so an unexpected success or an unexpected revert fails the run.
contract GameHandler is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant REWARD_TYPEHASH = keccak256(
        "Reward(bytes32 session,address player,bytes32 releaseHash,bytes32 rulesHash,uint256 amount,uint64 deadline)"
    );
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant STRANGER_KEY = 0xB0B;
    uint256 internal constant PLAYER_COUNT = 4;

    LaunchToken public immutable token;
    Game public immutable game;
    address public immutable owner;
    bytes32 public immutable rulesHash;
    uint64 public immutable closesAt;
    uint256 public immutable maxReward;

    address[] public players;

    struct Voucher {
        bytes32 session;
        address player;
        bytes32 releaseHash;
        uint256 amount;
        uint64 deadline;
        bytes signature;
    }

    /// @dev Vouchers that were paid, kept so they can be replayed.
    Voucher[] public paid;

    // ---------------------------------------------------------------- ghosts
    uint256 public ghostFunded;
    uint256 public ghostClaimed;
    uint256 public ghostRecovered;
    uint256 public ghostSessionsPaid;
    uint256 public ghostHonestAttempts;
    uint256 public ghostForgedAttempts;
    uint256 public ghostReplayAttempts;
    uint256 public ghostRecoveryAttempts;
    mapping(address => uint256) public ghostPaidTo;
    mapping(bytes32 => uint256) public ghostPaidForSession;
    bool public ghostForgedVoucherPaid;
    bool public ghostReplayPaid;
    bool public ghostClaimPaidAfterClose;
    bool public ghostRecoveredBeforeOrAtClose;
    bool public ghostRecoveredByNonOwner;
    bool public ghostSessionPaidTwice;

    uint256 internal sessionNonce;

    constructor(LaunchToken token_, Game game_, address owner_) {
        token = token_;
        game = game_;
        owner = owner_;
        rulesHash = game_.rulesHash();
        closesAt = game_.closesAt();
        maxReward = game_.maxReward();
        for (uint256 i; i < PLAYER_COUNT; ++i) {
            players.push(makeAddr(string.concat("player-", vm.toString(i))));
        }
    }

    function playerCount() external pure returns (uint256) {
        return PLAYER_COUNT;
    }

    function paidCount() external view returns (uint256) {
        return paid.length;
    }

    // --------------------------------------------------------------- actions

    /// @notice The creator (here the handler, which holds the supply) tops the vault up.
    function fund(uint256 amount) external {
        amount = bound(amount, 0, 500 ether);
        if (amount > token.balanceOf(address(this))) return;
        token.transfer(address(game), amount);
        ghostFunded += amount;
    }

    /// @notice Time only moves forward. Large enough steps that sequences reach `closesAt`.
    function warp(uint256 delta) external {
        delta = bound(delta, 0, 120 days);
        vm.warp(block.timestamp + delta);
    }

    /// @notice An honest voucher: fresh session, signed by the signer, submitted by its player.
    function claimHonest(uint256 playerSeed, uint256 amount, uint256 deadlineSeed, bytes32 release) external {
        ghostHonestAttempts++;
        address player = players[playerSeed % PLAYER_COUNT];
        amount = bound(amount, 1, maxReward);
        if (release == bytes32(0)) release = keccak256("release");
        uint64 deadline;
        bool deadlineReachable = block.timestamp <= closesAt;
        if (deadlineReachable) {
            deadline = uint64(bound(deadlineSeed, block.timestamp, closesAt));
        } else {
            // Nothing can be signed any more: the best possible deadline is already in the past.
            deadline = closesAt;
        }
        bytes32 session = _freshSession();
        bytes memory sig = _sign(SIGNER_KEY, session, player, release, rulesHash, amount, deadline);

        bool expectSuccess = deadlineReachable && token.balanceOf(address(game)) >= amount;
        uint256 before = token.balanceOf(player);

        vm.prank(player);
        try game.claimReward(session, player, release, rulesHash, amount, deadline, sig) {
            assertTrue(expectSuccess, "honest claim succeeded when it should have reverted");
            assertEq(token.balanceOf(player) - before, amount, "player paid a different amount");
            if (block.timestamp > closesAt) ghostClaimPaidAfterClose = true;
            if (ghostPaidForSession[session] != 0) ghostSessionPaidTwice = true;
            ghostClaimed += amount;
            ghostPaidTo[player] += amount;
            ghostPaidForSession[session] = amount;
            ghostSessionsPaid++;
            paid.push(Voucher(session, player, release, amount, deadline, sig));
        } catch {
            assertFalse(expectSuccess, "honest claim reverted when it should have paid");
            assertEq(token.balanceOf(player), before, "a reverted claim moved tokens");
            assertFalse(game.claimed(session), "a reverted claim spent the session");
        }
    }

    /// @notice Re-submits a voucher that was already paid, by its own player. Must always revert.
    function replay(uint256 index) external {
        if (paid.length == 0) return;
        ghostReplayAttempts++;
        Voucher memory v = paid[index % paid.length];
        uint256 before = token.balanceOf(v.player);
        vm.prank(v.player);
        try game.claimReward(v.session, v.player, v.releaseHash, rulesHash, v.amount, v.deadline, v.signature) {
            ghostReplayPaid = true;
        } catch {}
        assertEq(token.balanceOf(v.player), before, "replay moved tokens");
    }

    /// @notice A voucher that breaks exactly one rule. Must always revert and never move tokens.
    function claimForged(uint256 kind, uint256 playerSeed, uint256 amount, bytes32 release) external {
        ghostForgedAttempts++;
        kind = bound(kind, 0, 8);
        Forged memory f;
        f.sender = players[playerSeed % PLAYER_COUNT];
        f.v.player = f.sender;
        f.v.amount = bound(amount, 1, maxReward);
        f.v.releaseHash = release == bytes32(0) ? keccak256("release") : release;
        f.v.deadline = closesAt;
        f.v.session = _freshSession();
        f.rules = rulesHash;
        uint256 key = SIGNER_KEY;

        if (kind == 0) {
            key = STRANGER_KEY; // not the signer
            _signInto(f, key);
        } else if (kind == 1) {
            f.v.amount = bound(amount, maxReward + 1, maxReward * 1000); // over the cap, properly signed
            _signInto(f, key);
        } else if (kind == 2) {
            f.v.deadline = closesAt + 1; // outlives the vault, properly signed
            _signInto(f, key);
        } else if (kind == 3) {
            f.sender = players[(playerSeed % PLAYER_COUNT + 1) % PLAYER_COUNT]; // somebody else submits it
            _signInto(f, key);
        } else if (kind == 4) {
            _signInto(f, key);
            f.rules = keccak256(abi.encode(f.rules)); // wrong rules hash passed
        } else if (kind == 5) {
            f.v.session = bytes32(0); // zero session
            _signInto(f, key);
        } else if (kind == 6) {
            _signInto(f, key);
            f.v.amount = 0; // zero amount
        } else if (kind == 7) {
            // Signed for `player` but the amount was bumped in flight.
            _signInto(f, key);
            f.v.amount = f.v.amount == maxReward ? f.v.amount - 1 : f.v.amount + 1;
        } else {
            // Expired: a deadline strictly before now (the chain clock starts well above zero).
            f.v.deadline = uint64(block.timestamp - 1);
            _signInto(f, key);
        }

        uint256 before = token.balanceOf(f.sender);
        uint256 vaultBefore = token.balanceOf(address(game));
        if (_submit(f)) ghostForgedVoucherPaid = true;
        assertEq(token.balanceOf(f.sender), before, "forged claim paid the sender");
        assertEq(token.balanceOf(address(game)), vaultBefore, "forged claim moved vault tokens");
        if (f.v.session != bytes32(0)) assertFalse(game.claimed(f.v.session), "forged claim spent a session");
    }

    struct Forged {
        address sender;
        bytes32 rules;
        Voucher v;
    }

    function _signInto(Forged memory f, uint256 key) internal view {
        f.v.signature = _sign(key, f.v.session, f.v.player, f.v.releaseHash, f.rules, f.v.amount, f.v.deadline);
    }

    function _submit(Forged memory f) internal returns (bool ok) {
        vm.prank(f.sender);
        try game.claimReward(
            f.v.session, f.v.player, f.v.releaseHash, f.rules, f.v.amount, f.v.deadline, f.v.signature
        ) {
            ok = true;
        } catch {}
    }

    /// @notice The owner, or anyone else, tries to recover. Succeeds only for the owner after close.
    function recover(uint256 callerSeed) external {
        ghostRecoveryAttempts++;
        address caller = callerSeed % 3 == 0 ? owner : players[callerSeed % PLAYER_COUNT];
        bool expectSuccess = caller == owner && block.timestamp > closesAt;
        uint256 held = token.balanceOf(address(game));
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(caller);
        try game.recoverExpired() {
            assertTrue(expectSuccess, "recovery succeeded when it should have reverted");
            if (caller != owner) ghostRecoveredByNonOwner = true;
            if (block.timestamp <= closesAt) ghostRecoveredBeforeOrAtClose = true;
            assertEq(token.balanceOf(owner) - ownerBefore, held, "recovery paid the owner a different amount");
            assertEq(token.balanceOf(address(game)), 0, "recovery left tokens behind");
            ghostRecovered += held;
        } catch {
            assertFalse(expectSuccess, "recovery reverted when it should have succeeded");
            assertEq(token.balanceOf(address(game)), held, "a reverted recovery moved tokens");
        }
    }

    // --------------------------------------------------------------- helpers

    function _freshSession() internal returns (bytes32) {
        return keccak256(abi.encode("skyline-session", ++sessionNonce));
    }

    function _sign(
        uint256 key,
        bytes32 session,
        address player,
        bytes32 release,
        bytes32 rules,
        uint256 amount,
        uint64 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(REWARD_TYPEHASH, session, player, release, rules, amount, deadline));
        return _signStruct(key, structHash);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PepeArcadeRewards")),
                keccak256(bytes("1")),
                block.chainid,
                address(game)
            )
        );
    }

    function _signStruct(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GameInvariantTest is StdInvariant, Test {
    bytes32 internal constant RULES_HASH = 0x6a126dc671dbed043943f72f26c072f71bc7095efd3d0affa4ca4cb56bfcace8;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant START = 1_800_000_000;

    LaunchToken internal token;
    Game internal game;
    GameHandler internal handler;
    address internal owner = makeAddr("creator");
    address internal signer = vm.addr(0xA11CE);

    // Snapshot of the immutable policy at deployment.
    address internal ownerAt;
    address internal tokenAt;
    address internal signerAt;
    bytes32 internal rulesAt;
    uint256 internal perPointAt;
    uint256 internal maxRewardAt;
    uint64 internal closesAt;

    function setUp() public {
        vm.chainId(1);
        vm.warp(START);
        token = new LaunchToken();
        game = new Game(owner, address(token), signer, RULES_HASH);
        handler = new GameHandler(token, game, owner);
        // The handler stands in for the creator: it holds the supply and funds the vault from it.
        token.transfer(address(handler), SUPPLY);

        ownerAt = game.owner();
        tokenAt = address(game.token());
        signerAt = game.signer();
        rulesAt = game.rulesHash();
        perPointAt = game.rewardPerPoint();
        maxRewardAt = game.maxReward();
        closesAt = game.closesAt();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = GameHandler.fund.selector;
        selectors[1] = GameHandler.warp.selector;
        selectors[2] = GameHandler.claimHonest.selector;
        selectors[3] = GameHandler.replay.selector;
        selectors[4] = GameHandler.claimForged.selector;
        selectors[5] = GameHandler.recover.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Conservation. What the vault holds is exactly what went in minus what it paid out and
    /// gave back; every token is at an address we account for; each player holds exactly the sum
    /// of the vouchers they claimed; the owner holds only what recovery returned; the supply never
    /// changes; the vault never holds ETH.
    function invariant_tokensAreConserved() public view {
        assertEq(
            token.balanceOf(address(game)),
            handler.ghostFunded() - handler.ghostClaimed() - handler.ghostRecovered(),
            "vault balance drifted from the ledger"
        );
        uint256 held = token.balanceOf(address(handler)) + token.balanceOf(address(game)) + token.balanceOf(owner);
        uint256 sum;
        for (uint256 i; i < handler.playerCount(); ++i) {
            address p = handler.players(i);
            assertEq(token.balanceOf(p), handler.ghostPaidTo(p), "player balance differs from claims");
            held += token.balanceOf(p);
            sum += token.balanceOf(p);
        }
        assertEq(sum, handler.ghostClaimed(), "sum of player balances differs from total claimed");
        assertEq(token.balanceOf(owner), handler.ghostRecovered(), "owner holds tokens not from recovery");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(held, SUPPLY, "tokens leaked to an unknown address");
        assertEq(address(game).balance, 0, "vault holds ETH");
        assertLe(handler.ghostClaimed(), handler.ghostFunded(), "paid more than was ever funded");
    }

    /// @dev Sessions. A paid session stays paid, was paid once, within the cap and non-zero; no
    /// replay and no forged voucher of any kind ever moved a token; payouts are bounded by the cap
    /// times the number of sessions paid.
    function invariant_sessionsArePaidOnceAndOnlyWhenHonest() public view {
        uint256 n = handler.paidCount();
        for (uint256 i; i < n; ++i) {
            (bytes32 session,,, uint256 amount,,) = handler.paid(i);
            assertTrue(game.claimed(session), "a paid session reopened");
            assertEq(handler.ghostPaidForSession(session), amount, "session amount changed");
            assertLe(amount, maxRewardAt, "a session was paid over the cap");
            assertGt(amount, 0, "a zero-amount session was paid");
        }
        assertLe(handler.ghostClaimed(), handler.ghostSessionsPaid() * maxRewardAt, "cap exceeded");
        assertLe(handler.ghostSessionsPaid(), handler.ghostHonestAttempts(), "more paid than attempted");
        assertEq(handler.paidCount(), handler.ghostSessionsPaid(), "paid list and counter disagree");
        assertFalse(handler.ghostSessionPaidTwice(), "a session was paid twice");
        assertFalse(handler.ghostReplayPaid(), "a replayed voucher was paid");
        assertFalse(handler.ghostForgedVoucherPaid(), "a forged voucher was paid");
    }

    /// @dev Lifecycle and policy. Recovery only after close and only by the owner; no claim paid
    /// after close; a finished vault never reopens; the immutable policy never changes.
    function invariant_closeOrderingAndImmutablePolicy() public view {
        assertFalse(handler.ghostRecoveredBeforeOrAtClose(), "recovery before or at closesAt");
        assertFalse(handler.ghostRecoveredByNonOwner(), "recovery by a non-owner");
        assertFalse(handler.ghostClaimPaidAfterClose(), "claim paid after closesAt");
        if (block.timestamp <= closesAt) {
            assertEq(handler.ghostRecovered(), 0, "recovered while the vault is open");
        }
        assertEq(game.owner(), ownerAt);
        assertEq(address(game.token()), tokenAt);
        assertEq(game.signer(), signerAt);
        assertEq(game.rulesHash(), rulesAt);
        assertEq(game.rewardPerPoint(), perPointAt);
        assertEq(game.maxReward(), maxRewardAt);
        assertEq(game.closesAt(), closesAt);
        assertEq(game.maxReward(), 100 * game.rewardPerPoint());
    }
}
