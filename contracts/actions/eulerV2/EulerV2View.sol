// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import { IEVault } from "../../interfaces/eulerV2/IEVault.sol";
import { IPriceOracle } from "../../interfaces/eulerV2/IPriceOracle.sol";
import { IEVC } from "../../interfaces/eulerV2/IEVC.sol";
import { IIRM } from "../../interfaces/eulerV2/IIRM.sol";

import { EulerV2Helper } from "./helpers/EulerV2Helper.sol";

/// @title EulerV2View - aggregate various information about Euler vaults and users
contract EulerV2View is EulerV2Helper {

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // When flag is set, debt socialization during liquidation is disabled
    uint32 constant CFG_DONT_SOCIALIZE_DEBT = 1 << 0;
    // When flag is set, asset is considered to be compatible with EVC sub-accounts and protections
    // against sending assets to sub-accounts are disabled
    uint32 constant CFG_EVC_COMPATIBLE_ASSET = 1 << 1;
    // max interest rate accepted from IRM. 1,000,000% APY: floor(((1000000 / 100 + 1)**(1/(86400*365.2425)) - 1) * 1e27)
    uint256 constant MAX_ALLOWED_INTEREST_RATE = 291867278914945094175;


    /*//////////////////////////////////////////////////////////////
                          DATA FORMAT
    //////////////////////////////////////////////////////////////*/

    /// @notice Basic vault information
    struct VaultInfo {
        address vaultAddr;                  // Address of the Euler vault
        address assetAddr;                  // Address of the underlying asset
        string symbol;                      // Vault symbol
        address[] supportedCollaterals;     // Supported collateral assets
    }

    /// @notice Collateral information
    struct CollateralInfo {
        address vaultAddr;                  // Address of the Euler vault
        address assetAddr;                  // Address of the underlying asset
        string vaultSymbol;                 // Vault symbol
        uint256 decimals;                   // Decimals, the same as the asset's or 18 if the asset doesn't implement `decimals()`
        uint256 sharePriceInUnit;           // Price of one share in the unit of account. Scaled by 1e18
        uint256 cash;                       // Balance of vault assets as tracked by deposits/withdrawals and borrows/repays
        uint256 totalBorrows;               // Sum of all outstanding debts, in underlying units (increases as interest is accrued)
        uint256 supplyCap;                  // Maximum total amount of assets that can be supplied to the vault
        uint16 borrowLTV;                   // The current value of borrow LTV for originating positions
        uint16 liquidationLTV;              // The value of fully converged liquidation LTV
        uint16 initialLiquidationLTV;       // The initial value of the liquidation LTV, when the ramp began
        uint48 targetTimestamp;             // The timestamp when the liquidation LTV is considered fully converged
        uint32 rampDuration;                // The time it takes for the liquidation LTV to converge from the initial value to the fully converged value
    }

    /// @notice Full information about a vault
    struct VaultInfoFull {
        address vaultAddr;                  // Address of the Euler vault
        address assetAddr;                  // Address of the underlying asset 
        address dTokenAddr;                 // Address of the debt token. Only used for offchain tracking
        string name;                        // Vault name
        string symbol;                      // Vault symbol
        uint256 decimals;                   // Decimals, the same as the asset's or 18 if the asset doesn't implement `decimals()`

        uint256 totalSupplyShares;          // Total supply shares. Sum of all eTokens balances
        uint256 cash;                       // Balance of vault assets as tracked by deposits/withdrawals and borrows/repays
        uint256 totalBorrows;               // Sum of all outstanding debts, in underlying units (increases as interest is accrued)
        uint256 totalAssets;                // Total amount of managed assets, cash + borrows
        uint256 supplyCap;                  // Maximum total amount of assets that can be supplied to the vault
        uint256 borrowCap;                  // Maximum total amount of assets that can be borrowed from the vault

        CollateralInfo[] collaterals;       // Supported collateral assets with their LTV configurations
        uint16 maxLiquidationDiscount;      // The maximum liquidation discount in 1e4 scale
        uint256 liquidationCoolOffTime;     // Liquidation cool-off time, which must elapse after successful account status check before

        address hookTarget;                 // Address of the hook target contract
        uint32 hookedOps;                   // Bitmask indicating which operations call the hook target
        uint32 configFlags;                 // Bitmask of configuration flags
        bool badDebtSocializationEnabled;   // Flag indicating whether bad debt socialization is enabled
        bool evcCompatibleAssets;           // Flag indicating whether protection for sending assets to sub-accounts is disabled

        address unitOfAccount;              // Reference asset used for liquidity calculations
        address oracle;                     // Address of the oracle contract
        uint256 assetPriceInUnit;           // Price of one asset in the unit of account, scaled by 1e18
        uint256 sharePriceInUnit;           // Price of one share in the unit of account, scaled by 1e18
        uint256 assetsPerShare;             // How much one share is worth in underlying asset, scaled by 1e18
        uint256 sharesPerAsset;             // How much one underlying asset is worth in shares, scaled by 1e18

        uint256 accumulatedFeesInShares;    // Balance of the fees accumulator, in shares
        uint256 accumulatedFeesInAssets;    // Balance of the fees accumulator, in underlying units
        uint256 interestRate;               // Current borrow interest rate for an asset in yield-per-second, scaled by 10**27
        uint256 interestAccumulator;        // Current interest rate accumulator for an asset
        address irm;                        // Address of the interest rate contract or address zero to indicate 0% interest
        address balanceTrackerAddress;      // Retrieve the address of rewards contract, tracking changes in account's balances
        address creator;                    // Address of the creator of the vault
        address governorAdmin;              // Address of the governor admin of the vault, or address zero if escrow vault for example
        address feeReceiver;                // Address of the governance fee receiver
        uint256 interestFee;                // Interest that is redirected as a fee, as a fraction scaled by 1e4
        address protocolConfigAddress;      // ProtocolConfig address
        uint256 protocolFeeShare;           // Protocol fee share
        address protocolFeeReceiver;        // Address which will receive protocol's fees
        address permit2Address;             // Address of the permit2 contract
    }

    /// @notice User data with loan information
    struct UserData {
        address user;                       // Address of the user
        address owner;                      // Address of the owner address space. Same as user if user is not a sub-account
        bool inLockDownMode;                // Flag indicating whether the account is in lockdown mode
        bool inPermitDisabledMode;          // Flag indicating whether the account is in permit disabled mode
        address borrowVault;                // Address of the borrow vault (aka controller)
        uint256 borrowAmountInUnit;         // Amount of borrowed assets in the unit of account
        address[] collaterals;              // Enabled collateral assets
        uint256[] collateralAmountsInUnit;  // Amounts of collaterals in unit of account. If coll is not supported by the borrow vault, returns 0
    }

    /// @notice Used for borrow rate estimation
    /// @notice if isBorrowOperation => (liquidityAdded = repay, liquidityRemoved = borrow)
    /// @notice if not, look at it as supply/withdraw operation => (liquidityAdded = supply, liquidityRemoved = withdraw)
    struct LiquidityChangeParams {
        address vault;                      // Address of the Euler vault          
        bool isBorrowOperation;             // Flag indicating whether the operation is a borrow operation (repay/borrow), otherwise supply/withdraw
        uint256 liquidityAdded;             // Amount of liquidity added to the vault
        uint256 liquidityRemoved;           // Amount of liquidity removed from the vault
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Get list of users load data
    function getUsersData(address[] calldata _users) external view returns (UserData[] memory data) {
        data = new UserData[](_users.length);
        for (uint256 i = 0; i < _users.length; ++i) {
            data[i] = getUserData(_users[i]);
        }
    }

    /// @notice Get loan data for a user
    function getUserData(address _user) public view returns (UserData memory data) {
        bytes19 addressPrefix = getAddressPrefixInternal(_user);

        address[] memory controllers = IEVC(EVC_ADDR).getControllers(_user);
        address[] memory collaterals = IEVC(EVC_ADDR).getCollaterals(_user);

        bool controllerEnabled = controllers.length > 0;
        address controller = controllerEnabled ? controllers[0] : address(0);

        uint256 borrowAmount;
        uint256[] memory collateralAmounts = new uint256[](collaterals.length);
        if (controllerEnabled) {
           (, collateralAmounts, borrowAmount) = IEVault(controller).accountLiquidityFull(_user, false);
        }

        data = UserData({
            user: _user,
            owner: IEVC(EVC_ADDR).getAccountOwner(_user),
            inLockDownMode: IEVC(EVC_ADDR).isLockdownMode(addressPrefix),
            inPermitDisabledMode: IEVC(_user).isPermitDisabledMode(addressPrefix),
            borrowVault: controller,
            borrowAmountInUnit: borrowAmount,
            collaterals: collaterals,
            collateralAmountsInUnit: collateralAmounts
        });
    }

    /// @notice Get list of vaults with full information
    function getVaultsInfosFull(address[] calldata _vaults) external view returns (VaultInfoFull[] memory data) {
        data = new VaultInfoFull[](_vaults.length);
        for (uint256 i = 0; i < _vaults.length; ++i) {
            data[i] = getVaultInfoFull(_vaults[i]);
        }
    }

    /// @notice Get full information about a vault
    function getVaultInfoFull(address _vault) public view returns (VaultInfoFull memory data) {
        IEVault v = IEVault(_vault);

        (uint16 supplyCap, uint16 borrowCap) = v.caps();
        (address hookTarget, uint32 hookedOps) = v.hookConfig();
        uint32 configFlags = v.configFlags();
        address oracle = v.oracle();
        address asset = v.asset();
        address unitOfAccount = v.unitOfAccount();

        CollateralInfo[] memory collaterals = _getVaultCollaterals(_vault, unitOfAccount, oracle);

        data = VaultInfoFull({
            vaultAddr: _vault,
            assetAddr: asset,
            dTokenAddr: v.dToken(),
            name: v.name(),
            symbol: v.symbol(),
            decimals: v.decimals(),
            totalSupplyShares: v.totalSupply(),
            cash: v.cash(),
            totalBorrows: v.totalBorrows(),
            totalAssets: v.totalAssets(),
            supplyCap: _resolveAmountCap(supplyCap),
            borrowCap: _resolveAmountCap(borrowCap),
            collaterals: collaterals,
            maxLiquidationDiscount: v.maxLiquidationDiscount(),
            liquidationCoolOffTime: v.liquidationCoolOffTime(),
            hookTarget: hookTarget,
            hookedOps: hookedOps,
            configFlags: configFlags,
            badDebtSocializationEnabled: configFlags & CFG_DONT_SOCIALIZE_DEBT == 0,
            evcCompatibleAssets: configFlags & CFG_EVC_COMPATIBLE_ASSET == CFG_EVC_COMPATIBLE_ASSET,
            unitOfAccount: unitOfAccount,
            oracle: oracle,
            assetPriceInUnit: _getOraclePriceInUnitOfAccount(oracle, asset, unitOfAccount),
            sharePriceInUnit: _getOraclePriceInUnitOfAccount(oracle, _vault, unitOfAccount),
            assetsPerShare: v.convertToAssets(1e18),
            sharesPerAsset: v.convertToShares(1e18),
            accumulatedFeesInShares: v.accumulatedFees(),
            accumulatedFeesInAssets: v.accumulatedFeesAssets(),
            interestRate: v.interestRate(),
            interestAccumulator: v.interestAccumulator(),
            irm: v.interestRateModel(),
            balanceTrackerAddress: v.balanceTrackerAddress(),
            creator: v.creator(),
            governorAdmin: v.governorAdmin(),
            feeReceiver: v.feeReceiver(),
            interestFee: v.interestFee(),
            protocolConfigAddress: v.protocolConfigAddress(),
            protocolFeeShare: v.protocolFeeShare(),
            protocolFeeReceiver: v.protocolFeeReceiver(),
            permit2Address: v.permit2Address()       
        });
    }

    /// @notice Get list of vaults with basic information
    function getVaultsInfos(address[] calldata _vaults) external view returns (VaultInfo[] memory data) {
        data = new VaultInfo[](_vaults.length);
        for (uint256 i = 0; i < _vaults.length; ++i) {
            data[i] = getVaultInfo(_vaults[i]);
        }
    }

    /// @notice Get basic information about a vault
    function getVaultInfo(address _vault) public view returns (VaultInfo memory data) {
        IEVault v = IEVault(_vault);
        data = VaultInfo({
            vaultAddr: _vault,
            assetAddr: v.asset(),
            symbol: v.symbol(),
            supportedCollaterals: v.LTVList()
        });
    }

    /// @notice Get list of collaterals for a vault
    function getVaultCollaterals(address _vault) public view returns (CollateralInfo[] memory collateralsInfo) {
        address unitOfAccount = IEVault(_vault).unitOfAccount();
        address oracle = IEVault(_vault).oracle();
        collateralsInfo = _getVaultCollaterals(_vault, unitOfAccount, oracle);
    }

    /// @notice Fetches used accounts. Search up to `_sizeLimit` of sub-accounts
    function fetchUsedAccounts(address _account, uint256 _sizeLimit) external view returns (address[] memory accounts) {
        require(_sizeLimit >= 1 && _sizeLimit <= 255);

        accounts = new address[](_sizeLimit);

        address owner = IEVC(EVC_ADDR).getAccountOwner(_account);

        // if no main account is registered, return empty array
        if (owner == address(0)) {
            return accounts;
        }

        accounts[0] = owner;

        bytes19 addressPrefix = getAddressPrefixInternal(_account);

        for (uint8 i = 1; i < _sizeLimit; ++i) {
            address subAccount = getSubAccountByPrefix(addressPrefix, bytes1(i));
            address[] memory controllers = IEVC(EVC_ADDR).getControllers(subAccount);
            if (controllers.length > 0) {
                accounts[i] = subAccount;
            } else {
                address[] memory collaterals = IEVC(EVC_ADDR).getCollaterals(subAccount);
                accounts[i] = collaterals.length > 0 ? subAccount : address(0);
            }
        }
    }

    /// @notice Get borrow rate estimation after liquidity change
    /// @dev Should be called with staticcall
    function getApyAfterValuesEstimation(LiquidityChangeParams[] memory params) 
        public returns (uint256[] memory estimatedBorrowRates) 
    {
        estimatedBorrowRates = new uint256[](params.length);
        for (uint256 i = 0; i < params.length; ++i) {
            IEVault v = IEVault(params[i].vault);
            v.touch();

            address irm = v.interestRateModel();
            if (irm == address(0)) {
                estimatedBorrowRates[i] = 0;
                continue;
            }

            uint256 oldInterestRate = v.interestRate();
            uint256 cash = v.cash();
            uint256 totalBorrows = v.totalBorrows();
            
            if (params[i].isBorrowOperation) {
                // when repaying
                if (params[i].liquidityAdded > 0) {
                    cash += params[i].liquidityAdded;
                    totalBorrows = totalBorrows > params[i].liquidityAdded ? totalBorrows - params[i].liquidityAdded : 0;
                }
                // when borrowing
                if (params[i].liquidityRemoved > 0) {
                    cash = cash > params[i].liquidityRemoved ? cash - params[i].liquidityRemoved : 0;
                    totalBorrows += params[i].liquidityRemoved;
                }
            } else {
                // when supplying
                if (params[i].liquidityAdded > 0) {
                    cash += params[i].liquidityAdded;
                }
                // when withdrawing
                if (params[i].liquidityRemoved > 0) {
                    cash = cash > params[i].liquidityRemoved ? cash - params[i].liquidityRemoved : 0;
                }
            }

            (bool success, bytes memory data) = irm.staticcall(
                abi.encodeCall(
                    IIRM.computeInterestRateView,
                    (address(this), cash, totalBorrows)
                )
            );

            if (success && data.length >= 32) {
                uint256 newInterestRate = abi.decode(data, (uint256));
                if (newInterestRate > MAX_ALLOWED_INTEREST_RATE) {
                    newInterestRate = MAX_ALLOWED_INTEREST_RATE;
                }
                estimatedBorrowRates[i] = newInterestRate;
            } else {
                estimatedBorrowRates[i] = oldInterestRate;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL METHODS
    //////////////////////////////////////////////////////////////*/

    function _getVaultCollaterals(address _vault, address _unitOfAccount, address _oracle) internal view returns (CollateralInfo[] memory collateralsInfo) {
        address[] memory collaterals = IEVault(_vault).LTVList();
        collateralsInfo = new CollateralInfo[](collaterals.length);
        
        for (uint256 i = 0; i < collaterals.length; ++i) {
            (
                collateralsInfo[i].borrowLTV,
                collateralsInfo[i].liquidationLTV,
                collateralsInfo[i].initialLiquidationLTV,
                collateralsInfo[i].targetTimestamp,
                collateralsInfo[i].rampDuration
            ) = IEVault(_vault).LTVFull(collaterals[i]);

            collateralsInfo[i].vaultAddr = collaterals[i];
            collateralsInfo[i].assetAddr = IEVault(collaterals[i]).asset();
            collateralsInfo[i].vaultSymbol = IEVault(collaterals[i]).symbol();
            collateralsInfo[i].decimals = IEVault(collaterals[i]).decimals();

            collateralsInfo[i].sharePriceInUnit = _getOraclePriceInUnitOfAccount(
                _oracle,
                collaterals[i],
                _unitOfAccount
            );

            collateralsInfo[i].cash = IEVault(collaterals[i]).cash();
            
            collateralsInfo[i].totalBorrows = IEVault(collaterals[i]).totalBorrows();

            (uint16 supplyCap,) = IEVault(collaterals[i]).caps();
            collateralsInfo[i].supplyCap = _resolveAmountCap(supplyCap);
        }
    }

    function _getOraclePriceInUnitOfAccount(
        address _oracle,
        address _token,
        address _unitOfAccount
    ) internal view returns (uint256 price) {
        uint256 decimals = IEVault(_token).decimals();
        uint256 inAmount = 10 ** decimals;
        
        if (_oracle != address(0)) {
            try IPriceOracle(_oracle).getQuote(inAmount, _token, _unitOfAccount) returns (uint256 quote) {
                return quote;
            } catch {
                return 0;
            }
        }
    }

    function _resolveAmountCap(uint16 amountCap) internal pure returns (uint256) {
        if (amountCap == 0) return type(uint256).max;
        return 10 ** (amountCap & 63) * (amountCap >> 6) / 100;
    }
}