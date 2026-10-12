// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Funded, capped, player-claimed rewards. The signer has no token/LP/admin rights.
/// @dev No minting, paid entry, owner withdrawal before expiry, upgrade or result transactions.
/// Creator funds this vault by transferring the plain launch token. Unused funds recover after closesAt.
contract ArcadeRewardVault is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable owner;
    IERC20 public immutable token;
    address public immutable signer;
    bytes32 public immutable rulesHash;
    uint256 public immutable rewardPerPoint;
    uint256 public immutable maxReward;
    uint64 public immutable closesAt;
    mapping(bytes32 => bool) public claimed;
    bytes32 public constant REWARD_TYPEHASH = keccak256("Reward(bytes32 session,address player,bytes32 releaseHash,bytes32 rulesHash,uint256 amount,uint64 deadline)");
    event RewardClaimed(bytes32 indexed session,address indexed player,bytes32 indexed releaseHash,uint256 amount);
    error InvalidReward();

    constructor(address owner_,address token_,address signer_,bytes32 rules_,uint256 perPoint_,uint64 closes_)
        EIP712("PepeArcadeRewards","1") {
        if(owner_==address(0)||token_==address(0)||signer_==address(0)||rules_==bytes32(0)||perPoint_==0||perPoint_>1_000 ether||closes_<block.timestamp+14 days||closes_>block.timestamp+366 days) revert InvalidReward();
        owner=owner_;token=IERC20(token_);signer=signer_;rulesHash=rules_;
        rewardPerPoint=perPoint_;maxReward=100*perPoint_;closesAt=closes_;
    }
    function claimReward(bytes32 session,address player,bytes32 releaseHash,bytes32 rules_,uint256 amount,uint64 deadline,bytes calldata signature) external nonReentrant {
        if(msg.sender!=player||session==bytes32(0)||releaseHash==bytes32(0)||rules_!=rulesHash||amount==0||amount>maxReward||deadline>closesAt||block.timestamp>deadline||claimed[session]) revert InvalidReward();
        bytes32 hash=_hashTypedDataV4(keccak256(abi.encode(REWARD_TYPEHASH,session,player,releaseHash,rules_,amount,deadline)));
        if(ECDSA.recover(hash,signature)!=signer) revert InvalidReward();
        claimed[session]=true;
        token.safeTransfer(player,amount);
        emit RewardClaimed(session,player,releaseHash,amount);
    }
    /// @notice All valid vouchers expire no later than closesAt. Recovery cannot steal a live claim.
    function recoverExpired() external nonReentrant {
        if(msg.sender!=owner||block.timestamp<=closesAt) revert InvalidReward();
        token.safeTransfer(owner,token.balanceOf(address(this)));
    }
}
