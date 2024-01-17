/* eslint-disable array-callback-return */
/* eslint-disable no-param-reassign */
/* eslint-disable max-len */
const { ethers } = require('hardhat');
const { expect } = require('chai');
const sdk = require('@defisaver/sdk');

const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

const {
    impersonateAccount,
    resetForkToBlock,
    placeHolderAddr,
    getAllowance,
    nullAddress,
    MAX_UINT,
    addrs,
    getNetwork,
    getProxy,
    getContractFromRegistry,
    redeploy,
    getGasUsed,
} = require('../../utils');
const { VARIABLE_RATE, getAaveReserveData } = require('../../utils-aave');

const sfProxyAddress = '0x840CFfA2a3a6F56Eb2f205a06748a8284b683355';
const sfProxyLiquidBlock = 18976412;

const sfServiceRegistryAddress = '0x5e81a7515f956ab642eb698821a449fe8fe7498e';
const sfAAVEV3PaybackWithdrawName = 'AAVEV3PaybackWithdraw';
const sfSetApprovalTargetHash = ethers.utils.id('SetApproval_3');
const sfSetApprovalTypes = ['(address asset, address delegate, uint256 amount, bool sumAmounts)'];

const coder = ethers.utils.defaultAbiCoder;

const encodeSfApproveOperation = async (asset, delegate, amount) => {
    const sfServiceRegistry = await ethers.getContractAt('IServiceRegistry', sfServiceRegistryAddress);
    const sfOperationExecutorAddr = await sfServiceRegistry.getRegisteredService('OperationExecutor_2');
    const sfOperationsRegistryAddress = await sfServiceRegistry.getRegisteredService('OperationsRegistry_2');

    const [actions, optionals] = await ethers.getContractAt(
        'IOperationsRegistry',
        sfOperationsRegistryAddress,
    ).then((c) => c.getOperation(sfAAVEV3PaybackWithdrawName));

    const setApprovalIndex = actions.reduce(
        (acc, e, i) => (e === sfSetApprovalTargetHash ? i : acc),
        -1,
    );

    const canIsolateSetApproval = optionals.reduce(
        (acc, e, i) => acc && (e || i === setApprovalIndex),
        true,
    );
    expect(canIsolateSetApproval).to.be.eq(true);

    const calls = actions.map((targetHash) => [targetHash, '0x', true]);

    const executableInterface = await ethers.getContractAt('IExecutable', placeHolderAddr).then((e) => e.interface);
    calls[setApprovalIndex] = [
        sfSetApprovalTargetHash,
        executableInterface.encodeFunctionData('execute', [
            coder.encode(sfSetApprovalTypes, [[asset, delegate, amount, false]]),
            [0, 0, 0],
        ]),
        false,
    ];

    const operationExecutorInterface = await ethers.getContractAt('IOperationExecutor', sfOperationExecutorAddr).then((e) => e.interface);
    return [
        sfOperationExecutorAddr,
        operationExecutorInterface.encodeFunctionData('executeOp', [calls, sfAAVEV3PaybackWithdrawName]),
    ];
};

const createAaveV3ImportRecipeNoPermit = ({
    proxyAddress,
    oasisProxyAddress,
    flAddress,

    collAssetIds,
    collATokenAddresses,
    useAsCollateralFlags,

    emodeCategoryId,
    debtTokenAddresses,
    debtAssetIds,
    debtAmounts,
}) => {
    debtAmounts = debtAmounts.map((e) => e.mul(1_00_01).div(1_00_00));
    const actions = [
        new sdk.actions.flashloan.FLAction(new sdk.actions.flashloan.BalancerFlashLoanAction(
            debtTokenAddresses,
            debtAmounts,
        )),

        // payback actions
        ...debtAssetIds.map((debtAssetId, i) => new sdk.actions.aaveV3.AaveV3PaybackAction(
            true,
            nullAddress,
            MAX_UINT,
            proxyAddress,
            VARIABLE_RATE,
            debtTokenAddresses[i],
            debtAssetId,
            true,
            oasisProxyAddress,
        )),

        // pull actions
        ...collATokenAddresses.map((collATokenAddress) => new sdk.actions.basic.PullTokenAction(
            collATokenAddress, oasisProxyAddress, MAX_UINT,
        )),

        new sdk.actions.aaveV3.AaveV3CollateralSwitchAction(
            true,
            nullAddress,
            collAssetIds.length,
            collAssetIds,
            useAsCollateralFlags,
        ),

        new sdk.actions.aaveV3.AaveV3SetEModeAction(true, nullAddress, emodeCategoryId),

        // borrow actions go her
        ...debtAssetIds.map((debtAssetId, i) => new sdk.actions.aaveV3.AaveV3BorrowAction(
            true,
            nullAddress,
            debtAmounts[i],
            flAddress,
            VARIABLE_RATE,
            debtAssetId,
            false,
        )),
    ];
    return new sdk.Recipe('SummerfiAaveV3ImportNoPermit', actions);
};

