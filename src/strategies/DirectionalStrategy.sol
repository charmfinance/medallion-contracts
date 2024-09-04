// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

contract DirectionalFeeStrategy is IStrategy {
    using PoolIdLibrary for PoolKey;

    address public medallionHook;
    uint128 public feeIfSameDirection;
    uint128 public feeIfChangeDirection;
    mapping(PoolId => bool) public lastDirection;

    constructor(address _medallionHook, uint128 _feeIfSameDirection, uint128 _feeIfChangeDirection) {
        medallionHook = _medallionHook;
        feeIfSameDirection = _feeIfSameDirection;
        feeIfChangeDirection = _feeIfChangeDirection;
    }

    function calculateSwapFee(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams)
        external
        override
        returns (uint128 fee)
    {
        // Only Medallion can call this function otherwise anyone can mutate this contract's state
        require(msg.sender == medallionHook, "medallionHook");

        PoolId poolId = key.toId();
        fee = lastDirection[poolId] == swapParams.zeroForOne ? feeIfSameDirection : feeIfChangeDirection;
        lastDirection[poolId] = swapParams.zeroForOne;
    }
}
