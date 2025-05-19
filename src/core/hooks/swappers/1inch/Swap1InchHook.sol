// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// external
import {Execution} from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import "../../../../vendor/1inch/I1InchAggregationRouterV6.sol";

// Superform
import {BaseHook} from "../../BaseHook.sol";
import {HookSubTypes} from "../../../libraries/HookSubTypes.sol";
import {ISuperHookResult, ISuperHookContextAware, ISuperHookInspector} from "../../../interfaces/ISuperHook.sol";

import "forge-std/console2.sol";

/// @title Swap1InchHook
/// @author Superform Labs
/// @dev data has the following structure
/// @notice         address dstToken = BytesLib.toAddress(data, 0);
/// @notice         address dstReceiver = BytesLib.toAddress(data, 20);
/// @notice         uint256 value = BytesLib.toUint256(data, 40);
/// @notice         bool usePrevHookAmount = _decodeBool(data, 72);
/// @notice         bytes txData_ = BytesLib.slice(data, 73, data.length - 73);
contract Swap1InchHook is BaseHook, ISuperHookContextAware, ISuperHookInspector {
    using AddressLib for Address;
    using ProtocolLib for Address;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/
    I1InchAggregationRouterV6 public immutable aggregationRouter;
    uint256 private constant USE_PREV_HOOK_AMOUNT_POSITION = 72;

    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZERO_ADDRESS();
    error INVALID_RECEIVER();
    error INVALID_SELECTOR();
    error INVALID_TOKEN_PAIR();
    error INVALID_INPUT_AMOUNT();
    error INVALID_OUTPUT_AMOUNT();
    error INVALID_SELECTOR_OFFSET();
    error PARTIAL_FILL_NOT_ALLOWED();
    error INVALID_DESTINATION_TOKEN();

    constructor(address aggregationRouter_) BaseHook(HookType.NONACCOUNTING, HookSubTypes.SWAP) {
        if (aggregationRouter_ == address(0)) {
            revert ZERO_ADDRESS();
        }

        aggregationRouter = I1InchAggregationRouterV6(aggregationRouter_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEW METHODS
    //////////////////////////////////////////////////////////////*/
    function build(address prevHook, address, bytes calldata data)
        external
        view
        override
        returns (Execution[] memory executions)
    {
        address dstToken = address(bytes20(data[:20]));
        address dstReceiver = address(bytes20(data[20:40]));
        uint256 value = uint256(bytes32(data[40:USE_PREV_HOOK_AMOUNT_POSITION]));
        bool usePrevHookAmount = _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);
        bytes calldata txData_ = data[73:];

        bytes memory updatedTxData = _validateTxData(dstToken, dstReceiver, prevHook, usePrevHookAmount, txData_);

        executions = new Execution[](1);
        executions[0] = Execution({
            target: address(aggregationRouter),
            value: value,
            callData: usePrevHookAmount ? updatedTxData : txData_
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 EXTERNAL METHODS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISuperHookContextAware
    function decodeUsePrevHookAmount(bytes memory data) external pure returns (bool) {
        return _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);
    }

    /// @inheritdoc ISuperHookInspector
    function inspect(bytes calldata data) external pure returns (bytes memory) {
        bytes calldata txData_ = data[73:];
        bytes4 selector = bytes4(txData_[:4]);

        bytes memory packed;

        if (selector == I1InchAggregationRouterV6.unoswapTo.selector) {
            (Address to, Address token,,, Address dex) =
                abi.decode(txData_[4:], (Address, Address, uint256, uint256, Address));
            packed = abi.encodePacked(to.get(), token.get(), dex.get());
        } else if (selector == I1InchAggregationRouterV6.swap.selector) {
            (IAggregationExecutor executor, I1InchAggregationRouterV6.SwapDescription memory desc,) =
                abi.decode(txData_[4:], (IAggregationExecutor, I1InchAggregationRouterV6.SwapDescription, bytes));
            packed = abi.encodePacked(
                address(executor),
                address(desc.srcToken),
                address(desc.dstToken),
                address(desc.srcReceiver),
                address(desc.dstReceiver)
            );
        } else if (selector == I1InchAggregationRouterV6.clipperSwapTo.selector) {
            (IClipperExchange clipperExchange, address recipient, Address srcToken, IERC20 dstToken,,,,,) = abi.decode(
                txData_[4:], (IClipperExchange, address, Address, IERC20, uint256, uint256, uint256, bytes32, bytes32)
            );
            packed = abi.encodePacked(address(clipperExchange), recipient, srcToken.get(), address(dstToken));
        }

        return packed;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL METHODS
    //////////////////////////////////////////////////////////////*/
    function _preExecute(address, address, bytes calldata data) internal override {
        outAmount = _getBalance(data);
    }

    function _postExecute(address, address, bytes calldata data) internal override {
        outAmount = _getBalance(data) - outAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIVATE METHODS
    //////////////////////////////////////////////////////////////*/
    function _validateTxData(
        address dstToken,
        address dstReceiver,
        address prevHook,
        bool usePrevHookAmount,
        bytes calldata txData_
    ) private view returns (bytes memory updatedTxData) {
        bytes4 selector = bytes4(txData_[:4]);

        if (selector == I1InchAggregationRouterV6.unoswapTo.selector) {
            /// @dev support UNISWAP_V2, UNISWAP_V3, CURVE and all uniswap-based forks
            updatedTxData = _validateUnoswap(txData_[4:], dstReceiver, dstToken, prevHook, usePrevHookAmount);
        } else if (selector == I1InchAggregationRouterV6.swap.selector) {
            /// @dev support for generic router call
            updatedTxData = _validateGenericSwap(txData_[4:], dstReceiver, dstToken, prevHook, usePrevHookAmount);
        } else if (selector == I1InchAggregationRouterV6.clipperSwapTo.selector) {
            updatedTxData = _validateClipperSwap(txData_[4:], dstReceiver, dstToken, prevHook, usePrevHookAmount);
        } else {
            revert INVALID_SELECTOR();
        }
    }

    function _validateUnoswap(
        bytes calldata txData_,
        address receiver,
        address toToken,
        address prevHook,
        bool usePrevHookAmount
    ) private view returns (bytes memory updatedTxData) {
        (Address to, Address token, uint256 amount, uint256 minReturn, Address dex) =
            abi.decode(txData_, (Address, Address, uint256, uint256, Address));

        address dstToken;

        ProtocolLib.Protocol protocol = dex.protocol();
        if (protocol == ProtocolLib.Protocol.Curve) {
            // CURVE
            uint256 selectorOffset =
                (Address.unwrap(dex) >> _CURVE_TO_COINS_SELECTOR_OFFSET) & _CURVE_TO_COINS_SELECTOR_MASK;
            uint256 dstTokenIndex = (Address.unwrap(dex) >> _CURVE_TO_COINS_ARG_OFFSET) & _CURVE_TO_COINS_ARG_MASK;

            if (selectorOffset == 0) {
                dstToken = ICurvePool(dex.get()).base_coins(dstTokenIndex);
            } else if (selectorOffset == 4) {
                dstToken = ICurvePool(dex.get()).coins(int128(uint128(dstTokenIndex)));
            } else if (selectorOffset == 8) {
                dstToken = ICurvePool(dex.get()).coins(dstTokenIndex);
            } else if (selectorOffset == 12) {
                dstToken = ICurvePool(dex.get()).underlying_coins(int128(uint128(dstTokenIndex)));
            } else if (selectorOffset == 16) {
                dstToken = ICurvePool(dex.get()).underlying_coins(dstTokenIndex);
            } else {
                revert INVALID_SELECTOR_OFFSET();
            }
        } else {
            // UNISWAPV2 and UNISWAPV3
            address token0 = IUniswapPair(dex.get()).token0();
            address token1 = IUniswapPair(dex.get()).token1();

            address fromToken = token.get();
            if (token0 == fromToken) {
                dstToken = token1;
            } else if (token1 == fromToken) {
                dstToken = token0;
            } else {
                revert INVALID_TOKEN_PAIR();
            }
        }

        /// @dev remap of WETH to Native if unwrapWeth flag is true
        if (dex.shouldUnwrapWeth()) {
            dstToken = NATIVE;
        }

        if (usePrevHookAmount) {
            amount = ISuperHookResult(prevHook).outAmount();
        }

        if (amount == 0) {
            revert INVALID_INPUT_AMOUNT();
        }

        if (minReturn == 0) {
            revert INVALID_OUTPUT_AMOUNT();
        }

        if (toToken != dstToken) {
            revert INVALID_DESTINATION_TOKEN();
        }

        address dstReceiver = to.get();
        if (dstReceiver != receiver) {
            revert INVALID_RECEIVER();
        }

        if (usePrevHookAmount) {
            updatedTxData = abi.encode(to, token, amount, minReturn, dex);
        }
    }

    function _validateGenericSwap(
        bytes calldata txData_,
        address receiver,
        address toToken,
        address prevHook,
        bool usePrevHookAmount
    ) private view returns (bytes memory updatedTxData) {
        (IAggregationExecutor executor, I1InchAggregationRouterV6.SwapDescription memory desc, bytes memory data) =
            abi.decode(txData_, (IAggregationExecutor, I1InchAggregationRouterV6.SwapDescription, bytes));

        if (desc.flags & _PARTIAL_FILL != 0) {
            revert PARTIAL_FILL_NOT_ALLOWED();
        }

        if (address(desc.dstToken) != toToken) {
            revert INVALID_DESTINATION_TOKEN();
        }

        if (desc.dstReceiver != receiver) {
            revert INVALID_RECEIVER();
        }

        if (usePrevHookAmount) {
            desc.amount = ISuperHookResult(prevHook).outAmount();
        }

        if (desc.amount == 0) {
            revert INVALID_INPUT_AMOUNT();
        }

        if (desc.minReturnAmount == 0) {
            revert INVALID_OUTPUT_AMOUNT();
        }

        if (usePrevHookAmount) {
            updatedTxData = abi.encode(executor, desc, data);
        }
    }

    function _validateClipperSwap(
        bytes calldata txData_,
        address receiver,
        address toToken,
        address prevHook,
        bool usePrevHookAmount
    ) private view returns (bytes memory updatedTxData) {
        (
            IClipperExchange clipperExchange,
            address recipient,
            Address srcToken,
            IERC20 dstToken,
            uint256 inputAmount,
            uint256 outputAmount,
            uint256 expiryWithFlags,
            bytes32 r,
            bytes32 vs
        ) = abi.decode(
            txData_, (IClipperExchange, address, Address, IERC20, uint256, uint256, uint256, bytes32, bytes32)
        );

        if (recipient != receiver) {
            revert INVALID_RECEIVER();
        }

        if (usePrevHookAmount) {
            inputAmount = ISuperHookResult(prevHook).outAmount();
        }

        if (inputAmount == 0) {
            revert INVALID_INPUT_AMOUNT();
        }

        if (outputAmount == 0) {
            revert INVALID_OUTPUT_AMOUNT();
        }

        if (address(dstToken) != toToken) {
            revert INVALID_DESTINATION_TOKEN();
        }
        if (usePrevHookAmount) {
            updatedTxData = abi.encode(
                clipperExchange, recipient, srcToken, dstToken, inputAmount, outputAmount, expiryWithFlags, r, vs
            );
        }
    }

    function _getBalance(bytes calldata data) private view returns (uint256) {
        address dstToken = address(bytes20(data[:20]));
        address dstReceiver = address(bytes20(data[20:40]));

        if (dstToken == NATIVE || dstToken == address(0)) {
            return dstReceiver.balance;
        }
        return IERC20(dstToken).balanceOf(dstReceiver);
    }
}