const createAaveV3ImportRecipe = ({
    proxyAddress,
    oasisProxyAddress,
    flAddress,

    collAssetIds,
    collATokenAddresses,
    useAsCollateralFlags,
    collAmounts,

    emodeCategoryId,
    debtTokenAddresses,
    debtAssetIds,
    debtAmounts,
}) => {
    debtAmounts = debtAmounts.map((e) => e.mul(1_00_01).div(1_00_00));
    const actions = [
        new sdk.actions.flashloan.FLAction(new sdk.actions.flashloan.BalancerFlashLoanAction(
            debtTokenAddresses,
            debtAmounts,
        )),

        // payback actions
        ...debtAssetIds.map((debtAssetId, i) => new sdk.actions.aaveV3.AaveV3PaybackAction(
            true,
            nullAddress,
            MAX_UINT,
            proxyAddress,
            VARIABLE_RATE,
            debtTokenAddresses[i],
            debtAssetId,
            true,
            oasisProxyAddress,
        )),

        new sdk.actions.summerfi.SFApproveTokensAction(
            oasisProxyAddress,
            proxyAddress,
            collATokenAddresses,
            collAmounts.map((e) => e.mul(100_01).div(100_00)),
        ),

        // pull actions
        ...collATokenAddresses.map((collATokenAddress) => new sdk.actions.basic.PullTokenAction(
            collATokenAddress, oasisProxyAddress, MAX_UINT,
        )),

        new sdk.actions.aaveV3.AaveV3CollateralSwitchAction(
            true,
            nullAddress,
            collAssetIds.length,
            collAssetIds,
            useAsCollateralFlags,
        ),

        new sdk.actions.aaveV3.AaveV3SetEModeAction(true, nullAddress, emodeCategoryId),

        // borrow actions go her
        ...debtAssetIds.map((debtAssetId, i) => new sdk.actions.aaveV3.AaveV3BorrowAction(
            true,
            nullAddress,
            debtAmounts[i],
            flAddress,
            VARIABLE_RATE,
            debtAssetId,
            false,
        )),
    ];
    return new sdk.Recipe('SummerfiAaveV3Import', actions);
};

const getPositionInfo = async (user) => {
    const market = addrs[getNetwork()].AAVE_MARKET;
    const pool = await ethers.getContractAt('IPoolAddressesProvider', market).then((c) => ethers.getContractAt('IPoolV3', c.getPool()));
    const view = await getContractFromRegistry('AaveV3View');

    const {
        eMode: emodeCategoryId,
        collAddr,
        enabledAsColl,
        borrowAddr,
    } = await view.getLoanData(market, user);

    const collTokenAddresses = collAddr.filter((e) => e !== nullAddress);
    const useAsCollateralFlags = enabledAsColl.slice(0, collTokenAddresses.length);
    const debtTokenAddresses = borrowAddr.filter((e) => e !== nullAddress);

    const {
        collAssetIds,
        collATokenAddresses,
    } = await Promise.all(
        collTokenAddresses.map(async (c) => getAaveReserveData(pool, c)),
    ).then((arr) => arr.reduce((acc, { id, aTokenAddress }) => ({
        collAssetIds: [...acc.collAssetIds, id],
        collATokenAddresses: [...acc.collATokenAddresses, aTokenAddress],
    }), ({
        collAssetIds: [],
        collATokenAddresses: [],
    })));

    const {
        debtAssetIds,
    } = await Promise.all(
        debtTokenAddresses.map(async (c) => getAaveReserveData(pool, c)),
    ).then((arr) => arr.reduce((acc, { id }) => ({
        debtAssetIds: [...acc.debtAssetIds, id],
    }), ({
        debtAssetIds: [],
    })));

    const debtAmounts = await view.getTokenBalances(
        market,
        user,
        debtTokenAddresses,
    ).then((r) => r.map(({ borrowsVariable }) => borrowsVariable));

    const collAmounts = await view.getTokenBalances(
        market,
        user,
        collTokenAddresses,
    ).then((r) => r.map(({ balance }) => balance));

    return {
        collAssetIds,
        collATokenAddresses,
        useAsCollateralFlags,
        collAmounts,

        emodeCategoryId,
        debtTokenAddresses,
        debtAssetIds,
        debtAmounts,
    };
};

