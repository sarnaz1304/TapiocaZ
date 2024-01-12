// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "./tOFT/TapiocaOFT.sol";
import "./tOFT/mTapiocaOFT.sol";
import "tapioca-periph/contracts/interfaces/ITapiocaOFT.sol";

import "@openzeppelin/contracts/utils/Create2.sol";

import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";

contract TapiocaWrapper is BoringOwnable {
    struct ExecutionCall {
        address toft;
        uint256 value;
        bytes bytecode;
        bool revertOnFailure;
    }

    // ************ //
    // *** VARS *** //
    // ************ //
    /// @notice Array of deployed TOFT contracts.
    ITapiocaOFT[] public tapiocaOFTs;
    /// @notice Map of deployed TOFT contracts by ERC20.
    mapping(address => ITapiocaOFT) public tapiocaOFTsByErc20;

    // ************** //
    // *** EVENTS *** //
    // ************** //
    /// @notice Called when a new OFT is deployed.
    event CreateOFT(ITapiocaOFT indexed _tapiocaOFT, address indexed _erc20);
    /// @notice Emitted when ETH refund fails in batch call
    event RefundFailed(uint256 indexed amount);

    // ************** //
    // *** ERRORS *** //
    // ************** //
    /// @notice If the TOFT is already deployed.
    error TapiocaWrapper__AlreadyDeployed(address _erc20);
    /// @notice Failed to deploy the TapiocaWrapper contract.
    error TapiocaWrapper__FailedDeploy();

    /// @notice The TapiocaOFT execution failed.
    error TapiocaWrapper__TOFTExecutionFailed(bytes message);
    /// @notice No TOFT has been deployed yet.
    error TapiocaWrapper__NoTOFTDeployed();
    /// @notice Not enough provided
    error TapiocaWrapper__NotEnough();

    constructor(address _owner) {
        owner = _owner;
    }

    // ********************** //
    // *** VIEW FUNCTIONS *** //
    // ********************** //
    /// @notice Return the number of TOFT contracts deployed on the current chain.
    function tapiocaOFTLength() external view returns (uint256) {
        return tapiocaOFTs.length;
    }

    /// @notice Return the latest TOFT contract deployed on the current chain.
    function lastTOFT() external view returns (ITapiocaOFT) {
        if (tapiocaOFTs.length == 0) {
            revert TapiocaWrapper__NoTOFTDeployed();
        }
        return tapiocaOFTs[tapiocaOFTs.length - 1];
    }

    // *********************** //
    // *** OWNER FUNCTIONS *** //
    // *********************** //

    /// @notice Execute the `_bytecode` against the `_toft`. Callable only by the owner.
    /// @dev Used to call derived OFT functions to a TOFT contract.
    /// @param _toft The TOFT contract to execute against.
    /// @param _bytecode The executable bytecode of the TOFT contract.
    /// @param _revertOnFailure Whether to revert on failure.
    /// @return success If the execution was successful.
    /// @return result The error message if the execution failed.
    function executeTOFT(
        address _toft,
        bytes calldata _bytecode,
        bool _revertOnFailure
    ) external payable onlyOwner returns (bool success, bytes memory result) {
        (success, result) = payable(_toft).call{value: msg.value}(_bytecode);
        if (_revertOnFailure && !success) {
            revert TapiocaWrapper__TOFTExecutionFailed(result);
        }
    }

    /// @notice Execute the `_bytecode` against the `_toft`. Callable only by the owner.
    /// @dev Used to call derived OFT functions to a TOFT contract.
    /// @param _call The array calls to do.
    /// @return success If the execution was successful.
    /// @return results The message of the execution, could be an error message.
    function executeCalls(
        ExecutionCall[] calldata _call
    )
        external
        payable
        onlyOwner
        returns (bool success, bytes[] memory results)
    {
        uint256 valAccumulator = 0;
        uint256 totalVal = msg.value;
        results = new bytes[](_call.length);
        for (uint256 i = 0; i < _call.length; i++) {
            valAccumulator += _call[i].value;

            (success, results[i]) = payable(_call[i].toft).call{
                value: _call[i].value
            }(_call[i].bytecode);
            if (_call[i].revertOnFailure && !success) {
                revert TapiocaWrapper__TOFTExecutionFailed(results[i]);
            }
        }
        if (valAccumulator > totalVal) {
            revert TapiocaWrapper__NotEnough();
        }
        if (totalVal > valAccumulator) {
            //try to refund in ETH amount was bigger
            //nothing happens if this reverts
            (bool s, ) = msg.sender.call{value: totalVal - valAccumulator}("");
            if (!s) emit RefundFailed(totalVal - valAccumulator);
        }
    }

    /// @notice Deploy a new TOFT contract. Callable only by the owner.
    /// @param _erc20 The ERC20 to wrap.
    /// @param _bytecode The executable bytecode of the TOFT contract.
    /// @param _salt Create2 salt.
    function createTOFT(
        address _erc20,
        bytes calldata _bytecode,
        bytes32 _salt,
        bool _linked
    ) external onlyOwner {
        if (address(tapiocaOFTsByErc20[_erc20]) != address(0x0)) {
            revert TapiocaWrapper__AlreadyDeployed(_erc20);
        }

        ITapiocaOFT iOFT = ITapiocaOFT(
            _createTOFT(_erc20, _bytecode, _salt, _linked)
        );
        if (address(iOFT.erc20()) != _erc20) {
            revert TapiocaWrapper__FailedDeploy();
        }

        tapiocaOFTs.push(iOFT);
        tapiocaOFTsByErc20[_erc20] = iOFT;

        emit CreateOFT(iOFT, _erc20);
    }

    // ************************* //
    // *** PRIVATE FUNCTIONS *** //
    // ************************* //
    function _createTOFT(
        address _erc20,
        bytes calldata _bytecode,
        bytes32 _salt,
        bool _linked
    ) private returns (address) {
        address oft;
        if (!_linked) {
            TapiocaOFT toft = TapiocaOFT(
                payable(
                    Create2.deploy(
                        0,
                        keccak256(
                            abi.encodePacked(
                                keccak256(_bytecode),
                                address(this),
                                _erc20,
                                _salt
                            )
                        ),
                        _bytecode
                    )
                )
            );
            oft = address(toft);
        } else {
            mTapiocaOFT toft = mTapiocaOFT(
                payable(
                    Create2.deploy(
                        0,
                        keccak256(
                            abi.encodePacked(
                                keccak256(_bytecode),
                                address(this),
                                _erc20,
                                _salt
                            )
                        ),
                        _bytecode
                    )
                )
            );
            oft = address(toft);
        }
        return oft;
    }
}
