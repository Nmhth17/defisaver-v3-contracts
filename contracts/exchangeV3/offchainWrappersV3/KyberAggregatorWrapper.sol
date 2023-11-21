// SPDX-License-Identifier: MIT

pragma solidity =0.8.10;

import "../../DS/DSMath.sol";
import "../../auth/AdminAuth.sol";
import "../DFSExchangeHelper.sol";
import "../../interfaces/exchange/IOffchainWrapper.sol";
import "../../utils/KyberInputScalingHelper.sol";
import "../../core/DFSRegistry.sol";
import "../../core/helpers/CoreHelper.sol";

contract KyberAggregatorWrapper is IOffchainWrapper, DFSExchangeHelper, AdminAuth, DSMath, CoreHelper{

    using TokenUtils for address;

    bytes4 constant SCALING_HELPER_ID = bytes4(keccak256("KyberInputScalingHelper"));
    DFSRegistry public constant registry = DFSRegistry(REGISTRY_ADDR);

    //Not enough funds
    error InsufficientFunds(uint256 available, uint256 required);

    //Order success but amount 0
    error ZeroTokensSwapped();

    using SafeERC20 for IERC20;

    /// @notice Takes order from Paraswap and returns bool indicating if it is successful
    /// @param _exData Exchange data
    function takeOrder(
        ExchangeData memory _exData
    ) external override payable returns (bool success, uint256) {
        // check that contract have enough balance for exchange and protocol fee
        uint256 tokenBalance = _exData.srcAddr.getBalance(address(this));
        if (tokenBalance < _exData.srcAmount){
            revert InsufficientFunds(tokenBalance, _exData.srcAmount);
        }

        /// @dev safeApprove is modified to always first set approval to 0, then to exact amount
        IERC20(_exData.srcAddr).safeApprove(_exData.offchainData.allowanceTarget, _exData.srcAmount);

        address scalingHelperAddr = registry.getAddr(SCALING_HELPER_ID);
        bytes memory scaledCalldata = KyberInputScalingHelper(scalingHelperAddr).getScaledInputData(_exData.offchainData.callData, _exData.srcAmount);
        
        uint256 tokensBefore = _exData.destAddr.getBalance(address(this));

        /// @dev the amount of tokens received is checked in DFSExchangeCore
        /// @dev Exchange wrapper contracts should not be used on their own
        (success, ) = _exData.offchainData.exchangeAddr.call(scaledCalldata);

        uint256 tokensSwapped = 0;

        if (success) {
            // get the current balance of the swapped tokens
            tokensSwapped = _exData.destAddr.getBalance(address(this)) - tokensBefore;
            if (tokensSwapped == 0){
                revert ZeroTokensSwapped();
            }
        }

        // returns all funds from src addr, dest addr and eth funds (protocol fee leftovers)
        _sendLeftover(_exData.srcAddr, _exData.destAddr, payable(msg.sender));

        return (success, tokensSwapped);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}