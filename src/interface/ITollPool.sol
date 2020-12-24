// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.9;
pragma experimental ABIEncoderV2;

import { Decimal } from "../utils/Decimal.sol";
import { IERC20 } from "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

interface ITollPool {
    function notifyTokenAmount(IERC20 _token, Decimal.decimal calldata _amount) external;

    function transferToTmpRewardPool() external;
}
