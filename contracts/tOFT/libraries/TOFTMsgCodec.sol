// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.22;

// Tapioca
import {
    ITOFT,
    MarketRemoveCollateralMsg,
    MarketBorrowMsg,
    ExerciseOptionsMsg,
    SendParamsMsg
} from "tapioca-periph/interfaces/oft/ITOFT.sol";
import {
    YieldBoxApproveAllMsg,
    YieldBoxApproveAssetMsg,
    MarketPermitActionMsg
} from "tapioca-periph/interfaces/periph/ITapiocaOmnichainEngine.sol";
import {ITOFT} from "tapioca-periph/interfaces/oft/ITOFT.sol";

/*

████████╗ █████╗ ██████╗ ██╗ ██████╗  ██████╗ █████╗ 
╚══██╔══╝██╔══██╗██╔══██╗██║██╔═══██╗██╔════╝██╔══██╗
   ██║   ███████║██████╔╝██║██║   ██║██║     ███████║
   ██║   ██╔══██║██╔═══╝ ██║██║   ██║██║     ██╔══██║
   ██║   ██║  ██║██║     ██║╚██████╔╝╚██████╗██║  ██║
   ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝
   
*/

library TOFTMsgCodec {
    // ***************************************
    // * Encoding & Decoding TOFT messages *
    // ***************************************

    /**
     * @notice Encodes the message for the `TOFTMarketReceiverModule.marketBorrowReceiver()` operation.
     */
    function buildMarketBorrow(MarketBorrowMsg memory _marketBorrowMsg) internal pure returns (bytes memory) {
        return abi.encode(_marketBorrowMsg);
    }

    /**
     * @notice Decodes an encoded message for the `TOFTMarketReceiverModule.marketBorrowReceiver()` operation.
     */
    function decodeMarketBorrowMsg(bytes memory _msg) internal pure returns (MarketBorrowMsg memory marketBorrowMsg_) {
        return abi.decode(_msg, (MarketBorrowMsg));
    }

    /**
     * @notice Encodes the message for the `TOFTMarketReceiverModule.marketRemoveCollateralReceiver()` operation.
     */
    function buildMarketRemoveCollateralMsg(MarketRemoveCollateralMsg memory _marketMsg)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_marketMsg);
    }

    /**
     * @notice Decodes an encoded message for the `TOFTMarketReceiverModule.marketRemoveCollateralReceiver()` operation.
     */
    function decodeMarketRemoveCollateralMsg(bytes memory _msg)
        internal
        pure
        returns (MarketRemoveCollateralMsg memory marketMsg_)
    {
        return abi.decode(_msg, (MarketRemoveCollateralMsg));
    }

    /**
     * @notice Encodes the message for the `TOFTOptionsReceiverModule.exerciseOptionsReceiver()` operation.
     */
    function buildExerciseOptionsMsg(ExerciseOptionsMsg memory _marketMsg) internal pure returns (bytes memory) {
        return abi.encode(_marketMsg);
    }

    /**
     * @notice Decodes an encoded message for the `TOFTOptionsReceiverModule.exerciseOptionsReceiver()` operation.
     */
    function decodeExerciseOptionsMsg(bytes memory _msg) internal pure returns (ExerciseOptionsMsg memory marketMsg_) {
        return abi.decode(_msg, (ExerciseOptionsMsg));
    }

    /**
     * @notice Encodes the message for the `TOFTReceiver._receiveWithParams()` operation.
     */
    function buildSendParamsMsg(SendParamsMsg memory _msg) internal pure returns (bytes memory) {
        return abi.encode(_msg);
    }

    /**
     * @notice Decodes an encoded message for the `TOFTReceiver._receiveWithParams()` operation.
     */
    function decodeSendParamsMsg(bytes memory _msg) internal pure returns (SendParamsMsg memory sendMsg_) {
        return abi.decode(_msg, (SendParamsMsg));
    }
}