const validatePositionShift = (oldPosition, newPosition) => {
    expect(oldPosition.emodeCategoryId).to.be.eq(newPosition.emodeCategoryId);
    oldPosition.collAssetIds.map((e, i) => expect(e).to.be.eq(newPosition.collAssetIds[i]));
    oldPosition.collATokenAddresses.map((e, i) => expect(e).to.be.eq(newPosition.collATokenAddresses[i]));
    oldPosition.useAsCollateralFlags.map((e, i) => expect(e).to.be.eq(newPosition.useAsCollateralFlags[i]));
    oldPosition.debtTokenAddresses.map((e, i) => expect(e).to.be.eq(newPosition.debtTokenAddresses[i]));
    oldPosition.debtAssetIds.map((e, i) => expect(e).to.be.eq(newPosition.debtAssetIds[i]));

    oldPosition.collAmounts.map((e, i) => {
        expect(newPosition.collAmounts[i]).to.be.gte(e);
        expect(newPosition.collAmounts[i].sub(e)).to.be.lte(e.div(100_00));
    });
    oldPosition.debtAmounts.map((e, i) => {
        expect(newPosition.debtAmounts[i]).to.be.gte(e);
        expect(newPosition.debtAmounts[i].sub(e)).to.be.lte(e.div(100_00));
    });
};

describe('Summerfi-AaveV3-Import', function () {
    this.timeout(1_000_000);
    let flAddress;

    const fixture = async () => {
        await resetForkToBlock(sfProxyLiquidBlock);

        await redeploy('SFApproveTokens');
        await getContractFromRegistry('AaveV3View');
        flAddress = await getContractFromRegistry('FLAction').then(({ address }) => address);

        const sfProxy = await ethers.getContractAt('IDSProxy', sfProxyAddress);
        const userAddress = await ethers.getContractAt('IDSProxy', sfProxyAddress).then((e) => e.owner());
        const user = await ethers.getSigner(userAddress);
        const dsProxy = await getProxy(userAddress);
        const dsProxyAddress = dsProxy.address;
        const positionInfo = await getPositionInfo(sfProxyAddress);

        await impersonateAccount(userAddress);

        return {
            sfProxy,
            userAddress,
            user,
            dsProxy,
            dsProxyAddress,
            positionInfo,
        };
    };

    it('...should send approve Txs then execute import recipe', async () => {
        const {
            sfProxy,
            user,
            dsProxy,
            dsProxyAddress,
            positionInfo,
        } = await loadFixture(fixture);

        await Promise.all(positionInfo.collATokenAddresses.map(async (asset, i) => {
            const assetBalance = positionInfo.collAmounts[i].mul(1_00_01).div(1_00_00);
            const encodedSfApproveOperation = await encodeSfApproveOperation(asset, dsProxyAddress, assetBalance);
            const tx = await sfProxy.connect(user).execute(...encodedSfApproveOperation);
            await getGasUsed(tx).then((e) => console.log('Gas used summefi approve:', e));
            expect(await getAllowance(asset, sfProxyAddress, dsProxyAddress)).to.be.eq(assetBalance);
        }));

        const recipe = createAaveV3ImportRecipeNoPermit({
            proxyAddress: dsProxyAddress,
            oasisProxyAddress: sfProxyAddress,
            flAddress,

            ...positionInfo,
        });

        const recipeData = recipe.encodeForDsProxyCall();
        const tx = await dsProxy.connect(user).execute(recipeData[0], recipeData[1]);
        await getGasUsed(tx).then((e) => console.log('Gas used SummerfiAaveV3ImportNoPermit recipe:', e));

        const newPosition = await getPositionInfo(dsProxyAddress);
        validatePositionShift(positionInfo, newPosition);
        console.log({ newPosition });
    });

    it('... should send permit Tx then execute import recipe with SFApproveTokens action', async () => {
        const {
            sfProxy,
            user,
            dsProxy,
            dsProxyAddress,
            positionInfo,
        } = await loadFixture(fixture);

        const guard = await ethers.getContractAt('IAccountGuard', await sfProxy.guard());
        {
            const tx = await guard.connect(user).permit(dsProxyAddress, sfProxyAddress, true);
            await getGasUsed(tx).then((e) => console.log('Gas used summerfi permit:', e));
        }

        const recipe = createAaveV3ImportRecipe({
            proxyAddress: dsProxyAddress,
            oasisProxyAddress: sfProxyAddress,
            flAddress,

            ...positionInfo,
        });

        const recipeData = recipe.encodeForDsProxyCall();
        {
            const tx = await dsProxy.connect(user).execute(recipeData[0], recipeData[1]);
            await getGasUsed(tx).then((e) => console.log('Gas used SummerfiAaveV3Import recipe:', e));
        }

        const newPosition = await getPositionInfo(dsProxyAddress);
        validatePositionShift(positionInfo, newPosition);
        console.log({ newPosition });

        {
            const tx = await guard.connect(user).permit(dsProxyAddress, sfProxyAddress, false);
            await getGasUsed(tx).then((e) => console.log('Gas used summerfi permit:', e));
        }
    });
});

module.exports = {
    createAaveV3ImportRecipeNoPermit,
    createAaveV3ImportRecipe,
};
