// SPDX-License-Identifier: MIT
pragma solidity =0.8.10;

import "../auth/AdminAuth.sol";

contract SaverExchangeRegistry is AdminAuth {

	mapping(address => bool) private wrappers;

	function addWrapper(address _wrapper) external onlyOwner {
		wrappers[_wrapper] = true;
	}

	function removeWrapper(address _wrapper) external onlyOwner {
		wrappers[_wrapper] = false;
	}

	function isWrapper(address _wrapper) external view returns(bool) {
		return wrappers[_wrapper];
	}
}
