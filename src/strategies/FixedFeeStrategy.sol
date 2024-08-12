// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

contract FixedFeeStrategy is IStrategy {
    address public owner;
    uint128 public fee;

    constructor(uint128 _fee) {
        owner = msg.sender;
        fee = _fee;
    }

    function calculateSwapFee(PoolKey calldata, IPoolManager.SwapParams calldata)
        external
        view
        override
        returns (uint128)
    {
        return fee;
    }

    function setFee(uint128 _fee) external {
        require(msg.sender == owner, "!owner");
        fee = _fee;
    }
}
