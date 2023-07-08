// SPDX-License-Identifier: MIT

pragma solidity =0.8.10;

contract LSVProfitTracker{

    mapping(string => mapping(address => int256)) public unrealisedProfit;

    function supply(string memory _protocol, uint256 _amount) public {
        unrealisedProfit[_protocol][msg.sender] -= downCastUintToInt(_amount); 
    }

    function borrow(string memory _protocol, uint256 _amount) public {
        unrealisedProfit[_protocol][msg.sender] += downCastUintToInt(_amount); 
    }
    
    function payback(string memory _protocol, uint256 _amount) public {
        unrealisedProfit[_protocol][msg.sender] -= downCastUintToInt(_amount); 
    }

    function withdraw(string memory _protocol, uint256 _amount,  bool _isClosingVault) public returns (uint256 feeAmount){
        unrealisedProfit[_protocol][msg.sender] += downCastUintToInt(_amount);
        
        if (unrealisedProfit[_protocol][msg.sender] > 0){
            feeAmount = uint256(unrealisedProfit[_protocol][msg.sender]) / 10;
            unrealisedProfit[_protocol][msg.sender] = 0;
        } else if (_isClosingVault) {
            unrealisedProfit[_protocol][msg.sender] = 0;
        }

        return feeAmount;
    }

    function downCastUintToInt(uint256 uintAmount) internal pure returns(int256 amount){
        require(uintAmount <= uint256(type(int256).max));
        return int256(uintAmount);
    }
}