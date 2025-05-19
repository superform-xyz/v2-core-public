// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// external
import {BytesLib} from "../../../../vendor/BytesLib.sol";
import {Execution} from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IStandardizedYield} from "../../../../vendor/pendle/IStandardizedYield.sol";

// Superform
import {BaseHook} from "../../BaseHook.sol";
import {HookSubTypes} from "../../../libraries/HookSubTypes.sol";
import {HookDataDecoder} from "../../../libraries/HookDataDecoder.sol";
import {
    ISuperHookResult,
    ISuperHookInflowOutflow,
    ISuperHookContextAware,
    ISuperHookInspector
} from "../../../interfaces/ISuperHook.sol";

/// @title ApproveAndDeposit5115VaultHook
/// @author Superform Labs
/// @notice This hook does not support tokens reverting on 0 approval
/// @dev data has the following structure
/// @notice         bytes4 yieldSourceOracleId = bytes4(BytesLib.slice(data, 0, 4), 0);
/// @notice         address yieldSource = BytesLib.toAddress(data, 4);
/// @notice         address tokenIn = BytesLib.toAddress(data, 24);
/// @notice         uint256 amount = BytesLib.toUint256(data, 44);
/// @notice         uint256 minSharesOut = BytesLib.toUint256(data, 76);
/// @notice         bool usePrevHookAmount = _decodeBool(data, 108);
/// @notice         address vaultBank = BytesLib.toAddress(data, 109);
/// @notice         uint256 dstChainId = BytesLib.toUint256(data, 129);
contract ApproveAndDeposit5115VaultHook is
    BaseHook,
    ISuperHookInflowOutflow,
    ISuperHookContextAware,
    ISuperHookInspector
{
    using HookDataDecoder for bytes;

    uint256 private constant AMOUNT_POSITION = 44;
    uint256 private constant USE_PREV_HOOK_AMOUNT_POSITION = 108;

    constructor() BaseHook(HookType.INFLOW, HookSubTypes.ERC5115) {}

    /*//////////////////////////////////////////////////////////////
                                 VIEW METHODS
    //////////////////////////////////////////////////////////////*/
    function build(address prevHook, address account, bytes memory data)
        external
        view
        override
        returns (Execution[] memory executions)
    {
        address yieldSource = data.extractYieldSource();
        address tokenIn = BytesLib.toAddress(data, 24);
        uint256 amount = BytesLib.toUint256(data, 44);
        uint256 minSharesOut = BytesLib.toUint256(data, 76);
        bool usePrevHookAmount = _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);

        if (usePrevHookAmount) {
            amount = ISuperHookResult(prevHook).outAmount();
        }

        if (amount == 0) revert AMOUNT_NOT_VALID();
        if (yieldSource == address(0) || account == address(0) || tokenIn == address(0)) revert ADDRESS_NOT_VALID();

        executions = new Execution[](4);
        executions[0] =
            Execution({target: tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (yieldSource, 0))});
        executions[1] =
            Execution({target: tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (yieldSource, amount))});
        executions[2] = Execution({
            target: yieldSource,
            value: 0,
            callData: abi.encodeCall(IStandardizedYield.deposit, (account, tokenIn, amount, minSharesOut))
        });
        executions[3] =
            Execution({target: tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (yieldSource, 0))});
    }

    /*//////////////////////////////////////////////////////////////
                                 EXTERNAL METHODS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISuperHookInflowOutflow
    function decodeAmount(bytes memory data) external pure returns (uint256) {
        return _decodeAmount(data);
    }

    /// @inheritdoc ISuperHookContextAware
    function decodeUsePrevHookAmount(bytes memory data) external pure returns (bool) {
        return _decodeBool(data, USE_PREV_HOOK_AMOUNT_POSITION);
    }

    /// @inheritdoc ISuperHookInspector
    function inspect(bytes calldata data) external pure returns (bytes memory) {
        return abi.encodePacked(
            data.extractYieldSource(),
            BytesLib.toAddress(data, 24) // tokenIn
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL METHODS
    //////////////////////////////////////////////////////////////*/
    function _preExecute(address, address account, bytes calldata data) internal override {
        outAmount = _getBalance(account, data);
        vaultBank = BytesLib.toAddress(data, 109);
        dstChainId = BytesLib.toUint256(data, 129);
        spToken = data.extractYieldSource();
        asset = BytesLib.toAddress(BytesLib.slice(data, 24, 20), 0);
    }

    function _postExecute(address, address account, bytes calldata data) internal override {
        outAmount = _getBalance(account, data) - outAmount;
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIVATE METHODS
    //////////////////////////////////////////////////////////////*/
    function _decodeAmount(bytes memory data) private pure returns (uint256) {
        return BytesLib.toUint256(data, AMOUNT_POSITION);
    }

    function _getBalance(address account, bytes memory data) private view returns (uint256) {
        return IERC4626(data.extractYieldSource()).balanceOf(account);
    }
}
