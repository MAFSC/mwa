// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title MWAPriceHook
 * @notice Uniswap v4 hook, который:
 *         - Отслеживает цену RWA через Chainlink оракул
 *         - Хранит anchor price для каждого пула
 *         - Обеспечивает read-only доступ к цене для MWARedemption
 *
 *         ВАЖНО: в Uniswap v4 функции-хуки называются `_beforeSwap` / `_afterSwap`
 *         и уже имеют проверку `onlyPoolManager` в BaseHook.
 */
contract MWAPriceHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    AggregatorV3Interface public priceFeed;

    // Якорные цены по poolId
    mapping(bytes32 => uint256) public anchorPrices;

    // Цены по адресам RWA-активов (обновляется вручную или оракулом)
    mapping(address => uint256) public referencePrices;

    // Права на обновление цен
    address public priceAdmin;

    event PriceUpdated(bytes32 indexed poolId, uint256 newPrice);
    event ReferencePriceUpdated(address indexed asset, uint256 price);
    event PriceFeedUpdated(address newPriceFeed);
    event PriceAdminUpdated(address newAdmin);

    modifier onlyPriceAdmin() {
        require(msg.sender == priceAdmin, "MWAPriceHook: only admin");
        _;
    }

    constructor(IPoolManager _poolManager, address _priceFeed, address _priceAdmin)
        BaseHook(_poolManager)
    {
        priceFeed = AggregatorV3Interface(_priceFeed);
        priceAdmin = _priceAdmin;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Внутренний хук после свапа — обновляет anchor price
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        uint256 currentPrice = uint256(price);

        bytes32 poolId = PoolId.unwrap(key.toId());
        anchorPrices[poolId] = currentPrice;

        emit PriceUpdated(poolId, currentPrice);

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Получить reference price для RWA-актива.
     *         Если задана вручную — возвращает её, иначе — из Chainlink.
     */
    function getReferencePrice(address asset) external view returns (uint256) {
        uint256 manual = referencePrices[asset];
        if (manual > 0) return manual;

        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    /// @notice Получить anchor price для пула
    function getAnchorPrice(PoolKey calldata key) external view returns (uint256) {
        return anchorPrices[PoolId.unwrap(key.toId())];
    }

    /// @notice Установить reference price для RWA вручную (только admin)
    function setReferencePrice(address asset, uint256 price) external onlyPriceAdmin {
        referencePrices[asset] = price;
        emit ReferencePriceUpdated(asset, price);
    }

    /// @notice Установить anchor price для пула (только admin)
    function setAnchorPrice(address asset, uint256 price) external onlyPriceAdmin {
        referencePrices[asset] = price;
        emit ReferencePriceUpdated(asset, price);
    }

    /// @notice Обновить Chainlink оракул (только admin)
    function setPriceFeed(address newPriceFeed) external onlyPriceAdmin {
        priceFeed = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(newPriceFeed);
    }

    /// @notice Сменить админа цен
    function setPriceAdmin(address newAdmin) external onlyPriceAdmin {
        priceAdmin = newAdmin;
        emit PriceAdminUpdated(newAdmin);
    }
}
