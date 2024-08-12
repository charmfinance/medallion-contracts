// SPDX-License-Identifier: UNLICENSED
// TODO: Decide on license
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "v4-core/../test/utils/CurrencySettler.sol"; // TODO: Is this the right library to use?
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
 * @notice A Uniswap V4 hook that auctions off right to dynamically set and receive all swap fees
 * @dev This code is a proof-of-concept and must not be used in production
 *
 * TODO: Extend IHooks instead of BaseHook?
 * TODO: Implement `liquidate` function to liquidate managers
 */
contract NeptuneHook is BaseHook {
    // TODO: Clean up unused libraries
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
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
        address strategist;
        address strategy; // Current attached strategy contract. Zero address if none attached.
        address feeRecipient; // Fee recipient specified by strategist
        uint256 rent;
        uint256 lastRentPaidBlock;
        uint256 lastUsurpBlock;
        bool rentInTokenZero; // TODO: Find better way
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => PoolState) public pools;

    /// @notice How much collateral user has deposited into the contract.
    mapping(PoolId => mapping(address => uint256)) public collateral;

    // Swap fee used when no strategy set
    // TODO: Think of a better way than having the same fee across all pools
    uint24 DEFAULT_SWAP_FEE = 3000; // 30 bps swap fee

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

    /// @notice Ensure dynamic fee flag is set.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        onlyByPoolManager
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

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        // Distribute unpaid rent to LPs
        _payRent(key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Call strategy to calculate swap fees and redirect the fees to the strategist.
    // TODO: Add support for `maxFee` parameter specified in swap
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Distribute unpaid rent to LPs
        _payRent(key);

        // If no strategy is set, LPs get the default fee like in a hookless Uniswap pool
        PoolState storage pool = pools[key.toId()];
        if (address(pool.strategy) == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Call strategy contract to get swap fee.
        // TODO: Implement.
        uint128 fee = IStrategy(pool.strategy).calculateSwapFee(key, params);

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
        take(feeCurrency, poolManager, pool.feeRecipient, absFees.toUint256(), true);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments
    /// as the manager.
    // TODO: Emit event
    function depositCollateral(PoolKey calldata key, uint256 amount) external {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, amount, 0)));

        collateral[key.toId()][msg.sender] += amount;
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `deposit`.
    // TODO: Emit event
    function withdrawCollateral(PoolKey calldata key, uint256 amount) external {
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

        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, amount)));
    }

    /// @notice Modify bid or usurp the current strategist of a pool by paying a higher rent
    // TODO: Figure out a way to avoid gas wars when multiple managers want to usurp when rent is low
    // TODO: Emit event
    function modifyBid(PoolKey calldata key, address strategy, address feeRecipient, uint256 rent) external {
        // Distribute unpaid rent to LPs
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, 0)));

        PoolId poolId = key.toId();
        PoolState storage pool = pools[poolId];

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

    // TODO: Check don't need onlyByPoolManager modifier
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.depositAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.rentInTokenZero ? data.key.currency0 : data.key.currency1;
            take(currency, poolManager, address(this), data.depositAmount, true); // Mint 6909
            settle(currency, poolManager, data.sender, data.depositAmount, false); // Transfer ERC20
        }
        if (data.withdrawAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.rentInTokenZero ? data.key.currency0 : data.key.currency1;
            settle(currency, poolManager, address(this), data.withdrawAmount, true); // Burn 6909
            take(currency, poolManager, data.sender, data.withdrawAmount, false); // Claim ERC20
        }

        _payRent(data.key);
        return "";
    }

    // TODO: Emit event
    function _payRent(PoolKey memory key) internal {
        PoolState storage pool = pools[key.toId()];
        uint256 rentAmount = pool.rent * (block.number - pool.lastRentPaidBlock);
        pool.lastRentPaidBlock = block.number;
        if (rentAmount == 0) return;

        uint256 amount0 = pool.rentInTokenZero ? rentAmount : 0;
        uint256 amount1 = pool.rentInTokenZero ? 0 : rentAmount;

        _settleOrTake(key, address(this), -amount0.toInt256(), -amount1.toInt256(), true);

        // Deduct from strategist's collateral
        collateral[key.toId()][pool.strategist] -= rentAmount;

        // Distribute to in-range LPs
        // TODO: ensure there is liquidity when donating
        poolManager.donate(key, amount0, amount1, "");
    }

    /// @notice Calls `settle` or `take` depending on the signs of `delta0` and `delta1`
    function _settleOrTake(PoolKey memory key, address user, int256 delta0, int256 delta1, bool useClaims) internal {
        if (delta0 < 0) settle(key.currency0, poolManager, user, uint256(-delta0), useClaims);
        if (delta1 < 0) settle(key.currency1, poolManager, user, uint256(-delta1), useClaims);
        if (delta0 > 0) take(key.currency0, poolManager, user, uint256(delta0), useClaims);
        if (delta1 > 0) take(key.currency1, poolManager, user, uint256(delta1), useClaims);
    }

    /// @notice Settle (pay) a currency to the PoolManager
    /// @dev From https://github.com/Uniswap/v4-core/blob/main/test/utils/CurrencySettler.sol
    /// @param currency Currency to settle
    /// @param manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isNative()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @dev From https://github.com/Uniswap/v4-core/blob/main/test/utils/CurrencySettler.sol
    /// @param currency Currency to take
    /// @param manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }

    function getDeposit(PoolKey calldata key, address user) external view returns (uint256) {
        return collateral[key.toId()][user];
    }
}
