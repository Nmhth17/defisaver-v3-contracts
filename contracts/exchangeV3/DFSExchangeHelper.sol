// SPDX-License-Identifier: MIT

pragma solidity =0.8.10;

import "../utils/TokenUtils.sol";
import "../utils/SafeERC20.sol";
import "../utils/Discount.sol";

abstract contract DFSExchangeHelper {
    using TokenUtils for address;
    
    error InvalidOffchainData();
    error OutOfRangeSlicingError();

    using SafeERC20 for IERC20;

    function _sendLeftover(
        address _srcAddr,
        address _destAddr,
        address payable _to
    ) internal {
        // clean out any eth leftover
        TokenUtils.ETH_ADDR.withdrawTokens(_to, type(uint256).max);

        _srcAddr.withdrawTokens(_to, type(uint256).max);
        _destAddr.withdrawTokens(_to, type(uint256).max);
    }

    function _writeUint256(
        bytes memory _b,
        uint256 _index,
        uint256 _input
    ) internal pure {
        if (_b.length < _index + 32) {
            revert InvalidOffchainData();
        }

        bytes32 input = bytes32(_input);

        _index += 32;

        // Read the bytes32 from array memory
        assembly {
            mstore(add(_b, _index), input)
        }
    }
}
