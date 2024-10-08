// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";

import {MedallionHook} from "../src/MedallionHook.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedFeeStrategy} from "../src/strategies/FixedFeeStrategy.sol";

contract TestMedallionHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    address constant ALICE = address(0x1001);
    address constant BOB = address(0x1002);

    int24 constant TICK_SPACING = 60;
    bytes constant INIT_PARAMS = "";

    MedallionHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy our hook
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("MedallionHook.sol", abi.encode(manager), hookAddress);
        hook = MedallionHook(hookAddress);

        // Also approve hook to spend our tokens
        IERC20(Currency.unwrap(currency0)).approve(hookAddress, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddress, type(uint256).max);

        // Initialize a pool with 1% fee
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hook);
        manager.initialize(key, SQRT_PRICE_1_1, INIT_PARAMS);

        // Add some liquidity
        seedMoreLiquidity(key, 100 ether, 100 ether);

        // Set up users
        _setUpUser(ALICE);
        _setUpUser(BOB);
    }

    function _setUpUser(address user) internal {
        // Mint tokens for user
        MockERC20(Currency.unwrap(currency0)).mint(user, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user, 1000 ether);

        // Approve hook to spend user's tokens
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_beforeInitialize_revertsIfNotDynamicFee() public {
        uint24 feeWithNoDynamicFlag = 100;
        PoolKey memory badKey = PoolKey(currency0, currency1, feeWithNoDynamicFlag, TICK_SPACING, hook);

        // Should fail because no dynamic fee flag is set
        // The error should be `FailedHookCall` with the revertReason parameter set to `PoolMustBeDynamicFee`
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.FailedHookCall.selector, abi.encodeWithSelector(MedallionHook.PoolMustBeDynamicFee.selector)
            )
        );
        manager.initialize(badKey, SQRT_PRICE_1_1, INIT_PARAMS);
    }

    function test_modifyBid_usurp() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);
        vm.prank(BOB);
        hook.depositCollateral(key, 100 ether);

        // Alice bids and becomes strategist
        address strategy_ = address(0x1);
        address feeRecipient_ = address(0x2);
        uint256 rent_ = 12345;
        vm.prank(ALICE);
        hook.modifyBid(key, strategy_, feeRecipient_, rent_);

        // Check pool state
        address strategist;
        address strategy;
        address feeRecipient;
        uint256 rent;
        uint256 lastUsurpBlock;
        (strategist, strategy, feeRecipient, rent,, lastUsurpBlock,) = hook.pools(key.toId());
        assertEq(strategist, ALICE);
        assertEq(strategy, strategy_);
        assertEq(feeRecipient, feeRecipient_);
        assertEq(rent, rent_);
        assertEq(lastUsurpBlock, block.number);

        // Skip time forwards by 120 blocks
        vm.roll(block.number + 120);

        // Bob places higher bid and becomes strategist
        strategy_ = address(0x2);
        feeRecipient_ = address(0x3);
        rent_ = 23456;
        vm.prank(BOB);
        hook.modifyBid(key, strategy_, feeRecipient_, rent_);

        // Check pool state
        (strategist, strategy, feeRecipient, rent,, lastUsurpBlock,) = hook.pools(key.toId());
        assertEq(strategist, BOB);
        assertEq(strategy, strategy_);
        assertEq(feeRecipient, feeRecipient_);
        assertEq(rent, rent_);
        assertEq(lastUsurpBlock, block.number);
    }

    function test_modifyBid_increaseBid() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Alice bids and becomes strategist
        address strategy_ = address(0x1);
        address feeRecipient_ = address(0x2);
        uint256 rent_ = 12345;
        vm.prank(ALICE);
        hook.modifyBid(key, strategy_, feeRecipient_, rent_);

        uint256 firstBidBlock = block.number;

        // Skip block forwards by 120 blocks
        vm.roll(block.number + 120);

        // Increase bid
        rent_ = 23456;
        vm.prank(ALICE);
        hook.modifyBid(key, strategy_, feeRecipient_, rent_);

        // Check pool state
        uint256 rent;
        uint256 lastUsurpBlock;
        (,,, rent,, lastUsurpBlock,) = hook.pools(key.toId());
        assertEq(rent, rent_);
        assertEq(lastUsurpBlock, firstBidBlock);
    }

    function test_usurp_revertsIfNotEnoughCollateral() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 1000);

        // Should fail because user doesn't have enough collateral
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.NotEnoughCollateral.selector));
        vm.prank(BOB);
        hook.modifyBid(key, address(0), address(0), 12345);
    }

    function test_modifyBid_revertsIfUsurpWithBidTooLow() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);
        vm.prank(BOB);
        hook.depositCollateral(key, 100 ether);

        // Bid and become strategist
        vm.prank(ALICE);
        hook.modifyBid(key, address(0), address(0), 1000);

        // Should fail because rent is too low. It should be higher than current rent plus buffer
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RentTooLow.selector));
        vm.prank(BOB);
        hook.modifyBid(key, address(0), address(0), 1001);
    }

    function test_modifyBid_reduceBidAfterCooldown() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Bid and become strategist
        vm.prank(ALICE);
        hook.modifyBid(key, address(0), address(0), 1000);

        // Skip time forwards by 120 blocks
        vm.roll(block.number + 120);

        // Reduce bid
        uint256 rent_ = 500;
        vm.prank(ALICE);
        hook.modifyBid(key, address(0), address(0), rent_);

        // Check pool state
        uint256 rent;
        (,,, rent,,,) = hook.pools(key.toId());
        assertEq(rent, rent_);
    }

    function test_depositCollateral() public {
        Currency currency = currency1;

        uint256 balance = IERC20(Currency.unwrap(currency)).balanceOf(ALICE);

        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        uint256 balance2 = IERC20(Currency.unwrap(currency)).balanceOf(ALICE);
        assertEq(balance - balance2, 100 ether);

        // Check hook owns the claim tokens
        assertEq(manager.balanceOf(address(hook), currency.toId()), 100 ether);
    }

    function test_withdrawCollateral() public {
        Currency currency = currency1;

        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        uint256 balance = IERC20(Currency.unwrap(currency)).balanceOf(ALICE);

        vm.prank(ALICE);
        hook.withdrawCollateral(key, 100 ether);

        uint256 balance2 = IERC20(Currency.unwrap(currency)).balanceOf(ALICE);
        assertEq(balance2 - balance, 100 ether);

        // Check hook no longer owns the claim tokens
        assertEq(manager.balanceOf(address(hook), currency.toId()), 0);
    }

    function test_modifyBid_rentIsCharged() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Params for lp router
        // TODO: Remove
        // IPoolManager.ModifyLiquidityParams public LIQUIDITY_PARAMS =
        //     IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
        // IPoolManager.ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS =
        //     IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});

        uint256 balance0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        // Bid and become strategist
        vm.prank(ALICE);
        hook.modifyBid(key, address(0), address(0), 1e12);

        // Skip time forwards by 120 blocks
        vm.roll(block.number + 120);

        uint256 expectedRent = 120 * 1e12;
        uint256 depositBefore = hook.getDeposit(key, ALICE);
        uint256 claimBalanceBefore = manager.balanceOf(address(hook), currency1.toId()); // TODO: make currency choice depend on `payInTokenZero`

        // Poke
        vm.prank(ALICE);
        hook.modifyBid(key, address(0), address(0), 1e12);

        // Check rent was charged from Alice and from hook's claim balance
        assertEq(hook.getDeposit(key, ALICE), depositBefore - expectedRent);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), claimBalanceBefore - expectedRent);

        // Check LP was paid in currency1
        // TODO: make currency choice depend on `payInTokenZero`
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertApproxEqAbs(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), balance0, 5);
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), balance1 + 1000);
    }

    function test_modifyBid_bidTooHigh() public {
        // Deposit collateral
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Deploy fixed 1% fee strategy
        FixedFeeStrategy strategy = new FixedFeeStrategy(10000);

        // Bid and become strategist. Collateral can cover 10 blocks.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.NotEnoughCollateral.selector));
        hook.modifyBid(key, address(strategy), address(0), 100 ether / 10);
    }

    function test_modifyBid_automaticallyLiquidateIfOutOfCollateral() public {
        // Deposit collateral
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Deploy fixed 1% fee strategy
        FixedFeeStrategy strategy = new FixedFeeStrategy(10000);

        // Bid and become strategist. Collateral can cover 100 blocks.
        vm.prank(ALICE);
        hook.modifyBid(key, address(strategy), address(0), 100 ether / 100);

        // Skip time forwards by 200 blocks
        vm.roll(block.number + 200);

        // Do small swap so that rent is paid
        _swap(key, true, 0.000_001 ether);

        // Check pool state. Not enough collateral so strategist should have been automatically liquidated
        address strategist;
        address strategy_;
        address feeRecipient;
        uint256 rent;
        uint256 lastUsurpBlock;
        (strategist, strategy_, feeRecipient, rent,, lastUsurpBlock,) = hook.pools(key.toId());
        assertEq(strategist, address(0));
        assertEq(strategy_, address(0));
        assertEq(feeRecipient, address(0));
        assertEq(rent, 0);
        assertEq(lastUsurpBlock, block.number);
    }

    function test_beforeSwap() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Deploy fixed 1% fee strategy
        FixedFeeStrategy strategy = new FixedFeeStrategy(10000);

        // Bid and become strategist
        vm.prank(ALICE);
        hook.modifyBid(key, address(strategy), address(0), 1000);

        // Do small swap
        BalanceDelta delta = _swap(key, true, 0.000_001 ether);
        int128 loss = 1e18 + delta.amount1() * 1e18 / delta.amount0();

        // Check loss is 1%
        assertApproxEqRel(int256(loss).toUint256(), 0.01e18, 0.01e18);
    }

    function test_liquidate() public {
        // Deposit enough collateral to cover the bid
        vm.prank(ALICE);
        hook.depositCollateral(key, 100 ether);

        // Deploy fixed 1% fee strategy
        FixedFeeStrategy strategy = new FixedFeeStrategy(10000);

        // Bid and become strategist. Collateral can cover 100 blocks.
        vm.prank(ALICE);
        hook.modifyBid(key, address(strategy), address(0), 100 ether / 100);

        // Skip time forwards by 98 blocks
        vm.roll(block.number + 98);

        // Liquidate
        vm.prank(BOB);
        hook.liquidate(key);

        // Check pool state
        address strategist;
        address strategy_;
        address feeRecipient;
        uint256 rent;
        uint256 lastUsurpBlock;
        (strategist, strategy_, feeRecipient, rent,, lastUsurpBlock,) = hook.pools(key.toId());
        assertEq(strategist, address(0));
        assertEq(strategy_, address(0));
        assertEq(feeRecipient, address(0));
        assertEq(rent, 0);
        assertEq(lastUsurpBlock, block.number);
    }

    /// @notice Helper method to do a swap without a slippage limit
    function _swap(PoolKey memory key_, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = swapRouter.swap(
            key_,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            settings,
            ZERO_BYTES
        );
    }
}
