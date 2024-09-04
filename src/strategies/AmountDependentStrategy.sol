// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title AmountDependentStrategy
 * @notice A strategy that charges higher fees for larger swaps. The idea is that arbitrage swaps tend to be larger than
 * uninformed swaps, so this strategy can extract higher fees from arbitrage swaps while still allowing retail users to
 * swap at a lower fee.
 *
 * To prevent arbitrageurs from simply splitting up their swaps into smaller pieces to pay a lower fee, the fee is
 * dependant on the cumulative volume traded in the pool this block.
 */
contract AmountDependentStrategy is IStrategy {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // The default 0.3% swap fee used when no fee multiplier set for that pool
    uint24 DEFAULT_SWAP_FEE = 3000;

    IPoolManager public manager;
    address public owner;
    address public medallionHook;

    mapping(PoolId => uint128) public feeMultiplier;
    mapping(PoolId => uint256) public cumulativeVolume;
    mapping(PoolId => uint256) public lastTradedBlock;

    constructor(IPoolManager _manager, address _medallionHook) {
        owner = msg.sender;
        manager = _manager;
        medallionHook = _medallionHook;
    }

    function calculateSwapFee(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams)
        external
        override
        returns (uint128)
    {
        PoolId poolId = key.toId();

        // If the fee multiplier is not set, use the default fee
        uint128 feeMultiplier_ = feeMultiplier[poolId];
        if (feeMultiplier_ == 0) {
            return DEFAULT_SWAP_FEE;
        }

        // Convert the amount specified in the swap to be in terms of units of the geometric mean of the two tokens.
        // This is done so the fee multiplier can be applied regardless of if the amount specified is in terms of token0 or token1.
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolId);
        bool isToken0Specified = swapParams.zeroForOne == (swapParams.amountSpecified < 0);
        uint256 absAmountSpecified =
            uint256(swapParams.amountSpecified < 0 ? -swapParams.amountSpecified : swapParams.amountSpecified);
        uint256 swapAmount = isToken0Specified
            ? absAmountSpecified * (1 << 96) / sqrtPriceX96
            : absAmountSpecified * sqrtPriceX96 / (1 << 96);

        // Calculate and update cumulative volume this block
        if (block.number == lastTradedBlock[poolId]) {
            cumulativeVolume[poolId] += swapAmount;
        } else {
            cumulativeVolume[poolId] = swapAmount;
            lastTradedBlock[poolId] = block.number;
        }

        // Fee = cumulative volume * fee multiplier / 1 ether
        return feeMultiplier_ * cumulativeVolume[poolId].toUint128() / 1 ether;
    }

    /// @notice The strategist can set a fee multiplier for each pool which will be used to calculate the swap fee for swaps in that pool.
    /// Set the fee multiplier to 0 to use the default fee.
    function setFeeMultiplier(PoolKey calldata key, uint128 _feeMultiplier) external {
        require(msg.sender == owner, "!owner");
        feeMultiplier[key.toId()] = _feeMultiplier;
    }
}
