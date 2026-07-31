// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// Упрощенный интерфейс Chainlink AggregatorV3Interface
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

contract MWAPriceHook is BaseHook {
    AggregatorV3Interface public priceFeed;
    
    // Хранилище для "якорной" цены
    mapping(bytes32 => uint256) public anchorPrices;
    
    // События
    event PriceUpdated(bytes32 indexed poolId, uint256 newPrice);
    event PriceFeedUpdated(address newPriceFeed);

    constructor(IPoolManager _poolManager, address _priceFeed) BaseHook(_poolManager) {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // Устанавливаем флаги хука (только afterSwap)
    function getHookCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Хук после свапа — обновляем якорную цену
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4) {
        // Получаем актуальную цену от оракула
        (, int256 price, , , ) = priceFeed.latestRoundData();
        uint256 currentPrice = uint256(price);
        
        // Сохраняем цену для этого пула
        bytes32 poolId = keccak256(abi.encode(key));
        anchorPrices[poolId] = currentPrice;
        
        emit PriceUpdated(poolId, currentPrice);
        
        return this.afterSwap.selector;
    }

    // Получение текущей цены от оракула
    function getReferencePrice() external view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }
    
    // Получение сохраненной якорной цены для пула
    function getAnchorPrice(PoolKey calldata key) external view returns (uint256) {
        bytes32 poolId = keccak256(abi.encode(key));
        return anchorPrices[poolId];
    }
    
    // Обновление адреса оракула (только владелец)
    function setPriceFeed(address newPriceFeed) external {
        require(msg.sender == address(this), "Only hook itself can update");
        priceFeed = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(newPriceFeed);
    }
}
