// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IMWATokenFactory {
    function createToken(string memory name, string memory symbol, address vault) external returns (address);
}

interface IMWAPriceHook {
    function getReferencePrice(address asset) external view returns (uint256);
    function setAnchorPrice(address asset, uint256 price) external;
}

/**
 * @title MWAVault
 * @notice Хранилище RWA-залогов. Поддерживает:
 *         - Блокировку RWA (ERC721) или ERC20
 *         - Настройку валюты пула (ETH или USDC)
 *         - Настройку премии за выкуп (3/5/10%)
 *         - Создание MEME-токена при депозите
 */
contract MWAVault is Ownable {
    using SafeERC20 for IERC20;

    // Адрес WETH или native ETH (address(0) = ETH)
    address public constant NATIVE_ETH = address(0);

    struct Deposit {
        address assetAddress;      // RWA: ERC721 или ERC20
        uint256 assetId;           // для ERC721; для ERC20 = 0
        uint256 assetAmount;       // количество RWA (для ERC20); для ERC721 = 1
        address memeToken;         // созданный MEME токен
        uint256 memeTokenAmount;   // общий supply MEME
        uint256 redemptionDeadline;// когда автор может выкупить
        bool isRedeemed;           // был ли выкуп
        bool isClaimed;            // был ли claim (для покупателей)
        address poolCurrency;      // ETH (address(0)) или USDC
        uint256 premiumRate;       // 3, 5, 10 (%)
        address priceFeed;         // оракул цены RWA
        address owner;             // автор депозита
    }

    // Хранилище депозитов
    mapping(uint256 => Deposit) public deposits;
    uint256 public depositCounter;

    // Адреса
    address public mwaTokenFactory;
    address public priceOracle;
    address public usdcToken;     // адрес USDC на Robinhood Chain
    address public redemption;    // адрес MWARedemption

    bool private _locked;

    event AssetDeposited(
        uint256 indexed depositId,
        address indexed owner,
        address memeToken,
        uint256 assetAmount,
        uint256 memeTokenAmount
    );
    event AssetRedeemed(uint256 indexed depositId, address indexed redeemer);
    event AssetClaimed(uint256 indexed depositId, address indexed claimer, uint256 share);
    event FactoryUpdated(address factory);
    event OracleUpdated(address oracle);
    event UsdcUpdated(address usdc);
    event RedemptionUpdated(address redemption);

    modifier noReentrancy() {
        require(!_locked, "MWAVault: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyRedemption() {
        require(msg.sender == redemption, "MWAVault: only redemption");
        _;
    }

    constructor(
        address _mwaTokenFactory,
        address _priceOracle,
        address _usdcToken
    ) Ownable(msg.sender) {
        mwaTokenFactory = _mwaTokenFactory;
        priceOracle = _priceOracle;
        usdcToken = _usdcToken;
    }

    /**
     * @notice Блокировка RWA (ERC721) и создание MEME-токена
     * @param assetAddress Адрес RWA-контракта (ERC721)
     * @param assetId ID токена RWA
     * @param tokenAmount Количество MEME-токенов к выпуску (supply)
     * @param lockDuration Секунды до разблокировки
     * @param poolCurrency Адрес валюты пула (address(0) = ETH, иначе USDC)
     * @param premiumRate Премия за выкуп (3, 5, 10)
     * @param tokenName Имя MEME-токена
     * @param tokenSymbol Символ MEME-токена
     */
    function depositRWA(
        address assetAddress,
        uint256 assetId,
        uint256 tokenAmount,
        uint256 lockDuration,
        address poolCurrency,
        uint256 premiumRate,
        string memory tokenName,
        string memory tokenSymbol
    ) external noReentrancy returns (uint256 depositId) {
        require(tokenAmount > 0, "MWAVault: zero supply");
        require(premiumRate == 3 || premiumRate == 5 || premiumRate == 10, "MWAVault: invalid premium");
        require(
            poolCurrency == NATIVE_ETH || poolCurrency == usdcToken,
            "MWAVault: invalid pool currency"
        );

        // Переводим RWA в vault
        IERC721(assetAddress).transferFrom(msg.sender, address(this), assetId);

        // Создаём MEME-токен через фабрику
        address memeToken = IMWATokenFactory(mwaTokenFactory).createToken(
            tokenName,
            tokenSymbol,
            address(this)
        );

        depositId = ++depositCounter;

        deposits[depositId] = Deposit({
            assetAddress: assetAddress,
            assetId: assetId,
            assetAmount: 1,
            memeToken: memeToken,
            memeTokenAmount: tokenAmount,
            redemptionDeadline: block.timestamp + lockDuration,
            isRedeemed: false,
            isClaimed: false,
            poolCurrency: poolCurrency,
            premiumRate: premiumRate,
            priceFeed: priceOracle,
            owner: msg.sender
        });

        emit AssetDeposited(depositId, msg.sender, memeToken, 1, tokenAmount);
    }

    /**
     * @notice Депозит ERC20 RWA (альтернатива ERC721)
     */
    function depositRWA20(
        address assetAddress,
        uint256 assetAmount,
        uint256 tokenAmount,
        uint256 lockDuration,
        address poolCurrency,
        uint256 premiumRate,
        string memory tokenName,
        string memory tokenSymbol
    ) external noReentrancy returns (uint256 depositId) {
        require(assetAmount > 0, "MWAVault: zero amount");
        require(tokenAmount > 0, "MWAVault: zero supply");
        require(premiumRate == 3 || premiumRate == 5 || premiumRate == 10, "MWAVault: invalid premium");

        IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), assetAmount);

        address memeToken = IMWATokenFactory(mwaTokenFactory).createToken(
            tokenName,
            tokenSymbol,
            address(this)
        );

        depositId = ++depositCounter;

        deposits[depositId] = Deposit({
            assetAddress: assetAddress,
            assetId: 0,
            assetAmount: assetAmount,
            memeToken: memeToken,
            memeTokenAmount: tokenAmount,
            redemptionDeadline: block.timestamp + lockDuration,
            isRedeemed: false,
            isClaimed: false,
            poolCurrency: poolCurrency,
            premiumRate: premiumRate,
            priceFeed: priceOracle,
            owner: msg.sender
        });

        emit AssetDeposited(depositId, msg.sender, memeToken, assetAmount, tokenAmount);
    }

    /**
     * @notice Минтинг MEME-токенов покупателю (вызывается Redemption при покупке)
     */
    function mintMemeToken(
        uint256 depositId,
        address to,
        uint256 amount
    ) external onlyRedemption {
        Deposit storage d = deposits[depositId];
        require(d.memeToken != address(0), "MWAVault: no token");
        require(!d.isRedeemed, "MWAVault: redeemed");
        require(amount > 0, "MWAVault: zero amount");

        MWATokenInterface(d.memeToken).mint(to, amount);
    }

    /**
     * @notice Возврат RWA автору после выкупа
     */
    function releaseRWA(uint256 depositId) external onlyRedemption {
        Deposit storage d = deposits[depositId];
        require(!d.isRedeemed, "MWAVault: already redeemed");
        d.isRedeemed = true;

        if (d.assetId != 0 || d.assetAmount == 1) {
            // ERC721
            IERC721(d.assetAddress).transferFrom(address(this), d.owner, d.assetId);
        } else {
            // ERC20
            IERC20(d.assetAddress).safeTransfer(d.owner, d.assetAmount);
        }

        emit AssetRedeemed(depositId, d.owner);
    }

    /// @notice Обновление адреса фабрики токенов
    function setFactory(address _factory) external onlyOwner {
        mwaTokenFactory = _factory;
        emit FactoryUpdated(_factory);
    }

    /// @notice Обновление оракула цен
    function setOracle(address _oracle) external onlyOwner {
        priceOracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    /// @notice Обновление адреса USDC
    function setUsdc(address _usdc) external onlyOwner {
        usdcToken = _usdc;
        emit UsdcUpdated(_usdc);
    }

    /// @notice Обновление адреса Redemption
    function setRedemption(address _redemption) external onlyOwner {
        redemption = _redemption;
        emit RedemptionUpdated(_redemption);
    }

    /// @notice Получить депозит
    function getDeposit(uint256 depositId) external view returns (Deposit memory) {
        return deposits[depositId];
    }

    /// @notice Получить владельца депозита
    function getDepositOwner(uint256 depositId) external view returns (address) {
        return deposits[depositId].owner;
    }
}

interface MWATokenInterface {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}
