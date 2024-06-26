// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IRelay} from "./interfaces/IRelay.sol";
import {IRelayFactory} from "./interfaces/IRelayFactory.sol";

import {IOptimizer} from "./interfaces/IOptimizer.sol";

import {IVoter} from "@velodrome/contracts/interfaces/IVoter.sol";
import {IVotingEscrow} from "@velodrome/contracts/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "@velodrome/contracts/interfaces/IRewardsDistributor.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title Velodrome Relay v1
/// @author velodrome.finance, @pedrovalido, @airtoonricardo, @pegahcarter
/// @notice Velodrome base Relay contract to manage a (m)veNFT
/// @dev Inherit this contract to your custom Relay implementation
abstract contract Relay is IRelay, ERC721Holder, ReentrancyGuard, AccessControlEnumerable, Initializable {
    using SafeERC20 for IERC20;

    bytes32 public constant ALLOWED_CALLER = keccak256("ALLOWED_CALLER");

    uint256 public mTokenId;
    string public name;

    IVoter public immutable voter;
    IVotingEscrow public immutable ve;
    IERC20 public immutable velo;
    IRewardsDistributor public immutable distributor;
    IRelayFactory public relayFactory;

    IOptimizer public optimizer;
    uint256 public keeperLastRun;

    constructor(address _voter, address _admin, address _relayFactory, address _optimizer, string memory _name) {
        voter = IVoter(_voter);
        ve = IVotingEscrow(voter.ve());
        velo = IERC20(ve.token());
        relayFactory = IRelayFactory(_relayFactory);
        distributor = IRewardsDistributor(ve.distributor());
        optimizer = IOptimizer(_optimizer);

        name = _name;

        // Set initial default admin role
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @inheritdoc IRelay
    function initialize(uint256 _mTokenId) external initializer {
        if (ve.escrowType(_mTokenId) != IVotingEscrow.EscrowType.MANAGED) revert TokenIdNotManaged();
        if (ve.ownerOf(_mTokenId) != address(this)) revert ManagedTokenNotOwned();
        mTokenId = _mTokenId;
    }

    /// @dev Validate msg.sender is a keeper added by Velodrome team.
    ///      Can only call permissioned functions 1 day after epoch flip
    modifier onlyKeeper(address _sender) {
        if (!relayFactory.isKeeper(_sender)) revert NotKeeper();
        _;
    }

    // -------------------------------------------------
    // Basic functions
    // -------------------------------------------------

    /// @inheritdoc IRelay
    function claimBribes(address[] calldata _bribes, address[][] calldata _tokens) external {
        voter.claimBribes(_bribes, _tokens, mTokenId);
        _handleRebase();
    }

    /// @inheritdoc IRelay
    function claimFees(address[] calldata _fees, address[][] calldata _tokens) external {
        voter.claimFees(_fees, _tokens, mTokenId);
        _handleRebase();
    }

    /// @inheritdoc IRelay
    function multicall(bytes[] calldata _calls) external {
        for (uint256 i = 0; i < _calls.length; i++) {
            (bool s, ) = address(this).delegatecall(_calls[i]);
            if (!s) revert MulticallFailed();
        }
    }

    // -------------------------------------------------
    // ALLOWED_CALLER functions
    // -------------------------------------------------

    /// @inheritdoc IRelay
    function increaseAmount(uint256 _value) external onlyRole(ALLOWED_CALLER) {
        velo.transferFrom(msg.sender, address(this), _value);
        _handleApproval(velo, address(ve), _value);
        ve.increaseAmount(mTokenId, _value);
    }

    /// @inheritdoc IRelay
    function vote(address[] calldata _poolVote, uint256[] calldata _weights) external onlyRole(ALLOWED_CALLER) {
        voter.vote(mTokenId, _poolVote, _weights);
        keeperLastRun = block.timestamp;
    }

    // -------------------------------------------------
    // ADMIN functions
    // -------------------------------------------------

    /// @inheritdoc IRelay
    function setOptimizer(address _optimizer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_optimizer == address(0)) revert ZeroAddress();
        if (address(optimizer) == _optimizer) revert SameOptimizer();
        if (!relayFactory.isOptimizer(_optimizer)) revert OptimizerNotApproved();
        optimizer = IOptimizer(_optimizer);
        emit SetOptimizer(_optimizer);
    }

    // -------------------------------------------------
    // Helper functions
    // -------------------------------------------------

    /// @dev resets approval if needed then approves transfer of tokens
    function _handleApproval(IERC20 token, address sender, uint256 amount) internal {
        uint256 allowance = token.allowance(address(this), sender);
        if (allowance > 0) token.safeDecreaseAllowance(sender, allowance);
        token.safeIncreaseAllowance(sender, amount);
    }

    /// @dev claim rebase earned if possible
    function _handleRebase() internal {
        uint256 _mTokenId = mTokenId;
        if (distributor.claimable(_mTokenId) > 0) {
            distributor.claim(_mTokenId);
        }
    }
}
