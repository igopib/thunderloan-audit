// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;

//audit info-unused import
//audit info-interface IThunderLoan is not being implemented despite being imported
import { IThunderLoan } from "./IThunderLoan.sol";

/**
 * @dev Inspired by Aave:
 * https://github.com/aave/aave-v3-core/blob/master/contracts/flashloan/interfaces/IFlashLoanReceiver.sol
 */
//@audit info-natspec missing
interface IFlashLoanReceiver {
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    )
        external
        returns (bool);
}
