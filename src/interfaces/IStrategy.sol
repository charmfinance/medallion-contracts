// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

interface IStrategy {
    function calculateSwapFee(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (uint128);
}
