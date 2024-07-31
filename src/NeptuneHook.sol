// SPDX-License-Identifier: UNLICENSED
// TODO: Decide on license
pragma solidity ^0.8.25;

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol"; // TODO: Use test/utils/CurrencySettler.sol instead?
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// TODO: Move to its own file
// TODO: Add example strategies
interface IStrategy {
    function calculateSwapFee(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (uint128);
}

/**
 * @title Neptune Hook
 * @author Charm Finance
 * @notice A Uniswap V4 hook that auctions off right to dynamically set and receive all swap fees
 * @dev This code is a proof-of-concept and must not be used in production
 */
contract NeptuneHook is BaseHook {
    // TODO: Clean up unused libraries
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error NotEnoughCollateral();
    error PoolMustBeDynamicFee();
    error SenderIsAlreadyStrategist();
    error RentTooLow();
    error RentTooLowDuringCooldown();
    error SenderMustBeStrategist();

    /// @notice State stored for each pool.
    struct PoolState {
        IStrategy strategy; // Current attached strategy contract. Zero address if none attached.
        address feeRecipient; // Fee recipient specified by strategist
        uint256 rent;
        uint256 lastRentPaidBlock;
        uint256 lastUsurpBlock;
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 donateAmount0;
        uint256 donateAmount1;
    }

    mapping(PoolId => PoolState) public pools;

    /// @notice How much collateral user has deposited into the contract.
    mapping(PoolId => mapping(address => uint256)) public collateral;

    // Swap fee used when no strategy set
    // TODO: Think of a better way than having the same fee across all pools
    uint128 DEFAULT_SWAP_FEE = 3000; // 30 bps swap fee

    uint256 MIN_USURP_FACTOR = 1.2e18; // 1.2x rent increase to usurp
    uint256 COOLDOWN_BLOCKS = 100; // Cannot decrease bid for 100 blocks after newly becoming manager
    uint256 MIN_COLLATERAL_BLOCKS = 100; // Minimum collateral to withdraw

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Specify hook permissions.
    /// `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
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

    /// @notice Ensure dynamic fee flag is set and the given `hookData` is valid and set up initial
    /// pool state.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert PoolMustBeDynamicFee();

        // Initialize pool state
        // TODO: Uncomment if we need to actually initialize state
        // PoolId poolId = key.toId();
        // pools[poolId] = PoolState({
        //     strategy: address(0)
        // });

        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        // Distribute unpaid rent to LPs
        _pokeRent(key);
    }

    /// @notice Call strategy to calculate swap fees and redirect the fees to the strategist.
    // TODO: Add support for `maxFee` parameter specified in swap
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Distribute unpaid rent to LPs
        _pokeRent(key);

