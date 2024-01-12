// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

//OZ
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./BaseTOFTStorage.sol";

//TOFT MODULES
import "./modules/BaseTOFTLeverageModule.sol";
import "./modules/BaseTOFTLeverageDestinationModule.sol";
import "./modules/BaseTOFTMarketModule.sol";
import "./modules/BaseTOFTMarketDestinationModule.sol";
import "./modules/BaseTOFTOptionsModule.sol";
import "./modules/BaseTOFTOptionsDestinationModule.sol";
import "./modules/BaseTOFTGenericModule.sol";
import "./TOFTVault.sol";

import "tapioca-periph/contracts/interfaces/IStargateReceiver.sol";

contract BaseTOFT is BaseTOFTStorage, ERC20Permit, IStargateReceiver {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    // ************ //
    // *** VARS *** //
    // ************ //

    /// @notice returns the leverage module
    BaseTOFTLeverageModule private _leverageModule;
    /// @notice returns the leverage module
    BaseTOFTLeverageDestinationModule private _leverageDestinationModule;

    /// @notice returns the Market module
    BaseTOFTMarketModule private _marketModule;
    /// @notice returns the Market module
    BaseTOFTMarketDestinationModule private _marketDestinationModule;

    /// @notice returns the Options module
    BaseTOFTOptionsModule private _optionsModule;
    /// @notice returns the Options module
    BaseTOFTOptionsDestinationModule private _optionsDestinationModule;

    /// @notice returns the Options module
    BaseTOFTGenericModule private _genericModule;

    /// @notice returns the amount of total wrapped native coins
    uint256 wrappedNativeAmount;

    /// @notice returns the Stargate router address
    address private _stargateRouter;

    TOFTVault public vault;

    struct DestinationCall {
        Module module;
        bytes4 functionSelector;
    }
    // Define a mapping from packetType to destination module and function selector.
    mapping(uint256 => DestinationCall) private _destinationMappings;

    // ************** //
    // *** ERRORS *** //
    // ************** //
    error AllowanceNotValid();
    error Failed();
    error NotAuthorized();
    error NotNative();

    // ******************//
    // *** MODIFIERS *** //
    // ***************** //
    /// @notice Require that the caller is on the host chain of the ERC20.
    modifier onlyHostChain() {
        if (block.chainid != hostChainID) revert NotAuthorized();
        _;
    }

    constructor(
        address _lzEndpoint,
        address _erc20,
        IYieldBoxBase _yieldBox,
        ICluster _cluster,
        string memory _name,
        string memory _symbol,
        uint8 _decimal,
        uint256 _hostChainID,
        BaseTOFTLeverageModule __leverageModule,
        BaseTOFTLeverageDestinationModule __leverageDestinationModule,
        BaseTOFTMarketModule __marketModule,
        BaseTOFTMarketDestinationModule __marketDestinationModule,
        BaseTOFTOptionsModule __optionsModule,
        BaseTOFTOptionsDestinationModule __optionsDestinationModule,
        BaseTOFTGenericModule __genericModule
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
        ERC20Permit(string(abi.encodePacked("TapiocaOFT-", _name)))
    {
        //Set modules
        _leverageModule = __leverageModule;
        _leverageDestinationModule = __leverageDestinationModule;

        _marketModule = __marketModule;
        _marketDestinationModule = __marketDestinationModule;

        _optionsModule = __optionsModule;
        _optionsDestinationModule = __optionsDestinationModule;

        _genericModule = __genericModule;

        //Set modules' addresses
        _moduleAddresses[Module.Generic] = payable(__genericModule);
        _moduleAddresses[Module.Options] = payable(__optionsModule);
        _moduleAddresses[Module.OptionsDestination] = payable(
            __optionsDestinationModule
        );
        _moduleAddresses[Module.Leverage] = payable(__leverageModule);
        _moduleAddresses[Module.LeverageDestination] = payable(
            __leverageDestinationModule
        );
        _moduleAddresses[Module.Market] = payable(__marketModule);
        _moduleAddresses[Module.MarketDestination] = payable(
            __marketDestinationModule
        );

        //Set destination mappings
        _destinationMappings[PT_MARKET_REMOVE_COLLATERAL] = DestinationCall({
            module: Module.MarketDestination,
            functionSelector: BaseTOFTMarketDestinationModule.remove.selector
        });
        _destinationMappings[PT_YB_SEND_SGL_BORROW] = DestinationCall({
            module: Module.MarketDestination,
            functionSelector: BaseTOFTMarketDestinationModule.borrow.selector
        });
        _destinationMappings[PT_LEVERAGE_MARKET_DOWN] = DestinationCall({
            module: Module.LeverageDestination,
            functionSelector: BaseTOFTLeverageDestinationModule
                .leverageDown
                .selector
        });
        _destinationMappings[PT_TAP_EXERCISE] = DestinationCall({
            module: Module.OptionsDestination,
            functionSelector: BaseTOFTOptionsDestinationModule.exercise.selector
        });
        _destinationMappings[PT_TRIGGER_SEND_FROM] = DestinationCall({
            module: Module.Generic,
            functionSelector: BaseTOFTGenericModule.sendFromDestination.selector
        });
        _destinationMappings[PT_APPROVE] = DestinationCall({
            module: Module.Generic,
            functionSelector: BaseTOFTGenericModule.executeApproval.selector
        });
        _destinationMappings[PT_SEND_FROM_PARAMS] = DestinationCall({
            module: Module.Generic,
            functionSelector: BaseTOFTGenericModule
                .executSendFromWithParams
                .selector
        });
        vault = new TOFTVault(_erc20);
    }

    // ********************** //
    // *** VIEW FUNCTIONS *** //
    // ********************** //
    /// @notice decimal number of the ERC20
    function decimals() public view override returns (uint8) {
        if (_decimalCache == 0) return 18; //temporary fix for LZ _sharedDecimals check
        return _decimalCache;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(BaseOFTV2) returns (bool) {
        return
            interfaceId == type(ITapiocaOFT).interfaceId ||
            interfaceId == type(ISendFrom).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    //----Leverage---
    /// @notice sends TOFT to a specific chain and performs a leverage down operation
    /// @param amount the amount to use
    /// @param leverageFor the receiver address
    /// @param lzData LZ specific data
    /// @param swapData ISwapper specific data
    /// @param externalData external contracts used for the flow
    function sendForLeverage(
        uint256 amount,
        address leverageFor,
        IUSDOBase.ILeverageLZData calldata lzData,
        IUSDOBase.ILeverageSwapData calldata swapData,
        IUSDOBase.ILeverageExternalContractsData calldata externalData
    ) external payable {
        _executeModule(
            Module.Leverage,
            abi.encodeWithSelector(
                BaseTOFTLeverageModule.sendForLeverage.selector,
                amount,
                leverageFor,
                lzData,
                swapData,
                externalData
            ),
            false
        );
    }

    //----Market---
    /// @notice calls removeCollateral on another layer
    /// @param from sending address
    /// @param to receiver address
    /// @param lzDstChainId LayerZero destination chain id
    /// @param zroPaymentAddress LayerZero ZRO payment address
    /// @param withdrawParams withdrawTo specific params
    /// @param removeParams removeAsset specific params
    /// @param approvals approvals specific params
    /// @param adapterParams LZ adapter params
    function removeCollateral(
        address from,
        address to,
        uint16 lzDstChainId,
        address zroPaymentAddress,
        ICommonData.IWithdrawParams calldata withdrawParams,
        ITapiocaOFT.IRemoveParams calldata removeParams,
        ICommonData.IApproval[] calldata approvals,
        ICommonData.IApproval[] calldata revokes,
        bytes calldata adapterParams
    ) external payable {
        _executeModule(
            Module.Market,
            abi.encodeWithSelector(
                BaseTOFTMarketModule.removeCollateral.selector,
                from,
                to,
                lzDstChainId,
                zroPaymentAddress,
                withdrawParams,
                removeParams,
                approvals,
                revokes,
                adapterParams
            ),
            false
        );
    }

    /// @notice sends TOFT to a specific chain and performs a borrow operation
    /// @param from the sender address
    /// @param to the receiver address
    /// @param lzDstChainId the destination LayerZero id
    /// @param airdropAdapterParams the LayerZero aidrop adapter params
    /// @param borrowParams the borrow operation data
    /// @param withdrawParams the withdraw operation data
    /// @param options the cross chain send operation data
    /// @param approvals the cross chain approval operation data
    /// @param revokes the cross chain revoke operations data
    function sendToYBAndBorrow(
        address from,
        address to,
        uint16 lzDstChainId,
        bytes calldata airdropAdapterParams,
        ITapiocaOFT.IBorrowParams calldata borrowParams,
        ICommonData.IWithdrawParams calldata withdrawParams,
        ICommonData.ISendOptions calldata options,
        ICommonData.IApproval[] calldata approvals,
        ICommonData.IApproval[] calldata revokes
    ) external payable {
        _executeModule(
            Module.Market,
            abi.encodeWithSelector(
                BaseTOFTMarketModule.sendToYBAndBorrow.selector,
                from,
                to,
                lzDstChainId,
                airdropAdapterParams,
                borrowParams,
                withdrawParams,
                options,
                approvals,
                revokes
            ),
            false
        );
    }

    //----Options---
    /// @notice Exercise an oTAP position
    /// @param optionsData oTap exerciseOptions data
    /// @param lzData data needed for the cross chain transer
    /// @param tapSendData needed for withdrawing Tap token
    /// @param approvals array
    function exerciseOption(
        ITapiocaOptionsBrokerCrossChain.IExerciseOptionsData
            calldata optionsData,
        ITapiocaOptionsBrokerCrossChain.IExerciseLZData calldata lzData,
        ITapiocaOptionsBrokerCrossChain.IExerciseLZSendTapData
            calldata tapSendData,
        ICommonData.IApproval[] calldata approvals,
        ICommonData.IApproval[] calldata revokes,
        bytes calldata adapterParams
    ) external payable {
        _executeModule(
            Module.Options,
            abi.encodeWithSelector(
                BaseTOFTOptionsModule.exerciseOption.selector,
                optionsData,
                lzData,
                tapSendData,
                approvals,
                revokes,
                adapterParams
            ),
            false
        );
    }

    //----Generic---
    /// @notice executes a sendFromWithParams to another layer
    /// @param from address to debit from
    /// @param lzDstChainId LZ destination id
    /// @param to address to credit to
    /// @param amount amount to send back
    /// @param callParams LZ send call params
    /// @param unwrap unwrap or not on destination
    /// @param approvals the cross chain approval operation data
    /// @param revokes the cross chain revoke operations data
    function sendFromWithParams(
        address from,
        uint16 lzDstChainId,
        bytes32 to,
        uint256 amount,
        ICommonOFT.LzCallParams calldata callParams,
        bool unwrap,
        ICommonData.IApproval[] calldata approvals,
        ICommonData.IApproval[] calldata revokes
    ) external payable {
        _executeModule(
            Module.Generic,
            abi.encodeWithSelector(
                BaseTOFTGenericModule.sendFromWithParams.selector,
                from,
                lzDstChainId,
                to,
                amount,
                callParams,
                unwrap,
                approvals,
                revokes
            ),
            false
        );
    }

    /// @notice triggers a cross-chain approval
    /// @dev handled by BaseTOFTGenericModule
    /// @param lzDstChainId LZ destination id
    /// @param lzCallParams data needed to trigger triggerApproveOrRevoke on destination
    /// @param approvals approvals array
    function triggerApproveOrRevoke(
        uint16 lzDstChainId,
        ICommonOFT.LzCallParams calldata lzCallParams,
        ICommonData.IApproval[] calldata approvals
    ) external payable {
        _executeModule(
            Module.Generic,
            abi.encodeWithSelector(
                BaseTOFTGenericModule.triggerApproveOrRevoke.selector,
                lzDstChainId,
                lzCallParams,
                approvals
            ),
            false
        );
    }

    /// @notice triggers a sendFrom to another layer from destination
    /// @param from address to debit from
    /// @param lzDstChainId LZ destination id
    /// @param to address to credit to
    /// @param amount amount to send back
    /// @param sendFromData data needed to trigger sendFrom on destination
    /// @param approvals the cross chain approval operation data
    /// @param revokes the cross chain revoke operations data
    function triggerSendFrom(
        address from,
        uint16 lzDstChainId,
        bytes32 to,
        uint256 amount,
        ICommonOFT.LzCallParams calldata sendFromData,
        ICommonData.IApproval[] calldata approvals,
        ICommonData.IApproval[] calldata revokes
    ) external payable {
        _executeModule(
            Module.Generic,
            abi.encodeWithSelector(
                BaseTOFTGenericModule.triggerSendFrom.selector,
                from,
                lzDstChainId,
                to,
                amount,
                sendFromData,
                approvals,
                revokes
            ),
            false
        );
    }

    /// @notice needed for Stargate Router to receive funds from Balancer.sol contract
    function sgReceive(
        uint16,
        bytes memory,
        uint,
        address,
        uint amountLD,
        bytes memory
    ) external payable {
        if (msg.sender != _stargateRouter) revert NotAuthorized();

        if (erc20 == address(0)) {
            vault.depositNative{value: amountLD}();
        } else {
            IERC20(erc20).safeTransfer(address(vault), amountLD);
        }
    }

    //----OFT---
    function retryMessage(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public payable virtual override {
        // assert there is message to retry
        bytes32 payloadHash = failedMessages[_srcChainId][_srcAddress][_nonce];
        require(
            payloadHash != bytes32(0),
            "NonblockingLzApp: no stored message"
        );
        require(
            keccak256(_payload) == payloadHash,
            "NonblockingLzApp: invalid payload"
        );
        // clear the stored message
        failedMessages[_srcChainId][_srcAddress][_nonce] = bytes32(0);
        // execute the message. revert if it fails again
        _callSelfAndRevertOnError(_srcChainId, _srcAddress, _nonce, _payload);
        emit RetryMessageSuccess(_srcChainId, _srcAddress, _nonce, payloadHash);
    }

    function retryMessageWithSafeCall(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        (bool success, bytes memory reason) = _excessivelySafeCall(
            address(this),
            gasleft(),
            0,
            150,
            abi.encodeWithSelector(
                this.nonblockingLzReceive.selector,
                _srcChainId,
                _srcAddress,
                _nonce,
                _payload
            )
        );
        if (!success) {
            revert(_getRevertMsg(reason));
        }
    }

    // ************************ //
    // *** OWNER FUNCTIONS *** //
    // ************************ //
    /// @notice updates the cluster address
    /// @dev can only be called by the owner
    /// @param _cluster the new address
    function setCluster(ICluster _cluster) external {
        if (address(_cluster) == address(0)) revert NotValid();
        cluster = _cluster;
    }

    /// @notice rescues unused ETH from the contract
    /// @param amount the amount to rescue
    /// @param to the recipient
    function rescueEth(uint256 amount, address to) external onlyOwner {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert Failed();
    }

    /// @notice sets the StargateRouter address
    /// @param _router the router address
    function setStargateRouter(address _router) external onlyOwner {
        emit StargateRouterUpdated(_stargateRouter, _router);
        _stargateRouter = _router;
    }

    // ************************* //
    // *** PRIVATE FUNCTIONS *** //
    // ************************* //

    //---internal-
    function _wrap(
        address _fromAddress,
        address _toAddress,
        uint256 _amount,
        uint256 _feeAmount
    ) internal virtual {
        if (_fromAddress != msg.sender) {
            if (allowance(_fromAddress, msg.sender) < _amount)
                revert AllowanceNotValid();
            _spendAllowance(_fromAddress, msg.sender, _amount);
        }
        if (_amount == 0) revert NotValid();
        IERC20(erc20).safeTransferFrom(_fromAddress, address(vault), _amount);
        _mint(_toAddress, _amount - _feeAmount);
    }

    function _wrapNative(
        address _toAddress,
        uint256 _amount,
        uint256 _feeAmount
    ) internal virtual {
        vault.depositNative{value: _amount}();
        _mint(_toAddress, _amount - _feeAmount);
    }

    function _unwrap(address _toAddress, uint256 _amount) internal virtual {
        _burn(msg.sender, _amount);
        vault.withdraw(_toAddress, _amount);
    }

    //---private---
    function _extractModule(Module _module) private view returns (address) {
        address module = _moduleAddresses[_module];
        if (module == address(0)) revert NotValid();
        return module;
    }

    function _executeModule(
        Module _module,
        bytes memory _data,
        bool _forwardRevert
    ) private returns (bool success, bytes memory returnData) {
        success = true;
        address module = _extractModule(_module);

        (success, returnData) = module.delegatecall(_data);
        if (!success && !_forwardRevert) {
            revert(_getRevertMsg(returnData));
        }
    }

    function _executeOnDestination(
        Module _module,
        bytes memory _data,
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) private {
        (bool success, bytes memory returnData) = _executeModule(
            _module,
            _data,
            true
        );
        if (!success) {
            _storeFailedMessage(
                _srcChainId,
                _srcAddress,
                _nonce,
                _payload,
                returnData
            );
        }
    }

    //---LZ---
    function _callSelfAndRevertOnError(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) internal {
        (bool success, bytes memory reason) = _excessivelySafeCall(
            address(this),
            gasleft(),
            0,
            150,
            abi.encodeWithSelector(
                this.retryMessageWithSafeCall.selector,
                _srcChainId,
                _srcAddress,
                _nonce,
                _payload
            )
        );
        if (!success) {
            revert(_getRevertMsg(reason));
        }
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual override {
        uint256 packetType = _payload.toUint256(0);

        if (_destinationMappings[packetType].module != Module(0)) {
            DestinationCall memory callInfo = _destinationMappings[packetType];
            address targetModule;
            if (callInfo.module == Module.MarketDestination) {
                targetModule = address(_marketDestinationModule);
            } else if (callInfo.module == Module.LeverageDestination) {
                targetModule = address(_leverageDestinationModule);
            } else if (callInfo.module == Module.OptionsDestination) {
                targetModule = address(_optionsDestinationModule);
            } else if (callInfo.module == Module.Generic) {
                targetModule = address(_genericModule);
            } else {
                targetModule = address(0);
            }

            _executeOnDestination(
                callInfo.module,
                abi.encodeWithSelector(
                    callInfo.functionSelector,
                    targetModule,
                    _srcChainId,
                    _srcAddress,
                    _nonce,
                    _payload
                ),
                _srcChainId,
                _srcAddress,
                _nonce,
                _payload
            );
        } else {
            packetType = _payload.toUint8(0);
            if (packetType == PT_SEND) {
                _sendAck(_srcChainId, _srcAddress, _nonce, _payload);
            } else if (packetType == PT_SEND_AND_CALL) {
                _sendAndCallAck(_srcChainId, _srcAddress, _nonce, _payload);
            } else {
                revert("TOFT_packet");
            }
        }
    }

    /// @notice Use when you _really_ really _really_ don't trust the called
    /// contract. This prevents the called contract from causing reversion of
    /// the caller in as many ways as we can.
    /// @dev The main difference between this and a solidity low-level call is
    /// that we limit the number of bytes that the callee can cause to be
    /// copied to caller memory. This prevents stupid things like malicious
    /// contracts returning 10,000,000 bytes causing a local OOG when copying
    /// to memory.
    /// @param _target The address to call
    /// @param _gas The amount of gas to forward to the remote contract
    /// @param _value The value in wei to send to the remote contract
    /// @param _maxCopy The maximum number of bytes of returndata to copy
    /// to memory.
    /// @param _calldata The data to send to the remote contract
    /// @return success and returndata, as `.call()`. Returndata is capped to
    /// `_maxCopy` bytes.
    function _excessivelySafeCall(
        address _target,
        uint256 _gas,
        uint256 _value,
        uint16 _maxCopy,
        bytes memory _calldata
    ) private returns (bool, bytes memory) {
        // set up for assembly call
        uint256 _toCopy;
        bool _success;
        bytes memory _returnData = new bytes(_maxCopy);
        // dispatch message to recipient
        // by assembly calling "handle" function
        // we call via assembly to avoid memcopying a very large returndata
        // returned by a malicious contract
        assembly {
            _success := call(
                _gas, // gas
                _target, // recipient
                _value, // ether value
                add(_calldata, 0x20), // inloc
                mload(_calldata), // inlen
                0, // outloc
                0 // outlen
            )
            // limit our copy to 256 bytes
            _toCopy := returndatasize()
            if gt(_toCopy, _maxCopy) {
                _toCopy := _maxCopy
            }
            // Store the length of the copied bytes
            mstore(_returnData, _toCopy)
            // copy the bytes from returndata[0:_toCopy]
            returndatacopy(add(_returnData, 0x20), 0, _toCopy)
        }
        return (_success, _returnData);
    }
}
