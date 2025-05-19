// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// external
import {BytesLib} from "../../../../vendor/BytesLib.sol";
import {Execution} from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import {IOdosRouterV2} from "../../../../vendor/odos/IOdosRouterV2.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

// Superform
import {BaseHook} from "../../BaseHook.sol";
import {HookSubTypes} from "../../../libraries/HookSubTypes.sol";
import {ISuperHookResult, ISuperHookContextAware, ISuperHookInspector} from "../../../interfaces/ISuperHook.sol";

/// @title SwapOdosHook
/// @author Superform Labs
/// @dev data has the following structure
/// @notice         address inputToken = BytesLib.toAddress(data, 0);
/// @notice         uint256 inputAmount = BytesLib.toUint256(data, 20);
/// @notice         address inputReceiver = BytesLib.toAddress(data, 52);
/// @notice         address outputToken = BytesLib.toAddress(data, 72);
/// @notice         uint256 outputQuote = BytesLib.toUint256(data, 92);
/// @notice         uint256 outputMin = BytesLib.toUint256(data, 124);
/// @notice         bool usePrevHookAmount = _decodeBool(data, 156);
/// @notice         uint256 pathDefinition_paramLength = BytesLib.toUint256(data, 157);
/// @notice         bytes pathDefinition = BytesLib.slice(data, 189, pathDefinition_paramLength);
/// @notice         address executor = BytesLib.toAddress(data, 189 + pathDefinition_paramLength);
/// @notice         uint32 referralCode = BytesLib.toUint32(data, 189 + pathDefinition_paramLength + 20);
contract SwapOdosHook is BaseHook, ISuperHookContextAware, ISuperHookInspector {
    IOdosRouterV2 public immutable odosRouterV2;

    uint256 private constant USE_PREV_HOOK_AMOUNT_POSITION = 156;

    constructor(address _routerV2) BaseHook(HookType.NONACCOUNTING, HookSubTypes.SWAP) {
        if (_routerV2 == address(0)) revert ADDRESS_NOT_VALID();
        odosRouterV2 = IOdosRouterV2(_routerV2);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEW METHODS
    //////////////////////////////////////////////////////////////*/
    function build(address prevHook, address account, bytes memory data)
        external
        view
        override
        returns (Execution[] memory executions)
    {
        uint256 pathDefinition_paramLength = BytesLib.toUint256(data, 157);
        bytes memory pathDefinition = BytesLib.slice(data, 189, pathDefinition_paramLength);
        address executor = BytesLib.toAddress(data, 189 + pathDefinition_paramLength);
        uint32 referralCode = BytesLib.toUint32(data, 189 + pathDefinition_paramLength + 20);
        address inputToken = BytesLib.toAddress(data, 0);
        uint256 inputAmount = BytesLib.toUint256(data, 20);

        bool usePrevHookAmount = _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);
        if (usePrevHookAmount) {
            inputAmount = ISuperHookResult(prevHook).outAmount();
        }

        executions = new Execution[](1);
        executions[0] = Execution({
            target: address(odosRouterV2),
            value: inputToken == address(0) ? inputAmount : 0,
            callData: abi.encodeCall(
                IOdosRouterV2.swap, (_getSwapInfo(account, prevHook, data), pathDefinition, executor, referralCode)
            )
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
        uint256 pathDefinition_paramLength = BytesLib.toUint256(data, 157);
        address executor = BytesLib.toAddress(data, 189 + pathDefinition_paramLength);

        return abi.encodePacked(
            BytesLib.toAddress(data, 0), //inputToken
            BytesLib.toAddress(data, 52), //inputReceiver
            BytesLib.toAddress(data, 72), //outputToken
            executor
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL METHODS
    //////////////////////////////////////////////////////////////*/
    function _preExecute(address, address account, bytes calldata data) internal override {
        outAmount = _getBalance(account, data);
    }

    function _postExecute(address, address account, bytes calldata data) internal override {
        outAmount = _getBalance(account, data) - outAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIVATE METHODS
    //////////////////////////////////////////////////////////////*/
    function _getBalance(address account, bytes memory data) private view returns (uint256) {
        address outputToken = BytesLib.toAddress(BytesLib.slice(data, 72, 20), 0);

        if (outputToken == address(0)) {
            return account.balance;
        }

        return IERC20(outputToken).balanceOf(account);
    }

    function _getSwapInfo(address account, address prevHook, bytes memory data)
        private
        view
        returns (IOdosRouterV2.swapTokenInfo memory)
    {
        address inputToken = BytesLib.toAddress(data, 0);
        uint256 inputAmount = BytesLib.toUint256(data, 20);
        address inputReceiver = BytesLib.toAddress(data, 52);
        address outputToken = BytesLib.toAddress(data, 72);
        uint256 outputQuote = BytesLib.toUint256(data, 92);
        uint256 outputMin = BytesLib.toUint256(data, 124);
        bool usePrevHookAmount = _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);

        if (usePrevHookAmount) {
            inputAmount = ISuperHookResult(prevHook).outAmount();
        }
        return IOdosRouterV2.swapTokenInfo(
            inputToken, inputAmount, inputReceiver, outputToken, outputQuote, outputMin, account
        );
    }
}
