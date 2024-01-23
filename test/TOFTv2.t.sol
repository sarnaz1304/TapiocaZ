// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.22;

// LZ
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {BytesLib} from "solidity-bytes-utils/contracts/BytesLib.sol";
import {Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

// External
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Tapioca
import {
    ITOFTv2,
    LZSendParam,
    ERC20PermitStruct,
    ERC20PermitApprovalMsg,
    RemoteTransferMsg,
    TOFTInitStruct,
    TOFTModulesInitStruct,
    MarketBorrowMsg
} from "contracts/ITOFTv2.sol";
import {
    TOFTv2Helper,
    PrepareLzCallData,
    PrepareLzCallReturn,
    ComposeMsgData
} from "contracts/extensions/TOFTv2Helper.sol";
import {ERC20WithoutStrategy} from "tapioca-sdk/src/contracts/YieldBox/contracts/strategies/ERC20WithoutStrategy.sol";
import {TOFTv2MarketReceiverModule} from "contracts/modules/TOFTv2MarketReceiverModule.sol";
import {TOFTv2OptionsReceiverModule} from "contracts/modules/TOFTv2OptionsReceiverModule.sol";
import {YieldBox} from "tapioca-sdk/src/contracts/YieldBox/contracts/YieldBox.sol";
import {ITapiocaOFT} from "tapioca-periph/contracts/interfaces/ITapiocaOFT.sol";
import {ICommonData} from "tapioca-periph/contracts/interfaces/ICommonData.sol";
// import {MagnetarV2} from "../tapioca-periph/contracts/Magnetar/MagnetarV2.sol";
import {Cluster} from "../tapioca-periph/contracts/Cluster/Cluster.sol";
import {TOFTv2Receiver} from "contracts/modules/TOFTv2Receiver.sol";
import {TOFTMsgCoder} from "contracts/libraries/TOFTMsgCoder.sol";
import {TOFTv2Sender} from "contracts/modules/TOFTv2Sender.sol";

// Tapioca Tests
import {TOFTTestHelper} from "./TOFTTestHelper.t.sol";
import {SingularityMock} from "./SingularityMock.sol";
import {MagnetarMock} from "./MagnetarMock.sol";
import {ERC721Mock} from "./ERC721Mock.sol";
import {TOFTv2Mock} from "./TOFTv2Mock.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

import "forge-std/Test.sol";


contract TOFTv2Test is TOFTTestHelper {
    using OptionsBuilder for bytes;
    using OFTMsgCodec for bytes32;
    using OFTMsgCodec for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    YieldBox yieldBox;
    Cluster cluster;
    ERC20Mock aERC20;
    ERC20Mock bERC20;
    TOFTv2Mock aTOFT;
    TOFTv2Mock bTOFT;
    // MagnetarV2 magnetar;
    MagnetarMock magnetar;
    SingularityMock singularity;

    TOFTv2Helper tOFTv2Helper;

    uint256 aTOFTYieldBoxId;
    uint256 bTOFTYieldBoxId;

    uint256 internal userAPKey = 0x1;
    uint256 internal userBPKey = 0x2;
    address public userA = vm.addr(userAPKey);
    address public userB = vm.addr(userBPKey);
    uint256 public initialBalance = 100 ether;


    /**
     * DEPLOY setup addresses
     */
    address __endpoint;
    uint256 __hostEid = aEid;
    address __owner = address(this);

    uint16 internal constant SEND = 1; // Send LZ message type
    uint16 internal constant PT_REMOTE_TRANSFER = 400; // Use for transferring tokens from the contract from another chain
    uint16 internal constant PT_APPROVALS = 500; // Use for ERC20Permit approvals
    uint16 internal constant PT_YB_APPROVE_ASSET = 501; // Use for YieldBox 'setApprovalForAsset(true)' operation
    uint16 internal constant PT_YB_APPROVE_ALL = 502; // Use for YieldBox 'setApprovalForAll(true)' operation
    uint16 internal constant PT_MARKET_PERMIT = 503; // Use for market.permitLend() operation
    uint16 internal constant PT_MARKET_REMOVE_COLLATERAL = 700; // Use for remove collateral from a market available on another chain
    uint16 internal constant PT_YB_SEND_SGL_BORROW = 701; // Use fror send to YB and/or borrow from a market available on another chain
    uint16 internal constant PT_LEVERAGE_MARKET_DOWN = 702; // Use for leverage sell on a market available on another chain
    uint16 internal constant PT_TAP_EXERCISE = 703; // Use for exercise options on tOB available on another chain
    uint16 internal constant PT_SEND_PARAMS = 704; // Use for perform a normal OFT send but with a custom payload

     /**
     * @dev TOFTv2 global event checks
     */
    event OFTReceived(bytes32, address, uint256, uint256);
    event ComposeReceived(uint16 indexed msgType, bytes32 indexed guid, bytes composeMsg);

     /**
     * @dev Setup the OApps by deploying them and setting up the endpoints.
     */
    function setUp() public override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.label(userA, "userA");
        vm.label(userB, "userB");

        aERC20 = new ERC20Mock("Token A", "TNKA");
        bERC20 = new ERC20Mock("Token B", "TNKB");

        setUpEndpoints(3, LibraryType.UltraLightNode);

        yieldBox = createYieldBox();
        cluster = createCluster(aEid, __owner);
        magnetar = createMagnetar(address(cluster));

        {
            vm.label(address(endpoints[aEid]), "aEndpoint");
            vm.label(address(endpoints[bEid]), "bEndpoint");
            vm.label(address(yieldBox), "YieldBox");
            vm.label(address(cluster), "Cluster");
            vm.label(address(magnetar), "Magnetar");
        }
        
        TOFTInitStruct memory aTOFTInitStruct = createInitStruct("Token A", "TNKA", address(endpoints[aEid]), __owner, address(yieldBox), address(cluster), address(aERC20), aEid);
        TOFTv2Sender aTOFTv2Sender = new TOFTv2Sender(aTOFTInitStruct);
        TOFTv2Receiver aTOFTv2Receiver = new TOFTv2Receiver(aTOFTInitStruct);
        TOFTv2MarketReceiverModule aTOFTv2MarketReceiverModule = new TOFTv2MarketReceiverModule(aTOFTInitStruct);
        TOFTv2OptionsReceiverModule aTOFTv2OptionsReceiverModule = new TOFTv2OptionsReceiverModule(aTOFTInitStruct);
        vm.label(address(aTOFTv2Sender), "aTOFTv2Sender");
        vm.label(address(aTOFTv2Receiver), "aTOFTv2Receiver");
        vm.label(address(aTOFTv2MarketReceiverModule), "aTOFTv2MarketReceiverModule");
        vm.label(address(aTOFTv2OptionsReceiverModule), "aTOFTv2OptionsReceiverModule");
        TOFTModulesInitStruct memory aTOFTModulesInitStruct = createModulesInitStruct(address(aTOFTv2Sender), address(aTOFTv2Receiver), address(aTOFTv2MarketReceiverModule), address(aTOFTv2MarketReceiverModule));
        aTOFT = TOFTv2Mock(
            payable(
                _deployOApp(
                    type(TOFTv2Mock).creationCode,
                    abi.encode(aTOFTInitStruct, aTOFTModulesInitStruct)
                )
            )
        );
        vm.label(address(aTOFT), "aTOFT");

        TOFTInitStruct memory bTOFTInitStruct = createInitStruct("Token B", "TNKB", address(endpoints[bEid]), __owner, address(yieldBox), address(cluster), address(bERC20), bEid);
        TOFTv2Sender bTOFTv2Sender = new TOFTv2Sender(bTOFTInitStruct);
        TOFTv2Receiver bTOFTv2Receiver = new TOFTv2Receiver(bTOFTInitStruct);
        TOFTv2MarketReceiverModule bTOFTv2MarketReceiverModule = new TOFTv2MarketReceiverModule(bTOFTInitStruct);
        TOFTv2OptionsReceiverModule bTOFTv2OptionsReceiverModule = new TOFTv2OptionsReceiverModule(bTOFTInitStruct);
        vm.label(address(bTOFTv2Sender), "bTOFTv2Sender");
        vm.label(address(bTOFTv2Receiver), "bTOFTv2Receiver");
        vm.label(address(bTOFTv2MarketReceiverModule), "bTOFTv2MarketReceiverModule");
        vm.label(address(bTOFTv2OptionsReceiverModule), "bTOFTv2OptionsReceiverModule");
        TOFTModulesInitStruct memory bTOFTModulesInitStruct = createModulesInitStruct(address(bTOFTv2Sender), address(bTOFTv2Receiver), address(bTOFTv2MarketReceiverModule), address(bTOFTv2OptionsReceiverModule));
        bTOFT = TOFTv2Mock(
            payable(
                _deployOApp(
                    type(TOFTv2Mock).creationCode,
                    abi.encode(bTOFTInitStruct, bTOFTModulesInitStruct)
                )
            )
        );
        vm.label(address(bTOFT), "bTOFT");

        tOFTv2Helper = new TOFTv2Helper();
        vm.label(address(tOFTv2Helper), "TOFTv2Helper");

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aTOFT);
        ofts[1] = address(bTOFT);
        this.wireOApps(ofts);

        // Setup YieldBox assets
        ERC20WithoutStrategy aTOFTStrategy = createYieldBoxEmptyStrategy(address(yieldBox), address(aTOFT));
        ERC20WithoutStrategy bTOFTStrategy = createYieldBoxEmptyStrategy(address(yieldBox), address(bTOFT));

        aTOFTYieldBoxId = registerYieldBoxAsset(address(yieldBox), address(aTOFT), address(aTOFTStrategy)); //we assume this is the asset Id
        bTOFTYieldBoxId = registerYieldBoxAsset(address(yieldBox), address(bTOFT), address(bTOFTStrategy)); //we assume this is the collateral Id

        singularity = createSingularity(address(yieldBox), bTOFTYieldBoxId, aTOFTYieldBoxId, address(bTOFT), address(aTOFT));
        vm.label(address(singularity), "Singularity");

        cluster.updateContract(aEid, address(singularity), true);
        cluster.updateContract(aEid, address(magnetar), true);
        cluster.updateContract(bEid, address(singularity), true);
        cluster.updateContract(bEid, address(magnetar), true);
    }

       /**
     * =================
     *      HELPERS
     * =================
     */

    /**
     * @dev Used to bypass stack too deep
     *
     * @param msgType The message type of the lz Compose.
     * @param guid The message GUID.
     * @param composeMsg The source raw OApp compose message. If compose msg is composed with other msgs,
     * the msg should contain only the compose msg at its index and forward. I.E composeMsg[currentIndex:]
     * @param dstEid The destination EID.
     * @param from The address initiating the composition, typically the OApp where the lzReceive was called.
     * @param to The address of the lzCompose receiver.
     * @param srcMsgSender The address of src EID OFT `msg.sender` call initiator .
     * @param extraOptions The options passed in the source OFT call. Only restriction is to have it contain the actual compose option for the index,
     * whether there are other composed calls or not.
     */
    struct LzOFTComposedData {
        uint16 msgType;
        bytes32 guid;
        bytes composeMsg;
        uint32 dstEid;
        address from;
        address to;
        address srcMsgSender;
        bytes extraOptions;
    }
     /**
     * @notice Call lzCompose on the destination OApp.
     *
     * @dev Be sure to verify the message by calling `TestHelper.verifyPackets()`.
     * @dev Will internally verify the emission of the `ComposeReceived` event with
     * the right msgType, GUID and lzReceive composer message.
     *
     * @param _lzOFTComposedData The data to pass to the lzCompose call.
     */
    function __callLzCompose(LzOFTComposedData memory _lzOFTComposedData) internal {
        vm.expectEmit(true, true, true, false);
        emit ComposeReceived(_lzOFTComposedData.msgType, _lzOFTComposedData.guid, _lzOFTComposedData.composeMsg);

        this.lzCompose(
            _lzOFTComposedData.dstEid,
            _lzOFTComposedData.from,
            _lzOFTComposedData.extraOptions,
            _lzOFTComposedData.guid,
            _lzOFTComposedData.to,
            abi.encodePacked(
                OFTMsgCodec.addressToBytes32(_lzOFTComposedData.srcMsgSender), _lzOFTComposedData.composeMsg
            )
        );
    }



    function test_constructor() public {
        assertEq(address(aTOFT.yieldBox()), address(yieldBox));
        assertEq(address(aTOFT.cluster()), address(cluster));
        assertEq(address(aTOFT.erc20()), address(aERC20));
        assertEq(aTOFT.hostEid(), aEid);
     }

      function test_erc20_permit() public {
        ERC20PermitStruct memory permit_ =
            ERC20PermitStruct({owner: userA, spender: userB, value: 1e18, nonce: 0, deadline: 1 days});

        bytes32 digest_ = aTOFT.getTypedDataHash(permit_);
        ERC20PermitApprovalMsg memory permitApproval_ =
            __getERC20PermitData(permit_, digest_, address(aTOFT), userAPKey);

        aTOFT.permit(
            permit_.owner,
            permit_.spender,
            permit_.value,
            permit_.deadline,
            permitApproval_.v,
            permitApproval_.r,
            permitApproval_.s
        );
        assertEq(aTOFT.allowance(userA, userB), 1e18);
        assertEq(aTOFT.nonces(userA), 1);
    }

    /**
     * ERC20 APPROVALS
     */
    function test_tOFT_erc20_approvals() public {
        address userC_ = vm.addr(0x3);

        ERC20PermitApprovalMsg memory permitApprovalB_;
        ERC20PermitApprovalMsg memory permitApprovalC_;
        bytes memory approvalsMsg_;

        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: 1e18, nonce: 0, deadline: 1 days});
            ERC20PermitStruct memory approvalUserC_ = ERC20PermitStruct({
                owner: userA,
                spender: userC_,
                value: 2e18,
                nonce: 1, // Nonce is 1 because we already called permit() on userB
                deadline: 2 days
            });

            permitApprovalB_ = __getERC20PermitData(
                approvalUserB_, bTOFT.getTypedDataHash(approvalUserB_), address(bTOFT), userAPKey
            );

            permitApprovalC_ = __getERC20PermitData(
                approvalUserC_, bTOFT.getTypedDataHash(approvalUserC_), address(bTOFT), userAPKey
            );

            ERC20PermitApprovalMsg[] memory approvals_ = new ERC20PermitApprovalMsg[](2);
            approvals_[0] = permitApprovalB_;
            approvals_[1] = permitApprovalC_;

            approvalsMsg_ = tOFTv2Helper.buildPermitApprovalMsg(approvals_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = tOFTv2Helper.prepareLzCall(
            ITOFTv2(address(aTOFT)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                refundAddress: address(this),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_APPROVALS,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalsMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aTOFT.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bTOFT));

        vm.expectEmit(true, true, true, false);
        emit IERC20.Approval(userA, userB, 1e18);

        vm.expectEmit(true, true, true, false);
        emit IERC20.Approval(userA, userC_, 1e18);

        __callLzCompose(
            LzOFTComposedData(
                PT_APPROVALS,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bTOFT), // Compose creator (at lzReceive)
                address(bTOFT), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(bTOFT.allowance(userA, userB), 1e18);
        assertEq(bTOFT.allowance(userA, userC_), 2e18);
        assertEq(bTOFT.nonces(userA), 2);
    }
    
    function test_remote_transfer() public {
        // vars
        uint256 tokenAmount_ = 1 ether;
        LZSendParam memory remoteLzSendParam_;
        MessagingFee memory remoteMsgFee_; // Will be used as value for the composed msg

        /**
         * Setup
         */
        {
            deal(address(bTOFT), address(this), tokenAmount_);

            // @dev `remoteMsgFee_` is to be airdropped on dst to pay for the `remoteTransfer` operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = tOFTv2Helper.prepareLzCall( // B->A data
                ITOFTv2(address(bTOFT)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    refundAddress: address(this),
                    amountToSendLD: tokenAmount_,
                    minAmountToCreditLD: tokenAmount_,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            remoteLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            remoteMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        RemoteTransferMsg memory remoteTransferData =
            RemoteTransferMsg({composeMsg: new bytes(0), owner: address(this), lzSendParam: remoteLzSendParam_});
        bytes memory remoteTransferMsg_ = tOFTv2Helper.buildRemoteTransferMsg(remoteTransferData);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = tOFTv2Helper.prepareLzCall(
            ITOFTv2(address(aTOFT)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                refundAddress: address(this),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_REMOTE_TRANSFER,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(remoteMsgFee_.nativeFee), // TODO Should we care about verifying cast boundaries?
                    data: remoteTransferMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aTOFT.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bTOFT));

            // Initiate approval
            bTOFT.approve(address(bTOFT), tokenAmount_); // Needs to be pre approved on B chain to be able to transfer

            __callLzCompose(
                LzOFTComposedData(
                    PT_REMOTE_TRANSFER,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bTOFT), // Compose creator (at lzReceive)
                    address(bTOFT), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check arrival
        {
            assertEq(aTOFT.balanceOf(address(this)), 0);
            verifyPackets(uint32(aEid), address(aTOFT)); // Verify B->A transfer
            assertEq(aTOFT.balanceOf(address(this)), tokenAmount_);
        }
    }

    function test_market_deposit_and_borrow() public {
        uint256 erc20Amount_ = 1 ether;

        {   
            // test wrap
            deal(address(aERC20), address(this), erc20Amount_);
            deal(address(bERC20), address(this), erc20Amount_);

            assertEq(aERC20.balanceOf(address(this)), erc20Amount_);
            assertEq(bERC20.balanceOf(address(this)), erc20Amount_);

            aERC20.approve(address(aTOFT), erc20Amount_);
            bERC20.approve(address(bTOFT), erc20Amount_);

            aTOFT.wrap(address(this), address(this), erc20Amount_);
            bTOFT.wrap(address(this), address(this), erc20Amount_);

            assertEq(aTOFT.balanceOf(address(this)), erc20Amount_);
            assertEq(bTOFT.balanceOf(address(this)), erc20Amount_);

            aTOFT.approve(address(yieldBox), erc20Amount_);
            yieldBox.depositAsset(aTOFTYieldBoxId, address(this), address(singularity), erc20Amount_, 0);
            assertGt(yieldBox.balanceOf(address(singularity), aTOFTYieldBoxId), 0);

            assertEq(aTOFT.balanceOf(address(this)), 0);
            deal(address(aTOFT), address(this), erc20Amount_);
            assertEq(aTOFT.balanceOf(address(this)), erc20Amount_);
        }
        

        //useful in case of withdraw after borrow
        //MagnetarMock doesn't have this implemented yet, but we test the airdrop
        LZSendParam memory withdrawLzSendParam_;
        MessagingFee memory withdrawMsgFee_; // Will be used as value for the composed msg

        uint256 tokenAmount_ = 0.5 ether;

        {
             // @dev `withdrawMsgFee_` is to be airdropped on dst to pay for the send to source operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = tOFTv2Helper.prepareLzCall( // B->A data
                ITOFTv2(address(bTOFT)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    refundAddress: address(this),
                    amountToSendLD: tokenAmount_,
                    minAmountToCreditLD: tokenAmount_,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            withdrawLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            withdrawMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */

        //approve magnetar
        bTOFT.approve(address(magnetar), type(uint256).max);

        MarketBorrowMsg memory marketBorrowMsg =
            MarketBorrowMsg({
                from: address(this),
                to: address(this),
                borrowParams: ITapiocaOFT.IBorrowParams({
                    amount: tokenAmount_,
                    borrowAmount: tokenAmount_,
                    marketHelper: address(magnetar),
                    market: address(singularity),
                    deposit: true
                }),
                withdrawParams: ICommonData.IWithdrawParams({
                    withdraw: false,
                    withdrawLzFeeAmount: 0,
                    withdrawOnOtherChain: false,
                    withdrawLzChainId: 0,
                    withdrawAdapterParams: "0x",
                    unwrap: false,
                    refundAddress: payable(0),
                    zroPaymentAddress: address(0)
                })
            });
        bytes memory marketBorrowMsg_ = tOFTv2Helper.buildMarketBorrowMsg(marketBorrowMsg);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = tOFTv2Helper.prepareLzCall(
            ITOFTv2(address(aTOFT)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                refundAddress: address(this),
                amountToSendLD: tokenAmount_,
                minAmountToCreditLD: tokenAmount_,
                msgType: PT_YB_SEND_SGL_BORROW,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(withdrawMsgFee_.nativeFee), 
                    data: marketBorrowMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aTOFT.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bTOFT));

            __callLzCompose(
                LzOFTComposedData(
                    PT_YB_SEND_SGL_BORROW,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bTOFT), // Compose creator (at lzReceive)
                    address(bTOFT), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check execution
        {
            assertEq(aTOFT.balanceOf(address(this)), erc20Amount_ - tokenAmount_);
            assertEq(bTOFT.balanceOf(address(this)), erc20Amount_);
            assertEq(yieldBox.toAmount(aTOFTYieldBoxId, yieldBox.balanceOf(address(this), aTOFTYieldBoxId), false), tokenAmount_);

        }
    }

}