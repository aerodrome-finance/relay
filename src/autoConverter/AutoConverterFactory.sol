// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {AutoConverter} from "./AutoConverter.sol";
import {RelayFactory} from "../RelayFactory.sol";

import {IVotingEscrow} from "@velodrome/contracts/interfaces/IVotingEscrow.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

/// @title AutoConverterFactory
/// @author velodrome.finance, @pegahcarter, @airtoonricardo, @pedrovalido
/// @notice Factory contract to create AutoConverters and manage authorized callers of the AutoConverters
contract AutoConverterFactory is RelayFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable optimizer;

    constructor(
        address _forwarder,
        address _voter,
        address _router,
        address _optimizer,
        address _keeperRegistry,
        address[] memory highLiquidityTokens_
    ) RelayFactory(_forwarder, _voter, _router, _keeperRegistry, highLiquidityTokens_) {
        optimizer = _optimizer;
    }

    function _deployRelayInstance(
        address _admin,
        string calldata _name,
        bytes calldata _data
    ) internal override returns (address autoConverter) {
        address _token = abi.decode(_data, (address));
        if (_token == address(0)) revert ZeroAddress();

        autoConverter = address(
            new AutoConverter(forwarder, voter, _admin, _name, router, _token, optimizer, address(this))
        );
    }
}