        // If no strategy is set, LPs get the default fee like in a hookless Uniswap pool
        PoolState storage pool = pools[key.toId()];
        if (pool.strategy == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Call strategy contract to get swap fee.
        // TODO: Implement.
        uint128 fee = strategy.calculateSwapFee(key, params);

        // Calculate swap fees. The fees don't go to LPs, they instead go to the `feeRecipient` specified by the strategist.
        int256 fees = params.amountSpecified * uint256(fee).toInt256() / 1e6;
        int256 absFees = fees > 0 ? fees : -fees;

        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in
        // so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // Send fees to `feeRecipient`
        // TODO: Support both claim and erc20 transfer?
        feeCurrency.take(poolManager, feeRecipient, absFees.toUint256(), true);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments
    /// as the manager.
    // TODO: Emit event
    function depositCollateral(PoolKey calldata key, uint256 amount) external {
        PoolState storage pool = pools[key.toId()];
        collateral[key.toId()][msg.sender] += amount;

        // Receive tokens from user
        // TODO: Figure out a way to determine currency
        Currency currency = key.currency0;
        IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `deposit`.
    // TODO: Emit event
    function withdrawCollateral(PoolKey calldata key, uint256 amount) external {
        // Distribute unpaid rent to LPs
        _pokeRent(key);

        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

        // Get user's up-to-date balance
        uint256 collateral_ = collateral[poolId][msg.sender];
        uint256 minCollateral = pool.rent * MIN_COLLATERAL_BLOCKS;

        // Check user has enough balance to withdraw
        if (collateral_ < amount + minCollateral) {
            revert NotEnoughCollateral();
        }

        collateral[poolId][msg.sender] -= amount;

        // Send tokens to user
        // TODO: Figure out a way to determine currency
        Currency currency = key.currency0;
        IERC20(Currency.unwrap(currency)).transfer(msg.sender, amount);
    }

    /// @notice Modify the rent if already the strategist.
    /// @param key The pool to bid in
    /// @param rent The amount of tokens to pay per block to LPs. The token is determined by `payInTokenZero`
    // TODO: Emit event
    function modifyBid(PoolKey calldata key, uint256 rent) external {
        // Distribute unpaid rent to LPs
        _pokeRent(key);

        PoolState storage pool = pools[key.toId()];
        if (msg.sender != pool.manager) revert SenderMustBeStrategist();
        if (rent < pool.rent && block.number <= pool.lastUsurpBlock + COOLDOWN_BLOCKS) {
            revert RentTooLowDuringCooldown();
        }

        uint256 minCollateral = rent * MIN_COLLATERAL_BLOCKS;
        if (collateral[poolId][msg.sender] < minCollateral) {
            revert NotEnoughCollateral();
        }

        pool.rent = rent;
    }

    /// @notice Usurp the current strategist of a pool by paying a higher rent
    // TODO: Figure out a way to avoid gas wars when multiple managers want to usurp when rent is low
    // TODO: Emit event
    function usurp(PoolKey calldata key, address strategy, address feeRecipient, uint256 rent) external {
        // Distribute unpaid rent to LPs
        _pokeRent(key);

        PoolState storage pool = pools[key.toId()];
        if (msg.sender == pool.manager) revert SenderIsAlreadyStrategist();
        if (rent < pool.rent * MIN_USURP_FACTOR / 1 ether) revert RentTooLow();

        uint256 minCollateral = rent * MIN_COLLATERAL_BLOCKS;
        if (collateral[poolId][msg.sender] < minCollateral) {
            revert NotEnoughCollateral();
        }

        lastUsurpBlock = block.number;
        pool.strategy = strategy;
        pool.feeRecipient = feeRecipient;
        pool.rent = rent;
    }

    function _pokeRent(PoolKey calldata key) internal {
        PoolState storage pool = pools[key.toId()];
        uint256 rentAmount = pool.rent * (block.number - pool.lastRentPaidBlock);
        pool.lastRentPaidBlock = block.number;

        // TODO: Fix after deciding which token to pay rent in
        poolManager.unlock(abi.encode(CallbackData(key, pool.manager, 0, rentAmount)));
    }

    // TODO: Emit event
    function unlockCallback(bytes calldata rawData) external override poolManagerOnly returns (bytes memory) {
        // Take rent amount from this contract
        _settleOrTake(data.key, address(this), -data.donateAmount0.toInt256(), -data.donateAmount1.toInt256(), false);

        // Deduct from strategist's collateral
        // TODO: Figure out a way to determine currency
        collateral[data.key.toId()][data.sender] -= data.donateAmount0;

        // Distribute to in-range LPs
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        poolManager.donate(data.key, data.donateAmount0, data.donateAmount1, "");
    }

    /// @notice Calls `settle` or `take` depending on the signs of `delta0` and `delta1`
    function _settleOrTake(PoolKey memory key, address user, int256 delta0, int256 delta1, bool useClaims) internal {
        if (delta0 < 0) key.currency0.settle(poolManager, user, uint256(-delta0), useClaims);
        if (delta1 < 0) key.currency1.settle(poolManager, user, uint256(-delta1), useClaims);
        if (delta0 > 0) key.currency0.take(poolManager, user, uint256(delta0), useClaims);
        if (delta1 > 0) key.currency1.take(poolManager, user, uint256(delta1), useClaims);
    }
}
