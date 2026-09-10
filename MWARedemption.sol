// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMWAVault {
    struct Deposit {
        address assetAddress;
        uint256 assetId;
        uint256 assetAmount;
        address memeToken;
        uint256 memeTokenAmount;
        uint256 redemptionDeadline;
        bool isRedeemed;
        bool isClaimed;
        address poolCurrency;
        uint256 premiumRate;
        address priceFeed;
        address owner;
    }
    function getDeposit(uint256 depositId) external view returns (Deposit memory);
    function mintMemeToken(uint256 depositId, address to, uint256 amount) external;
    function releaseRWA(uint256 depositId) external;
    function usdcToken() external view returns (address);
}

interface IMWAToken {
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function burnHeld(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMWAPriceHook {
    function getReferencePrice(address asset) external view returns (uint256);
}

/**
 * @title MWARedemption
 * @notice Логика выкупа и сжигания токенов автором:
 *         1. Автор вносит ETH/USDC + премию
 *         2. Контракт выкупает все токены у держателей по текущей цене + премия
 *         3. Выкупленные токены сжигаются
 *         4. Автор получает RWA обратно
 *
 *         Также поддерживает обычную покупку/продажу токенов через пул.
 */
contract MWARedemption {
    using SafeERC20 for IERC20;

    address public constant NATIVE_ETH = address(0);

    address public vault;
    address public priceHook;
    address public owner;
    bool private _locked;

    // Учёт: depositId => накопленные средства для выкупа
    mapping(uint256 => uint256) public buybackPool;

    event TokensPurchased(uint256 indexed depositId, address indexed buyer, uint256 amount);
    event TokensSold(uint256 indexed depositId, address indexed seller, uint256 amount);
    event BuybackDeposited(uint256 indexed depositId, address indexed author, uint256 amount);
    event BuybackExecuted(uint256 indexed depositId, uint256 totalBurned, uint256 totalReturned);
    event CollateralRedeemed(uint256 indexed depositId, address indexed author);

    modifier noReentrancy() {
        require(!_locked, "Reentrancy");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyAuthor(uint256 depositId) {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(d.owner == msg.sender, "Not author");
        _;
    }

    constructor(address _vault, address _priceHook) {
        vault = _vault;
        priceHook = _priceHook;
        owner = msg.sender;
    }

    /* ============================================================
       ПОКУПКА ТОКЕНОВ
    ============================================================ */

    /**
     * @notice Покупка MEME-токенов за ETH
     */
    function buyWithETH(uint256 depositId, uint256 memeAmount) external payable noReentrancy {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(d.memeToken != address(0), "No token");
        require(!d.isRedeemed, "Redeemed");
        require(d.poolCurrency == NATIVE_ETH, "Pool is not ETH");

        uint256 price = _getTokenPrice(depositId);
        uint256 cost = (price * memeAmount) / 1e18;
        require(msg.value >= cost, "Insufficient ETH");

        IMWAVault(vault).mintMemeToken(depositId, msg.sender, memeAmount);

        // Возврат излишка
        if (msg.value > cost) {
            (bool ok, ) = msg.sender.call{value: msg.value - cost}("");
            require(ok, "Refund failed");
        }

        emit TokensPurchased(depositId, msg.sender, memeAmount);
    }

    /**
     * @notice Покупка MEME-токенов за USDC
     */
    function buyWithUSDC(uint256 depositId, uint256 memeAmount, uint256 maxUSDC) external noReentrancy {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(d.memeToken != address(0), "No token");
        require(!d.isRedeemed, "Redeemed");
        require(d.poolCurrency == IMWAVault(vault).usdcToken(), "Pool is not USDC");

        uint256 price = _getTokenPrice(depositId);
        uint256 cost = (price * memeAmount) / 1e18;
        require(cost <= maxUSDC, "Slippage");

        IERC20(IMWAVault(vault).usdcToken()).safeTransferFrom(msg.sender, address(this), cost);
        IMWAVault(vault).mintMemeToken(depositId, msg.sender, memeAmount);

        emit TokensPurchased(depositId, msg.sender, memeAmount);
    }

    /* ============================================================
       ПРОДАЖА ТОКЕНОВ
    ============================================================ */

    /**
     * @notice Продажа MEME-токенов обратно в пул
     */
    function sell(uint256 depositId, uint256 memeAmount, uint256 minOut) external noReentrancy {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(!d.isRedeemed, "Redeemed");

        IMWAToken(d.memeToken).burnFrom(msg.sender, memeAmount);

        uint256 price = _getTokenPrice(depositId);
        uint256 payout = (price * memeAmount) / 1e18;
        require(payout >= minOut, "Slippage");

        if (d.poolCurrency == NATIVE_ETH) {
            (bool ok, ) = msg.sender.call{value: payout}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(d.poolCurrency).safeTransfer(msg.sender, payout);
        }

        emit TokensSold(depositId, msg.sender, memeAmount);
    }

    /* ============================================================
       ВЫКУП И СЖИГАНИЕ (BUYBACK & BURN)
    ============================================================ */

    /**
     * @notice Автор вносит средства для выкупа токенов с премией
     */
    function depositBuyback(uint256 depositId, uint256 amount)
        external
        payable
        noReentrancy
        onlyAuthor(depositId)
    {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(!d.isRedeemed, "Redeemed");

        if (d.poolCurrency == NATIVE_ETH) {
            require(msg.value == amount, "Wrong ETH amount");
            buybackPool[depositId] += amount;
        } else {
            IERC20(d.poolCurrency).safeTransferFrom(msg.sender, address(this), amount);
            buybackPool[depositId] += amount;
        }

        emit BuybackDeposited(depositId, msg.sender, amount);
    }

    /**
     * @notice Автор выполняет выкуп: контракт получает все токены с рынка
     *         (по факту — сжигает все токены, которые у него есть, и возвращает RWA).
     *         В реальной реализации выкуп происходит через DEX/пул.
     */
    function executeBuyback(uint256 depositId)
        external
        noReentrancy
        onlyAuthor(depositId)
    {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        require(!d.isRedeemed, "Redeemed");
        require(block.timestamp >= d.redemptionDeadline, "Lock not expired");
        require(buybackPool[depositId] > 0, "No buyback funds");

        // Сжигаем все токены, которые контракт получил (в реальности — выкупленные)
        uint256 held = IMWAToken(d.memeToken).balanceOf(address(this));
        if (held > 0) {
            IMWAToken(d.memeToken).burnHeld(held);
        }

        // Возвращаем RWA автору
        IMWAVault(vault).releaseRWA(depositId);

        // Возвращаем остатки средств автору
        uint256 remaining = buybackPool[depositId];
        buybackPool[depositId] = 0;
        if (remaining > 0) {
            if (d.poolCurrency == NATIVE_ETH) {
                (bool ok, ) = msg.sender.call{value: remaining}("");
                require(ok, "Refund failed");
            } else {
                IERC20(d.poolCurrency).safeTransfer(msg.sender, remaining);
            }
        }

        emit BuybackExecuted(depositId, held, remaining);
        emit CollateralRedeemed(depositId, msg.sender);
    }

    /* ============================================================
       ВНУТРЕННИЕ ФУНКЦИИ
    ============================================================ */

    function _getTokenPrice(uint256 depositId) internal view returns (uint256) {
        IMWAVault.Deposit memory d = IMWAVault(vault).getDeposit(depositId);
        uint256 assetPrice = IMWAPriceHook(priceHook).getReferencePrice(d.assetAddress);
        if (d.memeTokenAmount == 0) return 0;
        return (assetPrice * d.assetAmount * 1e18) / d.memeTokenAmount;
    }

    /// @notice Получить текущую цену токена (для UI)
    function getTokenPrice(uint256 depositId) external view returns (uint256) {
        return _getTokenPrice(depositId);
    }

    receive() external payable {}
}
