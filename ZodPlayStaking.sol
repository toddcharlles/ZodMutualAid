// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OZ ERC20 (não-upgradeable) + OZ Upgradeable (proxy/modificadores)
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./IPaymentsVault.sol";

// ==== Integrações externas mínimas ====
interface ITaxVault { function setStakingAddress(address staking) external; }
interface ILotteryCoreLite { function setStakingAddress(address staking) external; }

// Oráculo externo de preço (AMM/DEX ou contrato dedicado)
interface IQuoteOracle {
    function quoteZPMInBASE(uint256 zpmAmount) external view returns (uint256 baseAmount);
    function quoteBASEInZPM(uint256 baseAmount) external view returns (uint256 zpmAmount);
}

// Interface mínima pro ZpmOnchainPool (opcional, pra notifyExternalDeposit)
interface IZpmPool { function notifyExternalDeposit(uint256 amount) external; }

// Hooks para AM (separados por tipo de yield)
interface IStakingYieldHookBase { function onStakeYieldGenerated(address depositor, uint256 commissionAmountBASE) external; }
interface IStakingYieldHookZpm  { function onStakeZpmYieldGenerated(address depositor, uint256 commissionAmountZPM) external; }

/// @title ZodPlayStakingUpgradeable (UUPS)
/// @notice Staking + comissões de afiliados (BASE/ZPM) via PaymentsVaults upgradeáveis.
contract ZodPlayStakingUpgradeable is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========= TIPOS =========
    struct Level { uint256 min; uint256 max; }

    struct Deposit {
        uint256 amountCore;
        uint256 amountSaved;
        uint256 stakeWeight;
        uint256 zpmCapBASE;
        uint256 zpmPaidBASE;
        uint256 rewardsBASE;
        uint256 rewardsZPMHold;
        uint256 rewardsMining;
        uint256 accumTotalBASE;
        bool    active;
        uint256 createdAt;
        uint256 initialSaved;
        uint256 initialWeight;
        uint256 feesDebt;
        uint256 burnDebt;
        uint256 miningDebt;
        uint8   level;
    }

    // ========= STORAGE =========
    IERC20 public baseToken;
    IERC20 public zpmToken;
    uint8  public baseTokenDecimals;
    uint8  public zpmTokenDecimals;

    address public taxVault;
    address public lotteryCore;
    address public treasury;
    address public liquidityReceiver;
    IQuoteOracle public priceOracle;

    // --- AFILIADOS ---
    IStakingYieldHookBase public affiliateHookBase; // hook BASE → AM
    IStakingYieldHookZpm  public affiliateHookZpm;  // hook ZPM  → AM
    IPaymentsVault public affiliateBaseVault;       // Vault de comissões em BASE
    IPaymentsVault public affiliateZpmVault;        // Vault de comissões em ZPM
    uint16 public yieldAffiliateCommissionBps;      // p.ex. 1000 = 10%
    uint256 public affiliateRoundId;                // round usado p/ comissões de staking

    // Pools internas BASE
    uint256 public savedBaseTotal;
    uint256 public feesPoolBase;
    uint256 public totalStakeWeight;

    // Índices por peso
    uint256 public accFeesPerWeight;   // BASE
    uint256 public accBurnPerWeight;   // ZPM
    uint256 public accMiningPerWeight; // ZPM

    // Parâmetros
    uint256 public constant CORE_BPS = 5000;             // 50% → liquidez
    uint256 public constant MAX_REWARD_MULTIPLIER = 300; // 300% do (core+saved)
    uint256 public constant COOLDOWN_BLOCKS = 10;
    uint16  public fastPassFeeBps; // 10% default

    // Depósitos por usuário
    mapping(address => mapping(uint256 => Deposit)) public userDeposits;
    mapping(address => uint256[]) public userDepositIds;
    uint256 public totalDeposits;
    uint256 public activeDepositsCount;
    mapping(address => bool) public hasActiveDeposit;
    mapping(address => uint8) public highestLevelCompleted;

    // Níveis
    Level[] public levels;

    // Salvaguardas
    bool public circuitBreakerActive;
    mapping(address => uint256) public lastDepositBlock;

    // MODIFICAÇÃO: Adição para promo (stake sem liquidez)
    bool public promoLocked;
    mapping(address => bool) public promoEligible;

    // ========= EVENTOS =========
    event DepositMade(address indexed user, uint256 depositId, uint256 amount, uint256 toLiquidity, uint256 toSaved, uint8 level);
    event ZPMPaid(address indexed user, uint256 depositId, uint256 zpmAmount, uint256 zpmPaidBASE);
    event FeesClaimed(address indexed user, uint256 depositId, uint256 netBaseAmount);
    event BurnBonusClaimed(address indexed user, uint256 depositId, uint256 netZpmAmount, uint256 baseAccounted);
    event MiningRewardClaimed(address indexed user, uint256 depositId, uint256 netZpmAmount, uint256 baseAccounted);
    event SavedWithdrawn(address indexed user, uint256 depositId, uint256 amount, uint256 newWeight);
    event BaseTokenUpdated(address indexed oldToken, address indexed newToken);
    event ZPMTokenUpdated(address indexed oldToken, address indexed newToken);
    event TaxVaultUpdated(address indexed oldVault, address indexed newVault);
    event LotteryCoreUpdated(address indexed oldCore, address indexed newCore);
    event TreasurySet(address indexed treasury);
    event LiquidityReceiverSet(address indexed oldReceiver, address indexed newReceiver);
    event PriceOracleSet(address indexed oldOracle, address indexed newOracle);
    event FeesAccrued(uint256 amount);
    event BurnBonusAccrued(uint256 amount);
    event MiningAccrued(uint256 amount);
    event CircuitBreakerToggled(bool active);
    event LevelsConfiguredHash(bytes32 hash, uint256 count);
    event LevelsCleared();
    event FastPassUsed(address indexed user, uint8 fromLevel, uint8 targetLevel, uint256 feeBASE);
    event FastPassFeeChanged(uint16 newBps);
    event RescueTokens(address indexed token, address indexed to, uint256 amount);
    event LevelAdvanced(address indexed user, uint8 level);
    event LevelCompleted(address indexed user, uint8 level);
    event CapBelowPaid(address indexed user, uint256 depositId, uint256 newZpmCapBASE, uint256 zpmPaidBASE);
    // Afiliados
    event AffiliateHookBaseUpdated(address indexed hook);
    event AffiliateHookZpmUpdated(address indexed hook);
    event AffiliateVaultsUpdated(address indexed baseVault, address indexed zpmVault);
    event YieldAffiliateCommissionBpsUpdated(uint16 bps);
    event AffiliateRoundIdSet(uint256 roundId);
    event YieldCommissionGeneratedBASE(address indexed depositor, uint256 yieldAmountBASE, uint256 commissionAmountBASE);
    event YieldCommissionGeneratedZPM(address indexed depositor, uint256 yieldAmountZPM, uint256 commissionAmountZPM);
    // MODIFICAÇÃO: Eventos para promo
    event PromoEligibleAdded(address indexed to);
    event PromoUsed(address indexed user, uint256 amount);
    event PromoLocked();

    // ===== UUPS constructor blocker =====
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ========= INITIALIZER =========
    function initialize(address baseToken_) external initializer {
        require(baseToken_ != address(0), "Base zero");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // decimais do baseToken
        (bool ok, bytes memory data) = baseToken_.staticcall(abi.encodeWithSignature("decimals()"));
        uint8 dec = ok && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
        require(dec == 18, "Base token must be 18 decimals (BSC USDT)");
        baseToken = IERC20(baseToken_);
        baseTokenDecimals = dec;

        yieldAffiliateCommissionBps = 1000; // 10%
        fastPassFeeBps = 1000;             // 10%

        emit BaseTokenUpdated(address(0), baseToken_);
    }

    // ===== UUPS authorize =====
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ========= SETUP PÓS-DEPLOY =========
    function setBaseToken(address token) external onlyOwner {
        require(token != address(0), "Base zero");
        require(token != address(zpmToken), "Base/ZPM must differ");
        require(activeDepositsCount == 0, "Active deposits");
        require(savedBaseTotal == 0 && feesPoolBase == 0, "Outstanding BASE");
        require(totalStakeWeight == 0, "Non-zero weight");
        require(levels.length == 0, "Clear levels first");
        if (address(baseToken) != address(0)) {
            require(IERC20(address(baseToken)).balanceOf(address(this)) == 0, "Old BASE balance");
        }
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        uint8 dec = ok && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
        require(dec == 18, "Base token must be 18 decimals (BSC USDT)");
        address oldToken = address(baseToken);
        baseToken = IERC20(token);
        baseTokenDecimals = dec;
        accFeesPerWeight = 0;
        emit BaseTokenUpdated(oldToken, token);
    }

    function setZPMToken(address token) external onlyOwner {
        require(token != address(0), "ZPM zero");
        require(token != address(baseToken), "Base/ZPM must differ");
        require(activeDepositsCount == 0 && totalStakeWeight == 0, "Active deposits");
        if (address(zpmToken) != address(0)) {
            require(IERC20(address(zpmToken)).balanceOf(address(this)) == 0, "Old ZPM balance");
        }
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        uint8 dec = ok && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
        require(dec == 18, "ZPM must be 18d");
        address oldToken = address(zpmToken);
        zpmToken = IERC20(token);
        zpmTokenDecimals = dec;
        accBurnPerWeight = 0;
        accMiningPerWeight = 0;
        emit ZPMTokenUpdated(oldToken, token);
    }

    function setTaxVault(address vault_) external onlyOwner {
        require(vault_ != address(0), "Vault zero");
        address old = taxVault;
        taxVault = vault_;
        try ITaxVault(vault_).setStakingAddress(address(this)) {} catch {}
        emit TaxVaultUpdated(old, vault_);
    }

    function setLotteryCore(address core_) external onlyOwner {
        require(core_ != address(0), "Core zero");
        address old = lotteryCore;
        lotteryCore = core_;
        try ILotteryCoreLite(core_).setStakingAddress(address(this)) {} catch {}
        emit LotteryCoreUpdated(old, core_);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Treasury zero");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setLiquidityReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "Receiver zero");
        address old = liquidityReceiver;
        liquidityReceiver = receiver;
        emit LiquidityReceiverSet(old, receiver);
    }

    function setPriceOracle(address oracle) external onlyOwner {
        require(oracle != address(0), "Oracle zero");
        address old = address(priceOracle);
        priceOracle = IQuoteOracle(oracle);
        emit PriceOracleSet(old, oracle);
    }

    // --- AFILIADOS: Setters ---
    function setAffiliateHooks(address hookBase, address hookZpm) external onlyOwner {
        affiliateHookBase = IStakingYieldHookBase(hookBase);
        affiliateHookZpm  = IStakingYieldHookZpm(hookZpm);
        emit AffiliateHookBaseUpdated(hookBase);
        emit AffiliateHookZpmUpdated(hookZpm);
    }

    function setAffiliateVaults(address baseVault, address zpmVault) external onlyOwner {
        require(baseVault != address(0) && zpmVault != address(0), "Vault zero");
        affiliateBaseVault = IPaymentsVault(baseVault);
        affiliateZpmVault  = IPaymentsVault(zpmVault);
        emit AffiliateVaultsUpdated(baseVault, zpmVault);
    }

    function setYieldAffiliateCommissionBps(uint16 bps) external onlyOwner {
        require(bps <= 2000, "Max 20%");
        yieldAffiliateCommissionBps = bps;
        emit YieldAffiliateCommissionBpsUpdated(bps);
    }

    function setAffiliateRoundId(uint256 roundId) external onlyOwner {
        affiliateRoundId = roundId;
        emit AffiliateRoundIdSet(roundId);
    }

    function setLevels(Level[] calldata newLevels) external onlyOwner {
        require(activeDepositsCount == 0, "Active deposits exist");
        require(newLevels.length > 0, "Invalid levels");
        for (uint256 i = 0; i < newLevels.length; i++) {
            require(newLevels[i].min <= newLevels[i].max, "Invalid range");
            if (i > 0) require(newLevels[i].min >= newLevels[i - 1].max, "Overlapping");
        }
        delete levels;
        for (uint256 i = 0; i < newLevels.length; i++) levels.push(newLevels[i]);
        emit LevelsConfiguredHash(keccak256(abi.encode(newLevels)), newLevels.length);
    }

    function clearLevels() external onlyOwner {
        require(activeDepositsCount == 0, "Active deposits exist");
        delete levels; emit LevelsCleared();
    }

    function setFastPassFeeBps(uint16 bps) external onlyOwner {
        require(bps <= 2000, "Max 20%");
        fastPassFeeBps = bps; emit FastPassFeeChanged(bps);
    }

    function toggleCircuitBreaker(bool active) external onlyOwner {
        circuitBreakerActive = active; emit CircuitBreakerToggled(active);
    }

    function rescueTokens(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        require(token != address(baseToken) && token != address(zpmToken), "Protected");
        require(to != address(0), "Dest zero"); require(amount > 0, "Invalid amount");
        IERC20(token).safeTransfer(to, amount); emit RescueTokens(token, to, amount);
    }

    // MODIFICAÇÃO: Funções para gerenciar promo
    function setPromoEligible(address[] calldata addrs) external onlyOwner {
        require(!promoLocked, "PromoLocked");
        for (uint256 i = 0; i < addrs.length; i++) {
            require(addrs[i] != address(0), "InvalidAddress");
            promoEligible[addrs[i]] = true;
            emit PromoEligibleAdded(addrs[i]);
        }
    }

    function lockPromo() external onlyOwner {
        promoLocked = true;
        emit PromoLocked();
    }

    // ========= HELPERS =========
    function _calcYieldCommissionBASE(uint256 yieldAmountBASE, uint256 yieldAmountZPM)
        internal view returns (uint256 commissionBASE, uint256 totalYieldBASE)
    {
        totalYieldBASE = yieldAmountBASE;
        if (yieldAmountZPM > 0 && address(priceOracle) != address(0)) {
            totalYieldBASE += priceOracle.quoteZPMInBASE(yieldAmountZPM);
        }
        commissionBASE = (totalYieldBASE * yieldAffiliateCommissionBps) / 10_000;
    }
    function _calcYieldCommissionZPM(uint256 yieldAmountZPM) internal view returns (uint256 commissionZPM) {
        commissionZPM = (yieldAmountZPM * yieldAffiliateCommissionBps) / 10_000;
    }

    // ========= STAKING =========
    function deposit(uint256 amount) external nonReentrant {
        require(!circuitBreakerActive, "Breaker ON");
        require(block.number > lastDepositBlock[msg.sender] + COOLDOWN_BLOCKS, "Cooldown");
        require(amount > 0, "Amount=0");
        require(address(zpmToken) != address(0), "ZPM not set");
        require(!hasActiveDeposit[msg.sender], "Active deposit exists");
        require(levels.length > 0, "Levels not set");
        require(liquidityReceiver != address(0), "Liquidity receiver not set");

        uint8 nextLevel = highestLevelCompleted[msg.sender] + 1;
        require(nextLevel <= levels.length, "Max level reached");
        Level memory L = levels[nextLevel - 1];
        require(amount >= L.min && amount <= L.max, "Amount out of range");

        bool isPromo = promoEligible[msg.sender];
        if (isPromo) {
            promoEligible[msg.sender] = false;
            emit PromoUsed(msg.sender, amount);
        }

        if (!isPromo) {
            baseToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 toLiquidity = isPromo ? 0 : (amount * CORE_BPS) / 10000;
        uint256 toSaved = amount - toLiquidity;
        uint256 stakeW = isPromo ? (amount * 10000 / (10000 - CORE_BPS)) : amount;

        baseToken.safeTransfer(liquidityReceiver, toLiquidity);
        if (toLiquidity > 0) {
            try IZpmPool(liquidityReceiver).notifyExternalDeposit(toLiquidity) {} catch {}
        }

        savedBaseTotal += toSaved;
        totalStakeWeight += stakeW;

        uint256 depositId = ++totalDeposits;
        userDeposits[msg.sender][depositId] = Deposit({
            amountCore: toLiquidity,
            amountSaved: toSaved,
            stakeWeight: stakeW,
            zpmCapBASE: toSaved,
            zpmPaidBASE: 0,
            rewardsBASE: 0,
            rewardsZPMHold: 0,
            rewardsMining: 0,
            accumTotalBASE: 0,
            active: true,
            createdAt: block.timestamp,
            initialSaved: toSaved,
            initialWeight: stakeW,
            feesDebt: (stakeW * accFeesPerWeight) / 1e18,
            burnDebt: (stakeW * accBurnPerWeight) / 1e18,
            miningDebt: (stakeW * accMiningPerWeight) / 1e18,
            level: nextLevel
        });

        userDepositIds[msg.sender].push(depositId);
        lastDepositBlock[msg.sender] = block.number;
        hasActiveDeposit[msg.sender] = true;
        activeDepositsCount++;

        emit DepositMade(msg.sender, depositId, amount, toLiquidity, toSaved, nextLevel);
        emit LevelAdvanced(msg.sender, nextLevel);
    }

    function depositFastPass(uint256 amount, uint8 targetLevel) external nonReentrant {
        require(!circuitBreakerActive, "Breaker ON");
        require(block.number > lastDepositBlock[msg.sender] + COOLDOWN_BLOCKS, "Cooldown");
        require(amount > 0, "Amount=0");
        require(address(zpmToken) != address(0), "ZPM not set");
        require(!hasActiveDeposit[msg.sender], "Active deposit exists");
        require(levels.length > 0, "Levels not set");
        require(liquidityReceiver != address(0), "Liquidity receiver not set");
        require(targetLevel >= 1 && targetLevel <= levels.length, "Invalid level");

        uint8 nextLevel = highestLevelCompleted[msg.sender] + 1;
        require(targetLevel >= nextLevel, "Target below eligible");
        Level memory L = levels[targetLevel - 1];
        require(amount >= L.min && amount <= L.max, "Amount out of range");

        bool isPromo = promoEligible[msg.sender];
        if (isPromo) {
            promoEligible[msg.sender] = false;
            emit PromoUsed(msg.sender, amount);
        }

        uint256 fee = (isPromo || targetLevel == nextLevel) ? 0 : (amount * fastPassFeeBps) / 10000;

        if (!isPromo) {
            baseToken.safeTransferFrom(msg.sender, address(this), amount + fee);
        }

        if (fee > 0) {
            baseToken.safeTransfer(liquidityReceiver, fee);
            try IZpmPool(liquidityReceiver).notifyExternalDeposit(fee) {} catch {}
            emit FastPassUsed(msg.sender, nextLevel, targetLevel, fee);
        }

        uint256 toLiquidity = isPromo ? 0 : (amount * CORE_BPS) / 10000;
        uint256 toSaved = amount - toLiquidity;
        uint256 stakeW = isPromo ? (amount * 10000 / (10000 - CORE_BPS)) : amount;

        baseToken.safeTransfer(liquidityReceiver, toLiquidity);
        if (toLiquidity > 0) {
            try IZpmPool(liquidityReceiver).notifyExternalDeposit(toLiquidity) {} catch {}
        }

        savedBaseTotal += toSaved;
        totalStakeWeight += stakeW;

        uint256 depositId = ++totalDeposits;
        userDeposits[msg.sender][depositId] = Deposit({
            amountCore: toLiquidity,
            amountSaved: toSaved,
            stakeWeight: stakeW,
            zpmCapBASE: toSaved,
            zpmPaidBASE: 0,
            rewardsBASE: 0,
            rewardsZPMHold: 0,
            rewardsMining: 0,
            accumTotalBASE: 0,
            active: true,
            createdAt: block.timestamp,
            initialSaved: toSaved,
            initialWeight: stakeW,
            feesDebt: (stakeW * accFeesPerWeight) / 1e18,
            burnDebt: (stakeW * accBurnPerWeight) / 1e18,
            miningDebt: (stakeW * accMiningPerWeight) / 1e18,
            level: targetLevel
        });

        userDepositIds[msg.sender].push(depositId);
        lastDepositBlock[msg.sender] = block.number;
        hasActiveDeposit[msg.sender] = true;
        activeDepositsCount++;

        emit DepositMade(msg.sender, depositId, amount, toLiquidity, toSaved, targetLevel);
        emit LevelAdvanced(msg.sender, targetLevel);
    }

    function claimZPM(uint256 depositId) external nonReentrant {
        require(address(zpmToken) != address(0), "ZPM not set");
        require(address(priceOracle) != address(0), "Oracle not set");

        Deposit storage d = userDeposits[msg.sender][depositId];
        require(d.active, "Inactive deposit");
        require(d.zpmPaidBASE < d.zpmCapBASE, "ZPM cap reached");

        uint256 remainingBASE = d.zpmCapBASE - d.zpmPaidBASE;
        uint256 maxZpm = priceOracle.quoteBASEInZPM(remainingBASE);
        require(maxZpm > 0, "Nothing to claim");
        require(zpmToken.balanceOf(address(this)) >= maxZpm, "Insufficient ZPM");

        uint256 paidBASE = remainingBASE;
        d.zpmPaidBASE = Math.min(d.zpmPaidBASE + paidBASE, d.zpmCapBASE);
        d.accumTotalBASE += paidBASE;
        _checkAndUpdateActiveStatus(msg.sender, d);

        zpmToken.safeTransfer(msg.sender, maxZpm);
        emit ZPMPaid(msg.sender, depositId, maxZpm, d.zpmPaidBASE);
        // Conversão de saldo salvo — sem comissão.
    }

    function claimFees(uint256 depositId) external nonReentrant {
        Deposit storage d = userDeposits[msg.sender][depositId];
        require(d.active, "Inactive deposit");
        uint256 gross = (d.stakeWeight * accFeesPerWeight) / 1e18;
        uint256 pending = gross > d.feesDebt ? gross - d.feesDebt : 0;
        require(pending > 0, "No fees");
        require(feesPoolBase >= pending, "Pool short");
        require(baseToken.balanceOf(address(this)) >= pending, "Insufficient BASE");

        (uint256 commission, uint256 totalYieldBASE) = _calcYieldCommissionBASE(pending, 0);
        uint256 net = pending - commission;

        d.feesDebt = (d.stakeWeight * accFeesPerWeight) / 1e18;
        d.rewardsBASE += net;
        d.accumTotalBASE += net;
        feesPoolBase -= pending;

        if (commission > 0) {
            require(address(affiliateBaseVault) != address(0), "AffBaseVault not set");
            baseToken.safeTransfer(address(affiliateBaseVault), commission);
            IPaymentsVault.Pools memory p = IPaymentsVault.Pools({prize:0, treasury:0, commission:commission, liquidity:0});
            affiliateBaseVault.creditPools(affiliateRoundId, p);
            emit YieldCommissionGeneratedBASE(msg.sender, totalYieldBASE, commission);
            if (address(affiliateHookBase) != address(0)) {
                try affiliateHookBase.onStakeYieldGenerated(msg.sender, commission) {} catch {}
            }
        }

        _checkAndUpdateActiveStatus(msg.sender, d);
        baseToken.safeTransfer(msg.sender, net);
        emit FeesClaimed(msg.sender, depositId, net);
    }

    function claimBurnBonus(uint256 depositId) external nonReentrant {
        require(address(zpmToken) != address(0), "ZPM not set");
        require(address(priceOracle) != address(0), "Oracle not set");

        Deposit storage d = userDeposits[msg.sender][depositId];
        require(d.active, "Inactive deposit");

        uint256 gross = (d.stakeWeight * accBurnPerWeight) / 1e18; // ZPM
        uint256 pending = gross > d.burnDebt ? gross - d.burnDebt : 0;
        require(pending > 0, "No burn bonus");
        require(zpmToken.balanceOf(address(this)) >= pending, "Insufficient ZPM");

        d.burnDebt = (d.stakeWeight * accBurnPerWeight) / 1e18;

        uint256 commissionZPM = _calcYieldCommissionZPM(pending);
        uint256 netZpm = pending - commissionZPM;

        d.rewardsZPMHold += netZpm;

        uint256 baseValNet = priceOracle.quoteZPMInBASE(netZpm);
        d.accumTotalBASE += baseValNet;

        _checkAndUpdateActiveStatus(msg.sender, d);

        if (commissionZPM > 0) {
            require(address(affiliateZpmVault) != address(0), "AffZpmVault not set");
            zpmToken.safeTransfer(address(affiliateZpmVault), commissionZPM);
            IPaymentsVault.Pools memory p = IPaymentsVault.Pools({prize:0, treasury:0, commission:commissionZPM, liquidity:0});
            affiliateZpmVault.creditPools(affiliateRoundId, p);
            emit YieldCommissionGeneratedZPM(msg.sender, pending, commissionZPM);
            if (address(affiliateHookZpm) != address(0)) {
                try affiliateHookZpm.onStakeZpmYieldGenerated(msg.sender, commissionZPM) {} catch {}
            }
        }

        zpmToken.safeTransfer(msg.sender, netZpm);
        emit BurnBonusClaimed(msg.sender, depositId, netZpm, baseValNet);
    }

    function claimMiningReward(uint256 depositId) external nonReentrant {
        require(address(zpmToken) != address(0), "ZPM not set");
        require(address(priceOracle) != address(0), "Oracle not set");

        Deposit storage d = userDeposits[msg.sender][depositId];
        require(d.active, "Inactive deposit");

        uint256 gross = (d.stakeWeight * accMiningPerWeight) / 1e18; // ZPM
        uint256 pending = gross > d.miningDebt ? gross - d.miningDebt : 0;
        require(pending > 0, "No mining reward");
        require(zpmToken.balanceOf(address(this)) >= pending, "Insufficient ZPM");

        d.miningDebt = (d.stakeWeight * accMiningPerWeight) / 1e18;

        uint256 commissionZPM = _calcYieldCommissionZPM(pending);
        uint256 netZpm = pending - commissionZPM;

        d.rewardsMining += netZpm;

        uint256 baseValNet = priceOracle.quoteZPMInBASE(netZpm);
        d.accumTotalBASE += baseValNet;

        _checkAndUpdateActiveStatus(msg.sender, d);

        if (commissionZPM > 0) {
            require(address(affiliateZpmVault) != address(0), "AffZpmVault not set");
            zpmToken.safeTransfer(address(affiliateZpmVault), commissionZPM);
            IPaymentsVault.Pools memory p = IPaymentsVault.Pools({prize:0, treasury:0, commission:commissionZPM, liquidity:0});
            affiliateZpmVault.creditPools(affiliateRoundId, p);
            emit YieldCommissionGeneratedZPM(msg.sender, pending, commissionZPM);
            if (address(affiliateHookZpm) != address(0)) {
                try affiliateHookZpm.onStakeZpmYieldGenerated(msg.sender, commissionZPM) {} catch {}
            }
        }

        zpmToken.safeTransfer(msg.sender, netZpm);
        emit MiningRewardClaimed(msg.sender, depositId, netZpm, baseValNet);
    }

    function withdrawSaved(uint256 depositId, uint256 amount) external nonReentrant {
        Deposit storage d = userDeposits[msg.sender][depositId];
        require(amount <= d.amountSaved, "Insufficient saved");
        require(d.initialSaved > 0, "Invalid initialSaved");
        require(savedBaseTotal >= amount, "Saved underflow");
        uint256 bal = baseToken.balanceOf(address(this));
        require(bal >= feesPoolBase + amount, "BASE reserved for fees");

        uint256 prevBase = d.amountCore + d.initialSaved;
        uint256 newBase  = d.amountCore + (d.amountSaved - amount);
        uint256 newWeight = (d.initialWeight * newBase) / prevBase;
        uint256 newZpmCapBASE = d.amountSaved - amount;

        savedBaseTotal -= amount;
        totalStakeWeight = totalStakeWeight - d.stakeWeight + newWeight;

        d.amountSaved -= amount;
        d.stakeWeight = newWeight;

        if (newZpmCapBASE < d.zpmPaidBASE) {
            emit CapBelowPaid(msg.sender, depositId, newZpmCapBASE, d.zpmPaidBASE);
            d.zpmCapBASE = d.zpmPaidBASE;
        } else {
            d.zpmCapBASE = newZpmCapBASE;
        }

        d.feesDebt   = (d.stakeWeight * accFeesPerWeight)   / 1e18;
        d.burnDebt   = (d.stakeWeight * accBurnPerWeight)   / 1e18;
        d.miningDebt = (d.stakeWeight * accMiningPerWeight) / 1e18;

        _checkAndUpdateActiveStatus(msg.sender, d);
        if (!d.active && hasActiveDeposit[msg.sender]) {
            hasActiveDeposit[msg.sender] = false;
            activeDepositsCount--;
        }

        baseToken.safeTransfer(msg.sender, amount);
        emit SavedWithdrawn(msg.sender, depositId, amount, newWeight);
    }

    // ========= FUNÇÕES CHAMADAS POR OUTROS CONTRATOS =========
    function accrueFees(uint256 amount) external onlyTaxVaultOrLiquidityReceiver nonReentrant {
        require(totalStakeWeight > 0, "No active stake");
        feesPoolBase += amount;
        accFeesPerWeight += (amount * 1e18) / totalStakeWeight;
        emit FeesAccrued(amount);
    }

    function accrueBurnBonus(uint256 amount) external onlyTaxVaultOrLiquidityReceiver nonReentrant {
        require(totalStakeWeight > 0, "No active stake");
        accBurnPerWeight += (amount * 1e18) / totalStakeWeight;
        emit BurnBonusAccrued(amount);
    }

    function accrueMiningReward(uint256 amount) external onlyLotteryCore nonReentrant {
        require(totalStakeWeight > 0, "No active stake");
        accMiningPerWeight += (amount * 1e18) / totalStakeWeight;
        emit MiningAccrued(amount);
    }

    // ========= VIEWS =========
    function isInitialized() external view returns (bool) {
        return address(zpmToken) != address(0) &&
               taxVault != address(0) &&
               lotteryCore != address(0) &&
               liquidityReceiver != address(0) &&
               address(priceOracle) != address(0) &&
               levels.length > 0;
    }

    function levelsCount() external view returns (uint256) { return levels.length; }

    function levelInfo(uint8 i) external view returns (uint256 min, uint256 max) {
        require(i >= 1 && i <= levels.length, "Invalid level");
        Level memory L = levels[i - 1]; return (L.min, L.max);
    }

    function getTotalStakeWeight() public view returns (uint256) { return totalStakeWeight; }

    function nextLevelOf(address user) external view returns (uint8 level, uint256 min, uint256 max, bool canDeposit) {
        uint8 nextLevel = highestLevelCompleted[user] + 1;
        if (nextLevel > levels.length) return (0,0,0,false);
        Level memory L = levels[nextLevel - 1];
        return (nextLevel, L.min, L.max, !hasActiveDeposit[user] && block.number > lastDepositBlock[user] + COOLDOWN_BLOCKS);
    }

    function progress(address user, uint256 depositId) external view returns (uint256 percentage, bool active) {
        Deposit memory d = userDeposits[user][depositId];
        uint256 target = (d.amountCore + d.initialSaved) * MAX_REWARD_MULTIPLIER / 100;
        if (target == 0) return (0, d.active);
        return (d.accumTotalBASE * 100 / target, d.active);
    }

    function getUserDepositIds(address user) external view returns (uint256[] memory) { return userDepositIds[user]; }

    function getUserDepositInfo(address user, uint256 depositId) external view returns (
        uint256 amountCore,
        uint256 amountSaved,
        uint256 stakeWeight,
        uint256 zpmCapBASE,
        uint256 zpmPaidBASE,
        uint256 rewardsBASE,
        uint256 rewardsZPMHold,
        uint256 rewardsMining,
        uint256 accumTotalBASE,
        bool active,
        uint256 createdAt,
        uint256 pendingFees,
        uint256 pendingBurnBonusZPM,
        uint256 pendingMiningRewardZPM,
        uint8 level
    ) {
        Deposit memory d = userDeposits[user][depositId];
        uint256 grossFees   = (d.stakeWeight * accFeesPerWeight) / 1e18;
        uint256 grossBurn   = (d.stakeWeight * accBurnPerWeight) / 1e18;
        uint256 grossMining = (d.stakeWeight * accMiningPerWeight) / 1e18;

        pendingFees            = grossFees   > d.feesDebt   ? grossFees   - d.feesDebt   : 0;
        pendingBurnBonusZPM    = grossBurn   > d.burnDebt   ? grossBurn   - d.burnDebt   : 0;
        pendingMiningRewardZPM = grossMining > d.miningDebt ? grossMining - d.miningDebt : 0;

        return (
            d.amountCore, d.amountSaved, d.stakeWeight, d.zpmCapBASE, d.zpmPaidBASE,
            d.rewardsBASE, d.rewardsZPMHold, d.rewardsMining, d.accumTotalBASE,
            d.active, d.createdAt, pendingFees, pendingBurnBonusZPM, pendingMiningRewardZPM, d.level
        );
    }

    // ========= INTERNAL =========
    function _checkAndUpdateActiveStatus(address user, Deposit storage d) internal {
        uint256 target = (d.amountCore + d.initialSaved) * MAX_REWARD_MULTIPLIER / 100;
        if (d.accumTotalBASE >= target) {
            totalStakeWeight -= d.stakeWeight;
            d.stakeWeight = 0;
            d.active = false;
            hasActiveDeposit[user] = false;
            activeDepositsCount--;
            if (d.level > highestLevelCompleted[user]) highestLevelCompleted[user] = d.level;
            emit LevelCompleted(user, d.level);
        }
    }

    // ========= MODIFIERS =========
    modifier onlyTaxVaultOrLiquidityReceiver() {
        require(msg.sender == taxVault || msg.sender == liquidityReceiver, "Only TaxVault or LiquidityReceiver"); _;
    }
    modifier onlyLotteryCore() { require(msg.sender == lotteryCore, "Only LotteryCore"); _; }

    // ===== storage gap p/ upgrades futuros =====
    uint256[44] private __gap;
}