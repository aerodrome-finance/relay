// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IConverterOptimizer} from "../interfaces/IConverterOptimizer.sol";

import {IRouter} from "@velodrome/contracts/interfaces/IRouter.sol";
import {IPoolFactory} from "@velodrome/contracts/interfaces/factories/IPoolFactory.sol";
import {IPool} from "@velodrome/contracts/interfaces/IPool.sol";

/// @notice Helper contract to calculate optimal amountOut from the Velodrome v2 Router
/// @author velodrome.finance, @pegahcarter, @pedrovalido
contract ConverterOptimizer is IConverterOptimizer {
    address public immutable weth;
    address public immutable usdc;
    address public immutable op;
    address public immutable velo;
    address public immutable factory;
    IRouter public immutable router;

    constructor(address _usdc, address _weth, address _op, address _velo, address _factory, address _router) {
        weth = _weth;
        usdc = _usdc;
        op = _op;
        velo = _velo;
        factory = _factory;
        router = IRouter(_router);
    }

    function _getRoutesTokenToToken(
        address token0,
        address token1
    ) internal view returns (IRouter.Route[2][7] memory routesTokenToToken, uint256 length) {
        // caching
        address _usdc = usdc;
        address _weth = weth;
        address _op = op;
        address _velo = velo;
        address _factory = factory;

        // Create routes for routesTokenToToken
        if (token1 != _usdc) {
            // token0 <> USDC <> token1
            // from <stable v2> USDC <> token1
            routesTokenToToken[0][0] = IRouter.Route(token0, _usdc, true, _factory);
            // from <volatile v2> USDC <> token1
            routesTokenToToken[1][0] = IRouter.Route(token0, _usdc, false, _factory);

            routesTokenToToken[0][1] = IRouter.Route(_usdc, token1, false, _factory);
            routesTokenToToken[1][1] = IRouter.Route(_usdc, token1, false, _factory);
            length = 2;
        }
        if (token1 != _weth) {
            // from <> WETH <> token1
            // from <stable v2> WETH <> token1
            routesTokenToToken[length][0] = IRouter.Route(token0, _weth, true, _factory);
            // from <volatile v2> WETH <> token1
            routesTokenToToken[length + 1][0] = IRouter.Route(token0, _weth, false, _factory);

            routesTokenToToken[length][1] = IRouter.Route(_weth, token1, false, _factory);
            routesTokenToToken[length + 1][1] = IRouter.Route(_weth, token1, false, _factory);
            length += 2;
        }
        if (token1 != _op) {
            // from <> OP <> token1
            // from <volatile v2> OP <> token1
            routesTokenToToken[length][0] = IRouter.Route(token0, _op, false, _factory);
            routesTokenToToken[length][1] = IRouter.Route(_op, token1, false, _factory);
            length++;
        }

        if (token1 != _velo) {
            // token0 <> VELO <> token1
            // from <stable v2> VELO <> token1
            routesTokenToToken[length][0] = IRouter.Route(token0, _velo, true, _factory);
            // from <volatile v2> VELO <> token1
            routesTokenToToken[length + 1][0] = IRouter.Route(token0, _velo, false, _factory);

            routesTokenToToken[length][1] = IRouter.Route(_velo, token1, false, _factory);
            routesTokenToToken[length + 1][1] = IRouter.Route(_velo, token1, false, _factory);
            length += 2;
        }
    }

    /// @inheritdoc IConverterOptimizer
    function getOptimalTokenToTokenRoute(
        address token0,
        address token1,
        uint256 amountIn
    ) external view returns (IRouter.Route[] memory) {
        // Get best route from multi-route paths
        uint256 index;
        uint256 optimalAmountOut;
        IRouter.Route[] memory routes = new IRouter.Route[](2);
        uint256[] memory amountsOut;

        (IRouter.Route[2][7] memory routesTokenToToken, uint256 length) = _getRoutesTokenToToken(token0, token1);
        // loop through multi-route paths
        for (uint256 i = 0; i < length; i++) {
            routes[0] = routesTokenToToken[i][0];
            routes[1] = routesTokenToToken[i][1];

            // Go to next route if a trading pool does not exist
            if (IPoolFactory(routes[0].factory).getPair(routes[0].from, routes[0].to, routes[0].stable) == address(0)) {
                continue;
            }

            amountsOut = router.getAmountsOut(amountIn, routes);
            // amountOut is in the third index - 0 is amountIn and 1 is the first route output
            uint256 amountOut = amountsOut[2];
            if (amountOut > optimalAmountOut) {
                // store the index and amount of the optimal amount out
                optimalAmountOut = amountOut;
                index = i;
            }
        }
        // use the optimal route determined from the loop
        routes[0] = routesTokenToToken[index][0];
        routes[1] = routesTokenToToken[index][1];

        // Get amountOut from a direct route to token1
        IRouter.Route[] memory route = new IRouter.Route[](1);
        route[0] = IRouter.Route(token0, token1, false, factory);
        amountsOut = router.getAmountsOut(amountIn, route);
        uint256 singleSwapAmountOut = amountsOut[1];

        // compare output and return the best result
        return singleSwapAmountOut > optimalAmountOut ? route : routes;
    }

    /// @inheritdoc IConverterOptimizer
    function getOptimalAmountOutMin(
        IRouter.Route[] calldata routes,
        uint256 amountIn,
        uint256 points,
        uint256 slippage
    ) external view returns (uint256 amountOutMin) {
        if (points < 2) revert NotEnoughPoints();
        uint256 length = routes.length;

        for (uint256 i = 0; i < length; i++) {
            IRouter.Route memory route = routes[i];
            if (route.factory == address(0)) route.factory = factory;
            address pool = IPoolFactory(route.factory).getPair(route.from, route.to, route.stable);
            // Return 0 if the pool does not exist
            if (pool == address(0)) return 0;
            uint256 amountOut = IPool(pool).quote(route.from, amountIn, points);
            // Overwrite amountIn assuming we're using the TWAP for the next route swap
            amountIn = amountOut;
        }

        // At this point, amountIn is actually amountOut as we finished the loop
        amountOutMin = (amountIn * (10_000 - slippage)) / 10_000;
    }
}
