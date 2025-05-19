// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Execution} from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import {FluidStakeHook} from "../../../../../src/core/hooks/stake/fluid/FluidStakeHook.sol";
import {ISuperHook, ISuperHookResult} from "../../../../../src/core/interfaces/ISuperHook.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {MockHook} from "../../../../mocks/MockHook.sol";
import {BaseHook} from "../../../../../src/core/hooks/BaseHook.sol";
import {Helpers} from "../../../../utils/Helpers.sol";

contract FluidStakeHookTest is Helpers {
    FluidStakeHook public hook;

    bytes4 yieldSourceOracleId;
    address yieldSource;
    address token;
    uint256 amount;

    function setUp() public {
        MockERC20 _mockToken = new MockERC20("Mock Token", "MTK", 18);
        token = address(_mockToken);

        yieldSourceOracleId = bytes4(keccak256("YIELD_SOURCE_ORACLE_ID"));
        yieldSource = makeAddr("yieldSource");
        amount = 1000;

        hook = new FluidStakeHook();
    }

    function test_Constructor() public view {
        assertEq(uint256(hook.hookType()), uint256(ISuperHook.HookType.NONACCOUNTING));
    }

    function test_Inspector() public view {
        bytes memory data = _encodeData(false);
        bytes memory argsEncoded = hook.inspect(data);
        assertGt(argsEncoded.length, 0);
    }

    function test_DecodeUsePrevHookAmount() public view {
        bytes memory data = _encodeData(false);
        assertEq(hook.decodeUsePrevHookAmount(data), false);

        data = _encodeData(true);
        assertEq(hook.decodeUsePrevHookAmount(data), true);
    }

    function test_Build() public view {
        bytes memory data = _encodeData(false);
        Execution[] memory executions = hook.build(address(0), address(this), data);
        assertEq(executions.length, 1);
        assertEq(executions[0].target, yieldSource);
        assertEq(executions[0].value, 0);
        assertGt(executions[0].callData.length, 0);

        data = _encodeData(false);
        executions = hook.build(address(0), address(this), data);
        assertEq(executions.length, 1);
        assertEq(executions[0].target, yieldSource);
        assertEq(executions[0].value, 0);
        assertGt(executions[0].callData.length, 0);
    }

    function test_Build_RevertIf_AddressZero() public {
        yieldSource = address(0);
        vm.expectRevert(BaseHook.ADDRESS_NOT_VALID.selector);
        hook.build(address(0), address(this), _encodeData(false));
    }

    function test_Build_WithPrevHook() public {
        uint256 prevHookAmount = 2000;
        address mockPrevHook = address(new MockHook(ISuperHook.HookType.INFLOW, token));
        MockHook(mockPrevHook).setOutAmount(prevHookAmount);

        bytes memory data = _encodeData(true);
        Execution[] memory executions = hook.build(mockPrevHook, address(this), data);
        assertEq(executions.length, 1);
        assertEq(executions[0].target, yieldSource);
        assertEq(executions[0].value, 0);
        assertGt(executions[0].callData.length, 0);
    }

    function test_PreAndPostExecute() public {
        yieldSource = token; // to allow balanceOf call
        bytes memory data = _encodeData(false);

        _getTokens(token, address(this), amount);

        hook.preExecute(address(0), address(this), data);
        assertEq(hook.outAmount(), amount);

        hook.postExecute(address(0), address(this), data);
        assertEq(hook.outAmount(), 0);
    }

    function _encodeData(bool usePrevHook) internal view returns (bytes memory) {
        return abi.encodePacked(yieldSourceOracleId, yieldSource, amount, usePrevHook);
    }
}
