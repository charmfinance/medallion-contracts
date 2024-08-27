// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title Neptune Hook
 * @author Charm Finance
 * @notice A Uniswap V4 hook that auctions off right to set and receive all swap fees
 * @dev This code is a proof-of-concept and must not be used in production
 *
 * Todo:
 * - Find a better way to specify the rent token
 * - Allow governance to modify parameters like MIN_USURP_FACTOR and COOLDOWN_BLOCKS
 * - Make sure strategy contract can't see max slippage
 * - Add support for a maxFee parameter in swap
 * - Emit events
 * - Make `_distributeRent` a modifier
 * - Find way to avoid gas wars when rent is too low and multiple managers bid
 */
contract NeptuneHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error NotEnoughCollateral();
    error NotLiquidatable();
    error PoolMustBeDynamicFee();
    error SenderIsAlreadyStrategist();
    error RentTooLow();
    error RentTooLowDuringCooldown();
    error SenderMustBeStrategist();

    /// @notice State stored for each pool.
    struct PoolState {
        address strategist;
        address strategy; // Current attached strategy contract. Zero address if none attached.
        address feeRecipient; // Fee recipient specified by strategist
        uint256 rent;
        uint256 lastRentPaidBlock;
        uint256 lastUsurpBlock;
        bool rentInTokenZero;
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => PoolState) public pools;

    /// @notice How much collateral user has deposited into the contract. This collateral covers rent payments.
    mapping(PoolId => mapping(address => uint256)) public collateral;

    // The default 0.3% swap fee used when no strategy set
    uint24 DEFAULT_SWAP_FEE = 3000;

    uint256 MIN_USURP_FACTOR = 1.2e18; // Rent needs to be 20% higher to usurp current strategist
    uint256 COOLDOWN_BLOCKS = 100; // Cannot decrease bid for 100 blocks after newly becoming strategist
    uint256 MIN_COLLATERAL_BLOCKS = 100; // Minimum collateral to withdraw
    uint256 LIQUIDATION_BLOCKS = 20; // If strategist's collateral is less than rent * LIQUIDATION_BLOCKS, they can be liquidated

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Reverts if dynamic fee flag is not set.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        onlyByPoolManager
        returns (bytes4)
    {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert PoolMustBeDynamicFee();
        return this.beforeInitialize.selector;
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        _distributeRent(key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Calculate swap fees from attached strategy and redirect the fees to the strategist.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _distributeRent(key);

        // If no strategy is set, the swap fee is just set to the default fee like in a hookless Uniswap pool
        PoolState storage pool = pools[key.toId()];
        if (address(pool.strategy) == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Call strategy contract to get swap fee.
        uint128 fee = IStrategy(pool.strategy).calculateSwapFee(key, params);
        int256 fees = params.amountSpecified * uint256(fee).toInt256() / 1e6;
        int256 absFees = fees > 0 ? fees : -fees;

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // Send fees to `feeRecipient`
        feeCurrency.take(poolManager, pool.feeRecipient, absFees.toUint256(), true);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments as the manager.
    function depositCollateral(PoolKey calldata key, uint256 amount) external {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, amount, 0)));
        collateral[key.toId()][msg.sender] += amount;
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `depositCollateral`.
    function withdrawCollateral(PoolKey calldata key, uint256 amount) external {
        _distributeRent(key);
        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Get user's up-to-date balance
        uint256 collateral_ = collateral[poolId][msg.sender];
        uint256 minCollateral = msg.sender == pool.strategist ? pool.rent * MIN_COLLATERAL_BLOCKS : 0;

        // Check user has enough balance to withdraw
        if (collateral_ < amount + minCollateral) {
            revert NotEnoughCollateral();
        }

        collateral[poolId][msg.sender] -= amount;

        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, amount)));
    }

    /// @notice Modify bid or usurp the current strategist of a pool by paying a higher rent
    function modifyBid(PoolKey calldata key, address strategy, address feeRecipient, uint256 rent) external {
        // Distribute unpaid rent to LPs
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, 0)));

        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Revert if sender has not deposited enough collateral
        uint256 minCollateral = rent * MIN_COLLATERAL_BLOCKS;
        if (collateral[poolId][msg.sender] < minCollateral) {
            revert NotEnoughCollateral();
        }

        // Bid is too low so can't modify
        if (msg.sender == pool.strategist && rent < pool.rent && block.number <= pool.lastUsurpBlock + COOLDOWN_BLOCKS)
        {
            revert RentTooLowDuringCooldown();
        }

        // Bid is too low so can't usurp
        if (msg.sender != pool.strategist && rent < pool.rent * MIN_USURP_FACTOR / 1 ether) {
            revert RentTooLow();
        }

        // Update state
        if (msg.sender != pool.strategist) {
            pool.lastUsurpBlock = block.number;
        }
        pool.strategist = msg.sender;
        pool.strategy = strategy;
        pool.feeRecipient = feeRecipient;
        pool.rent = rent;
    }

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.depositAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.rentInTokenZero ? data.key.currency0 : data.key.currency1;
            currency.take(poolManager, address(this), data.depositAmount, true); // Mint 6909
            currency.settle(poolManager, data.sender, data.depositAmount, false); // Transfer ERC20
        }
        if (data.withdrawAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.rentInTokenZero ? data.key.currency0 : data.key.currency1;
            currency.settle(poolManager, address(this), data.withdrawAmount, true); // Burn 6909
            currency.take(poolManager, data.sender, data.withdrawAmount, false); // Claim ERC20
        }

        _distributeRent(data.key);
        return "";
    }

    /// @dev Must be called while lock is acquired.
    function _distributeRent(PoolKey memory key) internal {
        PoolState storage pool = pools[key.toId()];
        uint256 rentAmount = pool.rent * (block.number - pool.lastRentPaidBlock);
        pool.lastRentPaidBlock = block.number;
        if (rentAmount == 0) return;

        uint256 strategistCollateral = collateral[key.toId()][pool.strategist];
        bool isLiquidate = strategistCollateral < rentAmount;
        if (isLiquidate) {
            rentAmount = strategistCollateral;
        }

        uint256 amount0 = pool.rentInTokenZero ? rentAmount : 0;
        uint256 amount1 = pool.rentInTokenZero ? 0 : rentAmount;

        _settleOrTake(key, address(this), -amount0.toInt256(), -amount1.toInt256(), true);

        // Deduct from strategist's collateral
        collateral[key.toId()][pool.strategist] -= rentAmount;

        // Distribute to in-range LPs
        // TODO: ensure there is liquidity when donating
        poolManager.donate(key, amount0, amount1, "");

        // If strategist doesn't have enough collateral to pay rent and wasn't liquidated in time, remove them as strategist
        if (isLiquidate) {
            _removeStrategist(key);
        }
    }

    /// @notice Calls `settle` or `take` depending on the signs of `delta0` and `delta1`
    function _settleOrTake(PoolKey memory key, address user, int256 delta0, int256 delta1, bool useClaims) internal {
        if (delta0 < 0) key.currency0.settle(poolManager, user, uint256(-delta0), useClaims);
        if (delta1 < 0) key.currency1.settle(poolManager, user, uint256(-delta1), useClaims);
        if (delta0 > 0) key.currency0.take(poolManager, user, uint256(delta0), useClaims);
        if (delta1 > 0) key.currency1.take(poolManager, user, uint256(delta1), useClaims);
    }

    /// @notice Get the collateral deposited by `user` for pool `key`.
    function getDeposit(PoolKey calldata key, address user) external view returns (uint256) {
        return collateral[key.toId()][user];
    }

    /// @notice Liquidate current strategist if their balance is not sufficient to pay rent. Can be called by anyone.
    function liquidate(PoolKey calldata key) external {
        // Distribute unpaid rent to LPs
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, 0)));

        // Check if strategist is liquidatable
        PoolState storage pool = pools[key.toId()];
        if (collateral[key.toId()][pool.strategist] > pool.rent * LIQUIDATION_BLOCKS) {
            revert NotLiquidatable();
        }
        _removeStrategist(key);
    }

    /// @notice Reset strategist and strategy for a pool if they are liquidated.
    function _removeStrategist(PoolKey memory key) internal {
        PoolState storage pool = pools[key.toId()];
        pool.strategist = address(0);
        pool.strategy = address(0);
        pool.feeRecipient = address(0);
        pool.rent = 0;
        pool.lastUsurpBlock = block.number;
    }
}
