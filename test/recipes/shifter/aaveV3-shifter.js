const { expect } = require('chai');
const hre = require('hardhat');
const dfs = require('@defisaver/sdk');
const { BigNumber } = require('ethers');
const {
    getProxy,
    approve,
    WETH_ADDRESS,
    LUSD_ADDR,
    nullAddress,
    WSTETH_ADDRESS,
    A_WSETH_TOKEN_ADDR,
    takeSnapshot,
    revertToSnapshot,
    setBalance,
    getAddrFromRegistry,
    addrs,
    getNetwork,
    balanceOf,
    redeploy,
} = require('../../utils');

const { liquityOpen, executeAction } = require('../../actions');
const { getTroveInfo } = require('../../utils-liquity');
const { getAaveReserveData, getEstimatedTotalLiquidityForToken, VARIABLE_RATE } = require('../../utils-aave');

const WSETH_ASSET_ID_IN_AAVE_V3_MARKET = '1';
const LUSD_ASSET_ID_IN_AAVE_V3_MARKET = '10';
const AAVE_NO_DEBT_MODE = '0';
const AAVE_VARIABLE_DEBT_MODE = '2';
const ETH_USD_PRICE_FEED = '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419';

const aaveV3Shifter = async () => {
    describe('Aave V3 Shifter from liquity position', () => {
        let senderAcc;
        let senderAddr;
        let proxy;
        let proxyAddr;
        let snapshotId;
        let flAaveV3Address;

        const createLiquityPosition = async (collAmount, LUSDAmount) => {
            await setBalance(WETH_ADDRESS, senderAddr, collAmount);
            await approve(WETH_ADDRESS, proxyAddr, senderAcc);
            const maxFeePercentage = hre.ethers.utils.parseUnits('5', 16);
            const tx = await liquityOpen(
                proxy,
                maxFeePercentage,
                collAmount,
                LUSDAmount,
                senderAddr,
                senderAddr,
            );
            await tx.wait();
            const troveInfo = await getTroveInfo(proxyAddr);
            console.log(`Trove created for proxy: ${proxyAddr}. TroveInfo: ${troveInfo}`);
            return troveInfo;
        };

        const actions = {
            flAaveV3Action: (debtAmount) => new dfs.actions.flashloan.AaveV3FlashLoanNoFeeAction(
                [LUSD_ADDR],
                [debtAmount.toString()],
                [AAVE_NO_DEBT_MODE],
                nullAddress,
            ),
            flAaveV3ActionWithDeptPosition: (debtAmount) => new dfs.actions.flashloan
                .AaveV3FlashLoanNoFeeAction(
                    [LUSD_ADDR],
                    [debtAmount.toString()],
                    [AAVE_VARIABLE_DEBT_MODE],
                    proxyAddr,
                ),
            lidoWrapAction: (collAmount) => new dfs.actions.lido.LidoWrapAction(
                collAmount.toString(),
                proxyAddr,
                proxyAddr,
                true, // is eth
            ),
            liquityCloseAction: () => new dfs.actions.liquity.LiquityCloseAction(
                proxyAddr,
                proxyAddr,
            ),
            aaveV3SupplyAction: () => new dfs.actions.aaveV3.AaveV3SupplyAction(
                true, // use default market
                addrs[getNetwork()].AAVE_MARKET,
                '$3', // pipe from lido wrap action
                proxyAddr,
                WSTETH_ADDRESS,
                WSETH_ASSET_ID_IN_AAVE_V3_MARKET,
                true, // use as collateral
                false, // use on behalf of
                nullAddress, // on behalf of
            ),
            aaveV3BorrowAction: (debtAmount) => new dfs.actions.aaveV3.AaveV3BorrowAction(
                true, // use default market
                addrs[getNetwork()].AAVE_MARKET,
                debtAmount.toString(), // debt amount
                proxyAddr,
                AAVE_VARIABLE_DEBT_MODE,
                LUSD_ASSET_ID_IN_AAVE_V3_MARKET,
                false,
                nullAddress,
            ),
            sendTokenActionFLPayback: () => new dfs.actions.basic.SendTokenAction(
                LUSD_ADDR,
                flAaveV3Address,
                '$1', // from FL action
            ),
            sendTokenActionCleanUpProxy: () => new dfs.actions.basic.SendTokenAction(
                LUSD_ADDR,
                senderAddr,
                hre.ethers.constants.MaxUint256.toString(), // send all DSProxy LUSD leftover
            ),
            delegateCreditOnAaveV3Action: () => new dfs.actions.aaveV3.AaveV3DelegateCredit(
                true,
                addrs[getNetwork()].AAVE_MARKET,
                '$1', // from FL action
                VARIABLE_RATE,
                LUSD_ASSET_ID_IN_AAVE_V3_MARKET,
                flAaveV3Address,
            ),
        };

        const regularShiftRecipe = (troveInfo) => new dfs.Recipe('Shift', [
            actions.flAaveV3Action(troveInfo.debtAmount),
            actions.liquityCloseAction(),
            actions.lidoWrapAction(troveInfo.collAmount),
            actions.aaveV3SupplyAction(),
            actions.aaveV3BorrowAction(troveInfo.debtAmount),
            actions.sendTokenActionFLPayback(),
            actions.sendTokenActionCleanUpProxy(),
        ]);

        const createLiquityPosWithDebtGtThanHalfOfLiquidityOnAaveV3 = async () => {
            const totalLUSDLiquidity = await getEstimatedTotalLiquidityForToken(LUSD_ADDR);
            const estimatedTotalLiquidityUSD = totalLUSDLiquidity.div(BigNumber.from('10').pow('18'));

            const ethPriceInUSDData = await hre.ethers.getContractAt('IAggregatorV3', ETH_USD_PRICE_FEED).then((c) => c.latestRoundData());
            const ethPriceInUSD = ethPriceInUSDData.answer.div(BigNumber.from('10').pow('8'));

            const ethCollAmount = estimatedTotalLiquidityUSD.div(ethPriceInUSD).mul(2);
            const totalDebtLUSD = estimatedTotalLiquidityUSD.div(2).add(BigNumber.from('50000'));

            const collAmountFormatted = hre.ethers.utils.parseUnits(ethCollAmount.toString(), 18);
            const LUSDAmountFormatted = hre.ethers.utils.parseUnits(totalDebtLUSD.toString(), 18);
            const troveInfo = await createLiquityPosition(collAmountFormatted, LUSDAmountFormatted);
            return troveInfo;
        };

        before(async () => {
            //flAaveV3Address = await getAddrFromRegistry('FLAaveV3');
            const flAaveV3Contract = await redeploy('FLAaveV3');
            flAaveV3Address = flAaveV3Contract.address;

            // not deployed so we need to deploy it
            await redeploy('AaveV3DelegateCredit');

            await redeploy('RecipeExecutor');

            senderAcc = (await hre.ethers.getSigners())[0];
            senderAddr = senderAcc.address;
            proxy = await getProxy(senderAddr);
            proxyAddr = proxy.address;
        });

        beforeEach(async () => {
            snapshotId = await takeSnapshot();
        });

        afterEach(async () => {
            await revertToSnapshot(snapshotId);
        });

        it('... should shift from WETH/LUSD to WSETH/LUSD', async () => {
            const collAmount = hre.ethers.utils.parseUnits('50', 18);
            const LUSDAmount = hre.ethers.utils.parseUnits('30000', 18);
            const troveInfo = await createLiquityPosition(collAmount, LUSDAmount);

            const shiftRecipe = regularShiftRecipe(troveInfo);
            console.log(troveInfo.debtAmount.toString());

            const functionData = shiftRecipe.encodeForDsProxyCall();
            await executeAction('RecipeExecutor', functionData[1], proxy);

            const newTroveInfo = await getTroveInfo(proxyAddr);

            expect(newTroveInfo.troveStatus).to.equal(2); // 2 for closedByOwner status
            expect(newTroveInfo.collAmount).to.equal(0);
            expect(newTroveInfo.debtAmount).to.equal(0);

            const proxyBalance = await balanceOf(A_WSETH_TOKEN_ADDR, proxyAddr);
            expect(proxyBalance).to.be.gt(0);
        });

        it('... should fail to shift from WETH/LUSD to WSETH/LUSD because of insufficient aaveV3 liquidity', async () => {
            const troveInfo = await createLiquityPosWithDebtGtThanHalfOfLiquidityOnAaveV3();
            const shiftRecipe = regularShiftRecipe(troveInfo);
            const functionData = shiftRecipe.encodeForDsProxyCall();
            await expect(executeAction('RecipeExecutor', functionData[1], proxy))
                .to.be.revertedWith('Error: Transaction reverted without a reason string');
        });

        it('... should shift from WETH/LUSD to WSETH/LUSD when debt is greater than half of liquidity', async () => {
            const troveInfo = await createLiquityPosWithDebtGtThanHalfOfLiquidityOnAaveV3();
            const recipeWithNewFLAction = new dfs.Recipe('Shift', [
                actions.flAaveV3ActionWithDeptPosition(troveInfo.debtAmount),
                actions.liquityCloseAction(),
                actions.lidoWrapAction(troveInfo.collAmount),
                actions.aaveV3SupplyAction(),
                actions.delegateCreditOnAaveV3Action(),
                actions.sendTokenActionCleanUpProxy(),
            ]);

            const functionData = recipeWithNewFLAction.encodeForDsProxyCall();
            await executeAction('RecipeExecutor', functionData[1], proxy);

            const newTroveInfo = await getTroveInfo(proxyAddr);
            expect(newTroveInfo.troveStatus).to.equal(2); // 2 for closedByOwner status
            expect(newTroveInfo.collAmount).to.equal(0);
            expect(newTroveInfo.debtAmount).to.equal(0);

            const proxyBalance = await balanceOf(A_WSETH_TOKEN_ADDR, proxyAddr);
            expect(proxyBalance).to.be.gt(0);
        });
    });
};

describe('AaveV3 Shift Tests', function () {
    this.timeout(80000);

    it('... test AaveV3 Shift', async () => {
        await aaveV3Shifter();
    }).timeout(50000);
});
