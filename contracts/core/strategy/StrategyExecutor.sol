// SPDX-License-Identifier: MIT

pragma solidity =0.8.4;

import "../../auth/AdminAuth.sol";
import "../../interfaces/IDSProxy.sol";
import "./StrategyModel.sol";
import "./BotAuth.sol";
import "../DFSRegistry.sol";
import "./ProxyAuth.sol";
import "../strategy/SubStorage.sol";
import "../strategy/StrategyStorage.sol";

/// @title Main entry point for executing automated strategies
contract StrategyExecutor is StrategyModel, AdminAuth {
    bytes4 constant PROXY_AUTH_ID = bytes4(keccak256("ProxyAuth"));

    address public constant REGISTRY_ADDR = 0xD5cec8F03f803A74B60A7603Ed13556279376b09;
    DFSRegistry public constant registry = DFSRegistry(REGISTRY_ADDR);

    bytes4 constant BOT_AUTH_ID = bytes4(keccak256("BotAuth"));
    bytes4 constant SUB_STORAGE_ID = bytes4(keccak256("SubStorage"));

    bytes4 constant RECIPE_EXECUTOR_ID = bytes4(keccak256("RecipeExecutor"));

    error BotNotApprovedError(address, uint256);
    error SubNotActiveError(uint256);

    /// @notice Checks all the triggers and executes actions
    /// @dev Only authorized callers can execute it
    /// @param _subId Id of the subscription
    /// @param _triggerCallData All input data needed to execute triggers
    /// @param _actionsCallData All input data needed to execute actions
    function executeStrategy(
        uint256 _subId,
        uint256 _strategyIndex, // need to specify because if sub is part of a bundle
        bytes[] calldata _triggerCallData,
        bytes[] calldata _actionsCallData
    ) public {
        StrategySub memory sub = SubStorage(registry.getAddr(SUB_STORAGE_ID)).getSub(_subId);

        if (!sub.active) {
            revert SubNotActiveError(_subId);
        }

        // check bot auth
        bool botHasAuth = checkCallerAuth(_subId);

        if (!botHasAuth) {
            revert BotNotApprovedError(msg.sender, _subId);
        }

        // execute actions
        callActions(_subId, _actionsCallData, _triggerCallData, sub.userProxy, _strategyIndex);
    }

    /// @notice Checks if msg.sender has auth, reverts if not
    /// @param _subId Id of the strategy
    function checkCallerAuth(uint256 _subId) public view returns (bool) {
        return BotAuth(registry.getAddr(BOT_AUTH_ID)).isApproved(_subId, msg.sender);
    }


    /// @notice Checks triggers and execute all the actions in order
    /// @param _subId Strategy data we have in storage
    /// @param _actionsCallData All input data needed to execute actions
    function callActions(
        uint256 _subId,
        bytes[] calldata _actionsCallData,
        bytes[] calldata _triggerCallData,
        address _proxy,
        uint256 _strategyIndex
    ) internal {
        address RecipeExecutorAddr = registry.getAddr(RECIPE_EXECUTOR_ID);

        address proxyAuthAddr = registry.getAddr(PROXY_AUTH_ID);

        ProxyAuth(proxyAuthAddr).callExecute{value: msg.value}(
            _proxy,
            RecipeExecutorAddr,
            abi.encodeWithSignature(
                "executeRecipeFromStrategy(uint256,bytes[],bytes[],uint256)",
                _subId,
                _actionsCallData,
                _triggerCallData,
                _strategyIndex
            )
        );
    }
}