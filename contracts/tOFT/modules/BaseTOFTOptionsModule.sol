// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

//LZ
import "tapioca-sdk/dist/contracts/libraries/LzLib.sol";

//TAPIOCA
import "tapioca-periph/contracts/interfaces/IPermitBorrow.sol";
import "tapioca-periph/contracts/interfaces/IPermitAll.sol";
import "tapioca-periph/contracts/interfaces/ITapiocaOptionsBroker.sol";

import "./TOFTCommon.sol";

contract BaseTOFTOptionsModule is TOFTCommon {
    using SafeERC20 for IERC20;

    constructor(
        address _lzEndpoint,
        address _erc20,
        IYieldBoxBase _yieldBox,
        ICluster _cluster,
        string memory _name,
        string memory _symbol,
        uint8 _decimal,
        uint256 _hostChainID
    )
        BaseTOFTStorage(
            _lzEndpoint,
            _erc20,
            _yieldBox,
            _cluster,
            _name,
            _symbol,
            _decimal,
            _hostChainID
        )
    {}

    function exerciseOption(
        ITapiocaOptionsBrokerCrossChain.IExerciseOptionsData memory optionsData,
        ITapiocaOptionsBrokerCrossChain.IExerciseLZData calldata lzData,
        ITapiocaOptionsBrokerCrossChain.IExerciseLZSendTapData
            calldata tapSendData,
        ICommonData.IApproval[] calldata approvals,
        bytes calldata adapterParams
    ) external payable {
        if (tapSendData.tapOftAddress != address(0)) {
            require(
                cluster.isWhitelisted(
                    lzData.lzDstChainId,
                    tapSendData.tapOftAddress
                ),
                "TOFT_UNAUTHORIZED"
            ); //fail fast
        }

        // allowance is also checked on SGL
        // check it here as well because tokens are moved over layers
        if (optionsData.from != msg.sender) {
            require(
                allowance(optionsData.from, msg.sender) >=
                    optionsData.paymentTokenAmount,
                "TOFT_UNAUTHORIZED"
            );
            _spendAllowance(
                optionsData.from,
                msg.sender,
                optionsData.paymentTokenAmount
            );
        }

        bytes32 toAddress = LzLib.addressToBytes32(optionsData.from);

        (uint256 paymentTokenAmount, ) = _removeDust(
            optionsData.paymentTokenAmount
        );
        paymentTokenAmount = _debitFrom(
            optionsData.from,
            lzEndpoint.getChainId(),
            toAddress,
            paymentTokenAmount
        );
        require(paymentTokenAmount > 0, "TOFT_AMOUNT");

        (, , uint256 airdropAmount, ) = LzLib.decodeAdapterParams(
            adapterParams
        );
        bytes memory lzPayload = abi.encode(
            PT_TAP_EXERCISE,
            _ld2sd(paymentTokenAmount),
            optionsData,
            tapSendData,
            approvals,
            airdropAmount
        );

        _checkAdapterParams(
            lzData.lzDstChainId,
            PT_TAP_EXERCISE,
            adapterParams,
            NO_EXTRA_GAS
        );

        _lzSend(
            lzData.lzDstChainId,
            lzPayload,
            payable(optionsData.from),
            lzData.zroPaymentAddress,
            adapterParams,
            msg.value
        );

        emit SendToChain(
            lzData.lzDstChainId,
            optionsData.from,
            toAddress,
            optionsData.paymentTokenAmount
        );
    }
}
