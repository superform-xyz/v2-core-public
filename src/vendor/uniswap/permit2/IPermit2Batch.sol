// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAllowanceTransfer} from "./IAllowanceTransfer.sol";

interface IPermit2Batch {
    function permit(address owner, IAllowanceTransfer.PermitBatch memory permitBatch, bytes memory signature)
        external;
    function transferFrom(IAllowanceTransfer.AllowanceTransferDetails[] calldata transferDetails) external;
}
