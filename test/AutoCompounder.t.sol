// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "src/AutoCompounder.sol";
import "src/CompoundOptimizer.sol";
import "src/AutoCompounderFactory.sol";

import "@velodrome/test/BaseTest.sol";

contract AutoCompounderTest is BaseTest {
    uint256 tokenId;
    uint256 mTokenId;

    AutoCompounderFactory autoCompounderFactory;
    AutoCompounder autoCompounder;
    CompoundOptimizer optimizer;
    LockedManagedReward lockedManagedReward;
    FreeManagedReward freeManagedReward;

    address[] bribes;
    address[] fees;
    address[][] tokensToClaim;
    address[] tokensToSwap;
    uint256[] slippages;
    address[] tokensToSweep;
    address[] recipients;

    constructor() {
        deploymentType = Deployment.FORK;
    }

    function _setUp() public override {
        // create managed veNFT
        vm.prank(escrow.allowedManager());
        mTokenId = escrow.createManagedLockFor(address(owner));
        lockedManagedReward = LockedManagedReward(escrow.managedToLocked(mTokenId));
        freeManagedReward = FreeManagedReward(escrow.managedToFree(mTokenId));

        vm.startPrank(address(owner));

        // Create normal veNFT and deposit into managed
        deal(address(VELO), address(owner), TOKEN_1);
        VELO.approve(address(escrow), TOKEN_1);
        tokenId = escrow.createLock(TOKEN_1, MAXTIME);

        skipToNextEpoch(1 hours + 1);
        voter.depositManaged(tokenId, mTokenId);

        // Create auto compounder
        optimizer = new CompoundOptimizer(
            address(USDC),
            address(WETH),
            address(FRAX), // OP
            address(VELO),
            address(factory),
            address(router)
        );
        autoCompounderFactory = new AutoCompounderFactory(
            address(forwarder),
            address(voter),
            address(router),
            address(optimizer),
            address(factoryRegistry),
            new address[](0)
        );
        escrow.approve(address(autoCompounderFactory), mTokenId);
        autoCompounder = AutoCompounder(autoCompounderFactory.createAutoCompounder(address(owner), mTokenId, ""));

        skipToNextEpoch(1 hours + 1);

        vm.stopPrank();

        // Add the owner as a keeper
        vm.prank(escrow.team());
        autoCompounderFactory.addKeeper(address(owner));

        // Create a VELO pool for USDC, WETH, and FRAX (seen as OP in CompoundOptimizer)
        deal(address(VELO), address(owner), TOKEN_100K * 3);
        deal(address(WETH), address(owner), TOKEN_1 * 3);

        // @dev these pools have a higher VELO price value than v1 pools
        _createPoolAndSimulateSwaps(address(USDC), address(VELO), USDC_1, TOKEN_1, address(USDC), 10, 3);
        _createPoolAndSimulateSwaps(address(WETH), address(VELO), TOKEN_1, TOKEN_100K, address(VELO), 1e6, 3);
        _createPoolAndSimulateSwaps(address(FRAX), address(VELO), TOKEN_1, TOKEN_1, address(VELO), 1e6, 3);
        _createPoolAndSimulateSwaps(address(FRAX), address(DAI), TOKEN_1, TOKEN_1, address(FRAX), 1e6, 3);

        tokensToSwap.push(address(USDC));
        tokensToSwap.push(address(FRAX));
        tokensToSwap.push(address(DAI));

        // 5% slippage
        slippages.push(500);
        slippages.push(500);
        slippages.push(500);

        // skip to last day where claiming becomes public
        skipToNextEpoch(6 days + 1);
    }

    function _createPoolAndSimulateSwaps(
        address token1,
        address token2,
        uint256 liquidity1,
        uint256 liquidity2,
        address tokenIn,
        uint256 amountSwapped,
        uint256 numSwapped
    ) internal {
        address tokenOut = tokenIn == token1 ? token2 : token1;
        _addLiquidityToPool(address(owner), address(router), token1, token2, false, liquidity1, liquidity2);

        IRouter.Route[] memory routes = new IRouter.Route[](1);

        // for every hour, simulate a swap to add an observation
        for (uint256 i = 0; i < numSwapped; i++) {
            skipAndRoll(1 hours);
            routes[0] = IRouter.Route(tokenIn, tokenOut, false, address(0));

            IERC20(tokenIn).approve(address(router), amountSwapped);
            router.swapExactTokensForTokens(amountSwapped, 0, routes, address(owner), block.timestamp);
        }
    }

    function testCannotSwapIfNoRouteFound() public {
        // Create a new pool with liquidity that doesn't swap into VELO
        IERC20 tokenA = IERC20(new MockERC20("Token A", "A", 18));
        IERC20 tokenB = IERC20(new MockERC20("Token B", "B", 18));
        deal(address(tokenA), address(owner), TOKEN_1 * 2, true);
        deal(address(tokenB), address(owner), TOKEN_1 * 2, true);
        _createPoolAndSimulateSwaps(address(tokenA), address(tokenB), TOKEN_1, TOKEN_1, address(tokenA), 1e6, 3);

        // give rewards to the autoCompounder
        deal(address(tokenA), address(autoCompounder), 1e6);

        // Attempt swapping into VELO - should revert
        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(tokenA);
        slippages = new uint256[](1);
        slippages[0] = 0;
        vm.expectRevert(IAutoCompounder.NoRouteFound.selector);
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, tokensToSwap, slippages);

        // Cannot swap for a token that doesn't have a pool
        IERC20 tokenC = IERC20(new MockERC20("Token C", "C", 18));
        deal(address(tokenC), address(autoCompounder), 1e6);

        tokensToSwap[0] = address(tokenC);

        // Attempt swapping into VELO - should revert
        vm.expectRevert(IAutoCompounder.NoRouteFound.selector);
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, tokensToSwap, slippages);
    }

    function testSwapToVELOAndCompoundWithCompoundRewardAmount() public {
        // Deal USDC, FRAX, and DAI to autocompounder to simulate earning bribes
        // NOTE: the low amount of bribe rewards leads to receiving 1% of the reward amount
        deal(address(USDC), address(autoCompounder), 1e2);
        deal(address(FRAX), address(autoCompounder), 1e6);
        deal(address(DAI), address(autoCompounder), 1e6);

        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);
        uint256 balanceVELOBefore = VELO.balanceOf(address(owner4));

        // Random user calls swapToVELO()
        vm.prank(address(owner4));
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, tokensToSwap, slippages);

        // USDC and FRAX converted even though they already have a direct pair to VELO
        // DAI converted without a direct pair to VELO
        assertEq(USDC.balanceOf(address(autoCompounder)), 0);
        assertEq(FRAX.balanceOf(address(autoCompounder)), 0);
        assertEq(DAI.balanceOf(address(autoCompounder)), 0);
        assertEq(VELO.balanceOf(address(autoCompounder)), 0);

        uint256 rewardAmountToNFT = escrow.balanceOfNFT(mTokenId) - balanceNFTBefore;
        uint256 rewardAmountToCaller = VELO.balanceOf(address(owner4)) - balanceVELOBefore;

        assertGt(rewardAmountToNFT, 0);
        assertGt(rewardAmountToCaller, 0);
        assertLt(rewardAmountToCaller, autoCompounderFactory.rewardAmount());

        // total reward is 100x what caller received - as caller received 1% the total reward
        assertEq((rewardAmountToNFT + rewardAmountToCaller) / 100, rewardAmountToCaller);
    }

    function testSwapToVELOAndCompoundWithFactoryRewardAmount() public {
        // Adjust the factory reward rate to a lower VELO to trigger the rewardAmount.
        // NOTE: this will not be needed in prod as more than 0.00000001 DAI etc. will
        // be compounded at one time
        vm.prank(escrow.team());
        autoCompounderFactory.setRewardAmount(1e17);

        // Deal USDC, WETH, and DAI to autocompounder to simulate earning bribe rewards
        // NOTE; the difference here is WETH for a higher amount of VELO swapped
        tokensToSwap[1] = address(WETH);
        deal(address(USDC), address(autoCompounder), 1e3);
        deal(address(WETH), address(autoCompounder), 1e15);
        deal(address(DAI), address(autoCompounder), 1e6);

        uint256 balanceVELOCallerBefore = VELO.balanceOf(address(owner4));
        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);

        // Random user calls swapToVELO()
        vm.prank(address(owner4));
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, tokensToSwap, slippages);

        // USDC and FRAX converted even though they already have a direct pair to VELO
        // DAI converted without a direct pair to VELO
        assertEq(USDC.balanceOf(address(autoCompounder)), 0);
        assertEq(WETH.balanceOf(address(autoCompounder)), 0);
        assertEq(DAI.balanceOf(address(autoCompounder)), 0);
        assertEq(VELO.balanceOf(address(autoCompounder)), 0);

        // Compounded into the mTokenId and caller has received a refund equal to the factory rewardAmount
        assertEq(VELO.balanceOf(address(owner4)), balanceVELOCallerBefore + autoCompounderFactory.rewardAmount());
        assertGt(escrow.balanceOfNFT(mTokenId), balanceNFTBefore);
    }

    function testSwapTokensToVELOAndCompoundClaimRebaseOnly() public {
        address[] memory pools = new address[](2);
        pools[0] = address(pool);
        pools[1] = address(pool2);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 1;
        weights[1] = 1;

        autoCompounder.vote(pools, weights);

        skipToNextEpoch(6 days + 1);
        minter.updatePeriod();

        uint256 claimable = distributor.claimable(mTokenId);
        assertGt(distributor.claimable(mTokenId), 0);

        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, new address[](0), new uint256[](0));
        assertEq(escrow.balanceOfNFT(mTokenId), balanceNFTBefore + claimable);
    }

    function testSwapTokensToVELOAndCompoundOnlyExistingVELOBalance() public {
        deal(address(VELO), address(autoCompounder), 1e18);

        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);

        vm.prank(address(owner2));
        autoCompounder.claimBribesAndCompound(bribes, tokensToClaim, new address[](0), new uint256[](0));

        // mTokenId has received the full VELO balance from the autoCompounder - meaning
        // the VELO has been directly compounded without a swap (minus fee)
        assertEq(escrow.balanceOfNFT(mTokenId), balanceNFTBefore + 1e18 - 1e16);
        assertEq(VELO.balanceOf(address(autoCompounder)), 0);
    }

    function testSwapTokensToVELOAndCompoundOptionalRouteBetterRate() public {
        // create a new pool with
        //  - liquidity of the token swapped to the mock token
        //  - liquidity of the mock token to VELO to return a lot of VELO
        // And add mock token as a high liquidity token
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        autoCompounderFactory.addHighLiquidityToken(address(mockToken));
        deal(address(mockToken), address(owner), TOKEN_1 * 3);
        deal(address(VELO), address(owner), TOKEN_100M + TOKEN_1 * 3);

        _createPoolAndSimulateSwaps(address(mockToken), address(FRAX), TOKEN_1, TOKEN_1, address(FRAX), 1e6, 3);
        _createPoolAndSimulateSwaps(address(mockToken), address(VELO), TOKEN_1, TOKEN_100M, address(VELO), TOKEN_1, 3);

        // simulate reward
        deal(address(FRAX), address(autoCompounder), 1e6);

        IRouter.Route[][] memory optionalRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        routes[0] = IRouter.Route(address(FRAX), address(mockToken), false, address(0));
        routes[1] = IRouter.Route(address(mockToken), address(VELO), false, address(0));
        optionalRoutes[0] = routes;

        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(FRAX);
        slippages = new uint256[](1);
        slippages[0] = 500;

        uint256[] memory amountsOut = router.getAmountsOut(1e6, routes);
        uint256 amountOut = amountsOut[amountsOut.length - 1];
        uint256 balanceOwnerBefore = VELO.balanceOf(address(owner));
        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);

        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, optionalRoutes, slippages);

        // validate the amount received by caller and balance increased to (m)veNFT equal
        // the amount out of the optionalRoute over the CompoundOptimizer suggested route
        uint256 balanceOwnerDelta = VELO.balanceOf(address(owner)) - balanceOwnerBefore;
        uint256 balanceNFTDelta = escrow.balanceOfNFT(mTokenId) - balanceNFTBefore;
        assertEq(balanceOwnerDelta + balanceNFTDelta, amountOut);
    }

    function testSwapTokensToVELOAndCompoundOptionalRouteBetterRateFromHighLiquidityToken() public {
        // create a new pool with
        //  - liquidity of the token swapped to the mock token
        //  - liquidity of the mock token to VELO to return a lot of VELO
        // Add mock token and token swapping from as high liquidity tokens
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        autoCompounderFactory.addHighLiquidityToken(address(mockToken));
        autoCompounderFactory.addHighLiquidityToken(address(FRAX));
        deal(address(mockToken), address(owner), TOKEN_1 * 3);
        deal(address(VELO), address(owner), TOKEN_100M + TOKEN_1 * 3);

        _createPoolAndSimulateSwaps(address(mockToken), address(FRAX), TOKEN_1, TOKEN_1, address(FRAX), 1e6, 3);
        _createPoolAndSimulateSwaps(address(mockToken), address(VELO), TOKEN_1, TOKEN_100M, address(VELO), TOKEN_1, 3);

        // simulate reward
        deal(address(FRAX), address(autoCompounder), 1e6);

        IRouter.Route[][] memory optionalRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        routes[0] = IRouter.Route(address(FRAX), address(mockToken), false, address(0));
        routes[1] = IRouter.Route(address(mockToken), address(VELO), false, address(0));
        optionalRoutes[0] = routes;

        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(FRAX);
        slippages = new uint256[](1);
        slippages[0] = 500;

        uint256[] memory amountsOut = router.getAmountsOut(1e6, routes);
        uint256 amountOut = amountsOut[amountsOut.length - 1];
        uint256 balanceOwnerBefore = VELO.balanceOf(address(owner));
        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);

        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, optionalRoutes, slippages);

        // validate the amount received by caller and balance increased to (m)veNFT equal
        // the amount out of the optionalRoute over the CompoundOptimizer suggested route
        uint256 balanceOwnerDelta = VELO.balanceOf(address(owner)) - balanceOwnerBefore;
        uint256 balanceNFTDelta = escrow.balanceOfNFT(mTokenId) - balanceNFTBefore;
        assertEq(balanceOwnerDelta + balanceNFTDelta, amountOut);
    }

    function testCannotSwapTokensToVELOAndCompoundOptionalRouteIfDoesNotUseHighLiquidityToken() public {
        // create a new pool with
        //  - liquidity of the token swapped to the mock token
        //  - liquidity of the mock token to VELO to return a lot of VELO
        // Mock Token is not added as a high liquidity token, so will revert
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        deal(address(mockToken), address(owner), TOKEN_1 * 3);
        deal(address(VELO), address(owner), TOKEN_100M + TOKEN_1 * 3);

        _createPoolAndSimulateSwaps(address(mockToken), address(FRAX), TOKEN_1, TOKEN_1, address(FRAX), 1e6, 3);
        _createPoolAndSimulateSwaps(address(mockToken), address(VELO), TOKEN_1, TOKEN_100M, address(VELO), TOKEN_1, 3);

        // simulate reward
        deal(address(FRAX), address(autoCompounder), 1e6);

        IRouter.Route[][] memory optionalRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        routes[0] = IRouter.Route(address(FRAX), address(mockToken), false, address(0));
        routes[1] = IRouter.Route(address(mockToken), address(VELO), false, address(0));
        optionalRoutes[0] = routes;

        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(FRAX);
        slippages = new uint256[](1);
        slippages[0] = 500;

        vm.expectRevert(IAutoCompounder.NotHighLiquidityToken.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, optionalRoutes, slippages);
    }

    function testSwapTokensToVELOAndCompoundOptionalRouteOnlyRoute() public {
        // create a new pool with
        //  - liquidity of the mock token to VELO
        // For a token that does NOT have a route supported by CompoundOptimizer
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        deal(address(mockToken), address(owner), TOKEN_1 * 3);
        deal(address(VELO), address(owner), TOKEN_100M + TOKEN_1 * 3);

        _createPoolAndSimulateSwaps(address(mockToken), address(VELO), TOKEN_1, TOKEN_100M, address(VELO), TOKEN_1, 3);

        // simulate reward
        deal(address(mockToken), address(autoCompounder), 1e6);

        IRouter.Route[][] memory optionalRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(mockToken), address(VELO), false, address(0));
        optionalRoutes[0] = routes;

        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(mockToken);
        slippages = new uint256[](1);
        slippages[0] = 500;

        uint256[] memory amountsOut = router.getAmountsOut(1e6, routes);
        uint256 amountOut = amountsOut[amountsOut.length - 1];
        uint256 balanceOwnerBefore = VELO.balanceOf(address(owner));
        uint256 balanceNFTBefore = escrow.balanceOfNFT(mTokenId);

        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, optionalRoutes, slippages);

        // validate the amount received by caller and balance increased to (m)veNFT equal
        // the amount out of the optionalRoute
        uint256 balanceOwnerDelta = VELO.balanceOf(address(owner)) - balanceOwnerBefore;
        uint256 balanceNFTDelta = escrow.balanceOfNFT(mTokenId) - balanceNFTBefore;
        assertEq(balanceOwnerDelta + balanceNFTDelta, amountOut);
    }

    function testIncreaseAmount() public {
        uint256 amount = TOKEN_1;
        deal(address(VELO), address(owner), amount);
        VELO.approve(address(autoCompounder), amount);

        uint256 balanceBefore = escrow.balanceOfNFT(mTokenId);
        uint256 supplyBefore = escrow.totalSupply();

        autoCompounder.increaseAmount(amount);

        assertEq(escrow.balanceOfNFT(mTokenId), balanceBefore + amount);
        assertEq(escrow.totalSupply(), supplyBefore + amount);
    }

    function testVote() public {
        address[] memory poolVote = new address[](1);
        uint256[] memory weights = new uint256[](1);
        poolVote[0] = address(pool2);
        weights[0] = 1;

        assertFalse(escrow.voted(mTokenId));

        autoCompounder.vote(poolVote, weights);

        assertTrue(escrow.voted(mTokenId));
        assertEq(voter.weights(address(pool2)), escrow.balanceOfNFT(mTokenId));
        assertEq(voter.votes(mTokenId, address(pool2)), escrow.balanceOfNFT(mTokenId));
        assertEq(voter.poolVote(mTokenId, 0), address(pool2));
    }

    function testSwapTokenToVELOAndCompound() public {
        uint256 amount = TOKEN_1 / 100;
        deal(address(WETH), address(autoCompounder), amount);

        uint256 balanceBefore = escrow.balanceOfNFT(mTokenId);
        uint256 veloBalanceBefore = VELO.balanceOf(address(owner));

        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(WETH), address(VELO), false, address(0));
        uint256[] memory amountsOut = router.getAmountsOut(amount, routes);
        uint256 amountOut = amountsOut[amountsOut.length - 1];
        assertGt(amountOut, 0);

        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        allRoutes[0] = routes;
        amountsIn[0] = amount;
        amountsOutMin[0] = 1;
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );

        // no reward given to caller this time- full amount deposited into mTokenId
        assertEq(VELO.balanceOf(address(owner)), veloBalanceBefore);
        assertEq(escrow.balanceOfNFT(mTokenId), balanceBefore + amountOut);
    }

    function testCannotInitializeTwice() external {
        vm.prank(address(autoCompounder.autoCompounderFactory()));
        vm.expectRevert(IAutoCompounder.AlreadyInitialized.selector);
        autoCompounder.initialize(1);
    }

    function testCannotInitializeIfNotFactory() external {
        vm.expectRevert(IAutoCompounder.NotFactory.selector);
        autoCompounder.initialize(1);
    }

    function testCannotClaimIfNotOnLastDayOfEpoch() external {
        address[] memory rewards = new address[](0);
        tokensToClaim = new address[][](0);
        tokensToSwap = new address[](0);
        slippages = new uint256[](0);

        skipToNextEpoch(0);
        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.claimBribesAndCompound(rewards, tokensToClaim, tokensToSwap, slippages);

        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.claimFeesAndCompound(rewards, tokensToClaim, tokensToSwap, slippages);

        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);

        skipToNextEpoch(6 days - 1);
        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.claimBribesAndCompound(rewards, tokensToClaim, tokensToSwap, slippages);

        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.claimFeesAndCompound(rewards, tokensToClaim, tokensToSwap, slippages);

        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);
    }

    function testCannotSwapIfSlippageTooHigh() public {
        slippages[0] = 501;
        vm.expectRevert(IAutoCompounder.SlippageTooHigh.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);
    }

    function testCannotSwapIfUnequalLengths() public {
        slippages = new uint256[](2);
        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);
    }

    function testCannotSwapIfAmountInZero() public {
        vm.expectRevert(IAutoCompounder.AmountInZero.selector);
        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);
    }

    function testHandleRouterApproval() public {
        deal(address(FRAX), address(autoCompounder), TOKEN_1 / 1000, true);

        // give a fake approval to impersonate a dangling approved amount
        vm.prank(address(autoCompounder));
        FRAX.approve(address(router), 100);

        // resets and properly approves swap amount
        tokensToSwap = new address[](1);
        tokensToSwap[0] = address(FRAX);
        slippages = new uint256[](1);
        slippages[0] = 500;

        autoCompounder.swapTokensToVELOAndCompound(tokensToSwap, slippages);
        assertEq(FRAX.allowance(address(autoCompounder), address(router)), 0);
    }

    // TODO: order tests similar to AutoCompounder with section titles
    function testCannotSweepAfterFirstDayOfEpoch() public {
        skipToNextEpoch(1 days + 1);
        vm.expectRevert(IAutoCompounder.TooLate.selector);
        autoCompounder.claimBribesAndSweep(bribes, tokensToClaim, tokensToSweep, recipients);
        vm.expectRevert(IAutoCompounder.TooLate.selector);
        autoCompounder.claimFeesAndSweep(fees, tokensToClaim, tokensToSweep, recipients);
        vm.expectRevert(IAutoCompounder.TooLate.selector);
        autoCompounder.sweep(tokensToSweep, recipients);
    }

    function testCannotSweepIfNotAdmin() public {
        skipToNextEpoch(1 days - 1);
        bytes memory revertString = bytes(
            "AccessControl: account 0x7d28001937fe8e131f76dae9e9947adedbd0abde is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
        );
        vm.startPrank(address(owner2));
        vm.expectRevert(revertString);
        autoCompounder.claimBribesAndSweep(bribes, tokensToClaim, tokensToSweep, recipients);
        vm.expectRevert(revertString);
        autoCompounder.claimFeesAndSweep(fees, tokensToClaim, tokensToSweep, recipients);
        vm.expectRevert(revertString);
        autoCompounder.sweep(tokensToSweep, recipients);
    }

    function testCannotSweepUnequalLengths() public {
        skipToNextEpoch(1 days - 1);
        recipients.push(address(owner2));
        assertTrue(tokensToSweep.length != recipients.length);
        vm.prank(escrow.team());
        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.sweep(tokensToSweep, recipients);
    }

    function testCannotSweepHighLiquidityToken() public {
        skipToNextEpoch(1 days - 1);
        tokensToSweep.push(address(USDC));
        recipients.push(address(owner2));
        vm.prank(escrow.team());
        autoCompounderFactory.addHighLiquidityToken(address(USDC));
        vm.expectRevert(IAutoCompounder.HighLiquidityToken.selector);
        autoCompounder.sweep(tokensToSweep, recipients);
    }

    function testCannotSweepZeroAddressRecipient() public {
        skipToNextEpoch(1 days - 1);
        tokensToSweep.push(address(USDC));
        recipients.push(address(0));
        vm.prank(escrow.team());
        vm.expectRevert(IAutoCompounder.ZeroAddress.selector);
        autoCompounder.sweep(tokensToSweep, recipients);
    }

    function testSweep() public {
        skipToNextEpoch(1 days - 1);
        tokensToSweep.push(address(USDC));
        recipients.push(address(owner2));
        deal(address(USDC), address(autoCompounder), USDC_1);
        uint256 balanceBefore = USDC.balanceOf(address(owner2));
        vm.prank(escrow.team());
        autoCompounder.sweep(tokensToSweep, recipients);
        assertEq(USDC.balanceOf(address(owner2)), balanceBefore + USDC_1);
    }

    function testCannotSwapKeeperIfWithinFirstDayOfEpoch() public {
        skipToNextEpoch(1 days - 1);
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](2);
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);

        vm.expectRevert(IAutoCompounder.TooSoon.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperUnequalLengths() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](2);
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);

        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );

        amountsIn = new uint256[](2);
        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );

        amountsIn = new uint256[](1);
        amountsOutMin = new uint256[](2);
        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );

        amountsIn = new uint256[](2);
        allRoutes = new IRouter.Route[][](1);
        vm.expectRevert(IAutoCompounder.UnequalLengths.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperIfNotKeeper() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](2);
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);

        vm.startPrank(address(owner2));
        vm.expectRevert(IAutoCompounder.NotKeeper.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperIfAmountInZero() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);
        vm.expectRevert(IAutoCompounder.AmountInZero.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperIfSlippageTooHigh() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);
        amountsIn[0] = 1;
        vm.expectRevert(IAutoCompounder.SlippageTooHigh.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperIfInvalidPath() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(0), address(0), false, address(0));
        allRoutes[0] = routes;
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);
        amountsIn[0] = 1;
        amountsOutMin[0] = 1;
        vm.expectRevert(IAutoCompounder.InvalidPath.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testCannotSwapKeeperIfAmountInTooHigh() public {
        IRouter.Route[][] memory allRoutes = new IRouter.Route[][](1);
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route(address(WETH), address(VELO), false, address(0));
        allRoutes[0] = routes;
        uint256[] memory amountsIn = new uint256[](1);
        uint256[] memory amountsOutMin = new uint256[](1);
        amountsIn[0] = 1;
        amountsOutMin[0] = 1;
        vm.expectRevert(IAutoCompounder.AmountInTooHigh.selector);
        autoCompounder.claimAndCompoundKeeper(
            bribes,
            tokensToClaim,
            fees,
            tokensToClaim,
            allRoutes,
            amountsIn,
            amountsOutMin
        );
    }

    function testName() public {
        // Create autoCompounder with a name
        vm.prank(escrow.allowedManager());
        mTokenId = escrow.createManagedLockFor(address(owner));

        vm.startPrank(address(owner));
        escrow.approve(address(autoCompounderFactory), mTokenId);
        escrow.setApprovalForAll(address(owner2), true);
        vm.stopPrank();
        vm.prank(address(owner2));
        autoCompounder = AutoCompounder(autoCompounderFactory.createAutoCompounder(address(owner), mTokenId, "Test"));

        assertEq(autoCompounder.name(), "Test");

        // Create an autoCompounder without a name
        vm.prank(escrow.allowedManager());
        mTokenId = escrow.createManagedLockFor(address(owner));

        vm.startPrank(address(owner));
        escrow.approve(address(autoCompounderFactory), mTokenId);
        escrow.setApprovalForAll(address(owner2), true);
        vm.stopPrank();
        vm.prank(address(owner2));
        autoCompounder = AutoCompounder(autoCompounderFactory.createAutoCompounder(address(owner), mTokenId, ""));

        assertEq(autoCompounder.name(), "");
    }

    function testSetName() public {
        assertEq(autoCompounder.name(), "");
        vm.startPrank(address(owner));
        autoCompounder.setName("New name");
        assertEq(autoCompounder.name(), "New name");
        autoCompounder.setName("Second new name");
        assertEq(autoCompounder.name(), "Second new name");
    }

    function testCannotSetNameIfNotAdmin() public {
        bytes memory revertString = bytes(
            "AccessControl: account 0x7d28001937fe8e131f76dae9e9947adedbd0abde is missing role 0x0000000000000000000000000000000000000000000000000000000000000000"
        );
        vm.startPrank(address(owner2));
        vm.expectRevert(revertString);
        autoCompounder.setName("Some totally new name");
    }
}
