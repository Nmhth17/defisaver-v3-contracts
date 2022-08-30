const { expect } = require('chai');
const { withdrawCompV3, supplyCompV3, borrowCompV3 } = require('../actions');
const {
    redeploy,
    WETH_ADDRESS,
    USDC_ADDR,
    balanceOf,
    fetchAmountinUSDPrice,
    getProxy,
    setBalance,
} = require('../utils');

describe('CompV3-Withdraw', function () {
    this.timeout(80000);

    let senderAcc;
    let proxy;

    before(async () => {
        await redeploy('CompV3Supply');
        await redeploy('CompV3Withdraw');
        await redeploy('CompV3Borrow');

        senderAcc = (await hre.ethers.getSigners())[0];
        proxy = await getProxy(senderAcc.address);
    });

    const USDCAmountWithUSD = fetchAmountinUSDPrice('USDC', '1000');
    const WETHAmountWithUSD = fetchAmountinUSDPrice('WETH', '2000');

    it(`... should withdraw ${USDCAmountWithUSD} USDC from CompoundV3`, async () => {
        const amount = hre.ethers.utils.parseUnits(USDCAmountWithUSD, 6);

        await supplyCompV3(proxy, USDC_ADDR, amount, senderAcc.address);

        const balanceBefore = await balanceOf(USDC_ADDR, senderAcc.address);

        // cant withdraw full amount?
        await withdrawCompV3(proxy, senderAcc.address, USDC_ADDR, amount);

        const balanceAfter = await balanceOf(USDC_ADDR, senderAcc.address);

        expect(balanceAfter).to.be.gt(balanceBefore);
    });

    it(`... should withdraw ${WETHAmountWithUSD} WETH from CompoundV3`, async () => {
        const amount = hre.ethers.utils.parseUnits(WETHAmountWithUSD, 18);

        await supplyCompV3(proxy, WETH_ADDRESS, amount, senderAcc.address);

        const balanceBefore = await balanceOf(WETH_ADDRESS, senderAcc.address);

        await withdrawCompV3(proxy, senderAcc.address, WETH_ADDRESS, amount);

        const balanceAfter = await balanceOf(WETH_ADDRESS, senderAcc.address);

        expect(balanceAfter).to.be.gt(balanceBefore);
    });
});
