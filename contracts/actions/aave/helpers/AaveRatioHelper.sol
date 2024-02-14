// SPDX-License-Identifier: MIT

pragma solidity =0.8.10;

import "../../../interfaces/aaveV2/ILendingPoolV2.sol";
import "../../../interfaces/aaveV2/ILendingPoolAddressesProviderV2.sol";
import "../../../DS/DSMath.sol";
import "./MainnetAaveAddresses.sol";

contract AaveRatioHelper is DSMath, MainnetAaveAddresses {

    /// @notice Calculated the ratio of coll * weighted ltv / debt for aave V2 user
    /// @param _market Address of LendingPoolAddressesProvider for specific market
    /// @param _user Address of the user
    function getSafetyRatio(address _market, address _user) public view returns(uint256) {
        ILendingPoolV2 lendingPool = ILendingPoolV2(ILendingPoolAddressesProviderV2(_market).getLendingPool());
        
        (uint256 totalCollETH,uint256 totalDebtETH,,,uint256 ltv,) = lendingPool.getUserAccountData(_user);

        if (totalDebtETH == 0) return 0;
        /// @dev we're multiplying ltv with 10**14 so it represents number with 18 decimals (since 0 < ltv < 10000)
        return wdiv(wmul(totalCollETH, ltv * 10**14), totalDebtETH);
    }
}