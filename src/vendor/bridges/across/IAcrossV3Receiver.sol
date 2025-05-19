// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IAcrossV3Receiver {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event AcrossFundsReceivedAndExecuted(address indexed account);
    event AcrossFundsReceivedButExecutionFailed(address indexed account);
    event AcrossFundsReceivedButNotEnoughBalance(address indexed account);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error INVALID_SENDER();

    /*//////////////////////////////////////////////////////////////
                                 EXTERNAL METHODS
    //////////////////////////////////////////////////////////////*/
    /// @notice Handle a message from the Across V3 bridge
    /// @param tokenSent The token sent
    /// @param amount The amount sent
    /// @param relayer The relayer
    /// @param message The message
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;
}
