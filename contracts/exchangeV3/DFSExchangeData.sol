// SPDX-License-Identifier: MIT
pragma solidity =0.8.10;

abstract contract DFSExchangeData {

    // first is empty to keep the legacy order in place
    // EMPTY was _, but in >0.8.x using underscore as name is forbidden
    enum ExchangeType { EMPTY, OASIS, KYBER, UNISWAP, ZEROX }

    struct OffchainData {
        address wrapper;
        address exchangeAddr;
        address allowanceTarget;
        uint256 price;
        uint256 protocolFee;
        bytes callData;
    }

    struct ExchangeData {
        address srcAddr;
        address destAddr;
        uint256 srcAmount;
        uint256 destAmount;
        uint256 minPrice;
        uint256 dfsFeeDivider; // service fee divider
        address user; // user to check special fee
        address wrapper;
        bytes wrapperData;
        OffchainData offchainData;
    }

    function packExchangeData(ExchangeData memory _exData) external pure returns(bytes memory) {
        return abi.encode(_exData);
    }

    function unpackExchangeData(bytes memory _data) external pure returns(ExchangeData memory _exData) {
        _exData = abi.decode(_data, (ExchangeData));
    }
}