// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IPaymentsVault.sol";

// ---------------------- Erros Personalizados ----------------------
error NotOwner();
error InvalidAddress();
error RoundNotExist();
error RoundClosed();
error InvalidQuantity();
error InvalidStar();
error InvalidMask();
error InvalidBps();
error InvalidBatch();
error RoundNotDrawn();
error WinnersAlreadyValidated();
error ClaimDeadlinePassed();
error NoWinningTickets();
error NoPrizeAvailable();
error MiningNotFinalized();
error NotEnoughTickets();
error NoEligibleTickets();
error NoRewardAvailable();
error MiningTokenNotSet();
error StakingNotSet();
error InvalidDuration();
error InvalidPrice();
error InvalidSymbols();
error InvalidStarReq();
error PercentSumInvalid();
error InvalidRound();
error CommitAlreadySet();
error InvalidReveal();
error RoundNotReady();
error AlreadyClaimed();
error LiquidityPoolNotSet();
error TreasuryNotSet();
error ClaimPeriodActive();
error AlreadySettled();
error PrizeUnderflow();
error DecimalsTooHigh();
error BadRange();
error InvalidTier();
error MaxTicketsPerRoundExceeded();
error CommitNotSet();
error VouchersLocked(); // MODIFICAÇÃO: Erro mantido com parênteses

// ---------------------- External modules ----------------------
interface IZodPlayStaking {
    function accrueMiningReward(uint256 amount) external;
    function totalStakeWeight() external view returns (uint256);
}

// Optional hook interface (AffiliateManager)
interface IAffiliateHook {
    function onTicketBought(address buyer, uint256 roundId, uint256 qty, uint256 cost, uint256 commissionAmount) external;
}

interface IMiningToken {
    function mint(address to, uint256 amount) external;
}

// ---------------------- Core ----------------------
contract LotteryCore is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== External modules
    IPaymentsVault public vault;
    address public stakingAddress;
    address public affiliateHook; // opcional

    // ===== Token & economic params
    IERC20 public paymentToken;
    address public treasury;
    address public liquidityPool;
    // MODIFICAÇÃO: Substituímos tokenDecimals por paymentTokenDecimals e tornamos imutável
    uint8 private immutable paymentTokenDecimals;

    // ===== Distribuição (SEM Network; commission é apenas um pool)
    struct TicketSaleDistribution { uint256 prizePool; uint256 treasury; uint256 commission; uint256 liquidity; }
    TicketSaleDistribution public dist = TicketSaleDistribution(34, 15, 18, 33);

    // ===== Preços
    // MODIFICAÇÃO: ticketPrice é armazenado em 18 decimais (formato "humano")
    uint256 public ticketPrice = 1e18; // 1 USDT em 18 decimais internamente
    uint256 public maxTicketsPerTx = 150;
    uint256 public maxTicketsPerRoundPerAddress = 140;

    // ===== Rounds
    struct Round {
        uint256 prizePoolMirror;
        uint256 liquidityPoolMirror;
        uint256 soldTickets;
        uint64 endTime;
        bool drawn;
        bool exists;
        uint16 winningMask;
        uint8 winningStar;
        uint256[3] totalWinningQtyPerTier;
        uint256[3] allocatedPrizePerTier;
        bool winnersValidated;
        bool liquidityWithdrawn;
        uint256 carryOverToNextPrize;
        bool noWinnersSettled;
        bytes32 commit;
        bool commitSet;
        bytes32 entropy;
        uint64 commitBlock;
    }
    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;

    struct Ticket { uint16 mask; uint8 star; uint96 qty; }
    mapping(uint256 => mapping(address => Ticket[])) public userTickets;
    mapping(uint256 => mapping(address => uint256)) public userTicketQtyPerRound;

    // Lista de participantes por rodada
    mapping(uint256 => address[]) public roundParticipants;
    mapping(uint256 => mapping(address => bool)) public isParticipant;

    // Cursor para validação automática paginada
    mapping(uint256 => uint256) public winnersValidationCursor;

    // Tamanho padrão do batch que roda automaticamente após o sorteio
    uint256 public autoValidateBatch = 50; // ajuste fino conforme budget de gas

    // ===== Prize tiers
    struct PrizeTier { uint8 symbolsRequired; uint8 starRequired; uint256 percent; }
    PrizeTier[3] public prizeTiers;

    // ===== Times
    uint64 public roundDuration = 30 days;
    uint64 public claimDeadline = 30 days;
    uint64 public minRoundDuration = 1 hours;
    uint64 public maxRoundDuration = 30 days;

    // ===== Mineração
    IMiningToken public miningToken;
    uint256 public maxMiningSupply = 21_000_000 * 1e18;
    uint256 public mintedSoFar;
    mapping(address => mapping(uint256 => bool)) public miningClaimed;
    mapping(uint256 => uint256) public miningRewardPerRound;

    uint256 public miningPerBlock = 202 * 1e18;
    uint256 public ticketsPerMiningBlock = 200;
    uint16 public miningStakingBps = 3000; // 30%
    mapping(uint256 => uint256) public stakingSharePerRound;
    uint256 public stakingEscrowTotal;

    struct MiningRoundInfo {
        uint256 numBlocks;
        uint256 total;
        uint256 perTicket;
        uint256 remainder;
        bool finalized;
    }
    mapping(uint256 => MiningRoundInfo) public miningRoundInfo;

    // Regras de elegibilidade e peso da mineração
    uint256 public minTicketsForMining = 1;
    uint256 public ticketsPerWeight = 1;

    // % “sem ganhadores” (base 1e4)
    uint256 public constant DENOM = 10_000;
    uint256 public t0CarryPct = 4_000;
    uint256 public t0ToT1Pct = 3_000;
    uint256 public t0ToT2Pct = 3_000;
    uint256 public t1CarryPct = 4_000;
    uint256 public t1ToT2Pct = 6_000;
    uint256 public t2CarryPct = 7_000;
    uint256 public t2ToLiquidityPct = 3_000;

    // por rodada: valor fixo por bilhete vencedor em cada tier
    mapping(uint256 => uint256[3]) public perWinningTicket;

    // Rastreamento de bilhetes já reivindicados por usuário, por rodada e por tier
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) public userClaimedTickets;

    // ============================================================
    // Winners storage
    // ============================================================
    event WinnerRecorded(uint256 indexed roundId, address indexed user, uint8 tierIndex, uint256 qty);

    struct Winners {
        address[] t0;
        address[] t1;
        address[] t2;
    }

    mapping(uint256 => Winners) private winnersByRound;
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) private winnerMarked;

    // ===== Events
    event RoundStarted(uint256 indexed roundId, uint64 endTime);
    event Bought(address indexed user, uint256 indexed roundId, uint16 mask, uint8 star, uint256 qty, uint256 paid);
    event CommitSet(uint256 indexed roundId, bytes32 commit);
    event RoundDrawn(uint256 indexed roundId, uint16 mask, uint8 star, bytes32 seed);
    event WinnersValidated(uint256 indexed roundId, uint256[3] totalWinningQtyPerTier);
    event PrizeClaimed(address indexed user, uint256 indexed roundId, uint256 amount, uint8 tierIndex);
    event LiquidityWithdrawn(uint256 indexed roundId, uint256 amount, address to);
    event UnclaimedWithdrawn(uint256 indexed roundId, uint256 amount, address to);
    event PricesAdjusted(uint256 ticketPrice, uint8 decimals);
    event RoundEndedNow(uint256 indexed roundId, uint64 newEndTime);
    event NoWinnersSettled(
        uint256 indexed roundId,
        bool t0NoWinners,
        bool t1NoWinners,
        bool t2NoWinners,
        uint256 carryOver,
        uint256 toT1,
        uint256 toT2,
        uint256 toLiquidity
    );
    event MiningClaimed(address indexed user, uint256 indexed roundId, uint256 amount);
    event MiningRewardAccruedToStaking(uint256 indexed roundId, uint256 amount);
    event StakingAddressUpdated(address indexed oldStaking, address indexed newStaking);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event MiningSplitSet(uint16 stakingBps);
    event TicketsPerMiningBlockSet(uint256 value);
    event StakingEscrowed(uint256 indexed roundId, uint256 amount);
    event StakingEscrowFlushed(uint256 indexed roundId, uint256 amount);
    event AutoFlushToStakingSkipped(uint256 indexed roundId, uint256 amount, string reason);
    event Congratulations(address indexed user, uint256 indexed roundId, uint8 tierIndex, uint256 winningQty);
    event WinnersValidationProgress(uint256 indexed roundId, uint256 processed, uint256 total);
    event MaxTicketsPerRoundPerAddressSet(uint256 value);
    event AffiliateHookUpdated(address indexed hook);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event LiquidityPoolUpdated(address indexed oldLiquidityPool, address indexed newLiquidityPool);
    event MiningFinalized(
        uint256 indexed roundId,
        uint256 soldTickets,
        uint256 numBlocks,
        uint256 totalReward,
        uint256 userShare,
        uint256 perTicket,
        uint256 remainder
    );
    event VouchersAdded(address indexed to, uint256 qty);
    event VouchersUsed(address indexed user, uint256 qty);
    event VouchersLockedEvent(); // MODIFICAÇÃO: Evento renomeado de VouchersLocked para VouchersLockedEvent

    // MODIFICAÇÃO: Adição para vouchers
    bool public vouchersLocked;
    mapping(address => uint256) public availableVouchers;

    constructor(
        address _token,
        address _treasury,
        address _vault
    ) Ownable(msg.sender) {
        if (_token == address(0) || _treasury == address(0) || _vault == address(0)) revert InvalidAddress();
        paymentToken = IERC20(_token);
        treasury = _treasury;
        vault = IPaymentsVault(_vault);

        // MODIFICAÇÃO: Pegamos os decimais do token dinamicamente
        uint8 decs = _getTokenDecimals(_token);
        // Removido o require(decs == 18) para suportar qualquer número de decimais
        paymentTokenDecimals = decs; // Armazena os decimais do token (ex.: 6 para USDT, 18 para outros)

        prizeTiers[0] = PrizeTier(4, 1, 60);
        prizeTiers[1] = PrizeTier(3, 1, 25);
        prizeTiers[2] = PrizeTier(2, 1, 15);

        _startNewRound();
        emit PricesAdjusted(ticketPrice, decs);
    }

    // MODIFICAÇÃO: Funções auxiliares para conversão de valores
    // Converte valores do formato "humano" (18 decimais) para o formato do token
    function _toPayUnits(uint256 humanAmount) internal view returns (uint256) {
        // humanAmount está em 1e18 (formato interno do contrato)
        // Convertemos para o número de decimais do token (ex.: 1e6 para USDT)
        if (paymentTokenDecimals == 18) return humanAmount; // Sem conversão se for 18 decimais
        if (paymentTokenDecimals < 18) return humanAmount / (10 ** (18 - paymentTokenDecimals));
        return humanAmount * (10 ** (paymentTokenDecimals - 18));
    }

    // Converte valores do formato do token para o formato "humano" (18 decimais)
    function _fromPayUnits(uint256 payAmount) internal view returns (uint256) {
        // payAmount está no formato do token (ex.: 1e6 para USDT)
        // Convertemos para o formato interno (1e18)
        if (paymentTokenDecimals == 18) return payAmount; // Sem conversão se for 18 decimais
        if (paymentTokenDecimals < 18) return payAmount * (10 ** (18 - paymentTokenDecimals));
        return payAmount / (10 ** (paymentTokenDecimals - 18));
    }

    // MODIFICAÇÃO: Função para liberar recompensas de staking em escrow
    function flushStakingEscrow(uint256[] calldata roundIds) external onlyOwner nonReentrant {
        // Verifica cada rodada passada e transfere as recompensas pendentes para o staking
        for (uint256 i = 0; i < roundIds.length; i++) {
            uint256 id = roundIds[i];
            // Verifica se há recompensas em escrow para essa rodada
            uint256 amt = stakingSharePerRound[id];
            if (amt == 0) continue; // Pula se não há nada em escrow
            // Verifica se há peso de stake ativo
            if (stakingAddress == address(0) || IZodPlayStaking(stakingAddress).totalStakeWeight() == 0) {
                emit AutoFlushToStakingSkipped(id, amt, "No active stake or staking address not set");
                continue;
            }
            // Zera o escrow da rodada
            stakingSharePerRound[id] = 0;
            stakingEscrowTotal -= amt;
            // Transfere as recompensas para o contrato de staking
            IERC20(address(miningToken)).safeTransfer(stakingAddress, amt);
            IZodPlayStaking(stakingAddress).accrueMiningReward(amt);
            emit StakingEscrowFlushed(id, amt);
        }
    }

    // ============================ Admin / Config ============================

    function pause() external {
        if (msg.sender != owner()) revert NotOwner();
        _pause();
    }

    function unpause() external {
        if (msg.sender != owner()) revert NotOwner();
        _unpause();
    }

    function setAffiliateHook(address hook) external {
        if (msg.sender != owner()) revert NotOwner();
        affiliateHook = hook;
        emit AffiliateHookUpdated(hook);
    }

    function setStakingAddress(address staking_) external {
        if (msg.sender != owner()) revert NotOwner();
        if (staking_ == address(0)) revert InvalidAddress();
        emit StakingAddressUpdated(stakingAddress, staking_);
        stakingAddress = staking_;
    }

    function setVault(address v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v == address(0)) revert InvalidAddress();
        emit VaultUpdated(address(vault), v);
        vault = IPaymentsVault(v);
    }

    function setTreasury(address t) external {
        if (msg.sender != owner()) revert NotOwner();
        if (t == address(0)) revert InvalidAddress();
        emit TreasuryUpdated(treasury, t);
        treasury = t;
    }

    function setLiquidityPool(address lp) external {
        if (msg.sender != owner()) revert NotOwner();
        if (lp == address(0)) revert InvalidAddress();
        emit LiquidityPoolUpdated(liquidityPool, lp);
        liquidityPool = lp;
    }

    function setMiningToken(address t) external {
        if (msg.sender != owner()) revert NotOwner();
        if (t == address(0)) revert InvalidAddress();
        miningToken = IMiningToken(t);
    }

    function setMiningSplitBps(uint16 bps) external {
        if (msg.sender != owner()) revert NotOwner();
        if (bps > 10000) revert InvalidBps();
        miningStakingBps = bps;
        emit MiningSplitSet(bps);
    }

    function setTicketsPerMiningBlock(uint256 v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v == 0 || v > 1_000_000) revert InvalidQuantity();
        ticketsPerMiningBlock = v;
        emit TicketsPerMiningBlockSet(v);
    }

    function setMaxTicketsPerRoundPerAddress(uint256 v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v == 0) revert InvalidQuantity();
        maxTicketsPerRoundPerAddress = v;
        emit MaxTicketsPerRoundPerAddressSet(v);
    }

    function setDistribution(
        uint256 prizePct,
        uint256 treasuryPct,
        uint256 liquidityPct,
        uint256 commissionPct
    ) external {
        if (msg.sender != owner()) revert NotOwner();
        if (prizePct + treasuryPct + liquidityPct + commissionPct != 100) revert PercentSumInvalid();
        dist = TicketSaleDistribution(prizePct, treasuryPct, commissionPct, liquidityPct);
    }

    function setPrizeTiers(uint8[3] calldata symbols, uint8[3] calldata starReq, uint256[3] calldata perc) external {
        if (msg.sender != owner()) revert NotOwner();
        if (perc[0] + perc[1] + perc[2] != 100) revert PercentSumInvalid();
        if (symbols[0] <= symbols[1] || symbols[1] <= symbols[2]) revert InvalidSymbols();
        for (uint8 i = 0; i < 3; i++) {
            if (symbols[i] < 1 || symbols[i] > 12) revert InvalidSymbols();
            if (starReq[i] > 1) revert InvalidStarReq();
            prizeTiers[i] = PrizeTier(symbols[i], starReq[i], perc[i]);
        }
    }

    function setTicketPrice(uint256 price) external {
        if (msg.sender != owner()) revert NotOwner();
        if (price == 0) revert InvalidPrice();
        ticketPrice = price;
        emit PricesAdjusted(price, paymentTokenDecimals);
    }

    function setRoundDuration(uint64 s) external {
        if (msg.sender != owner()) revert NotOwner();
        if (s < minRoundDuration || s > maxRoundDuration) revert InvalidDuration();
        roundDuration = s;
    }

    function setClaimDeadline(uint64 s) external {
        if (msg.sender != owner()) revert NotOwner();
        claimDeadline = s;
    }

    function setNoWinnerPercents(
        uint256 _t0Carry, uint256 _t0ToT1, uint256 _t0ToT2,
        uint256 _t1Carry, uint256 _t1ToT2,
        uint256 _t2Carry, uint256 _t2Liq
    ) external {
        if (msg.sender != owner()) revert NotOwner();
        if (_t0Carry + _t0ToT1 + _t0ToT2 != DENOM) revert PercentSumInvalid();
        if (_t1Carry + _t1ToT2 != DENOM) revert PercentSumInvalid();
        if (_t2Carry + _t2Liq != DENOM) revert PercentSumInvalid();
        t0CarryPct = _t0Carry; t0ToT1Pct = _t0ToT1; t0ToT2Pct = _t0ToT2;
        t1CarryPct = _t1Carry; t1ToT2Pct = _t1ToT2;
        t2CarryPct = _t2Carry; t2ToLiquidityPct = _t2Liq;
    }

    function setMiningPerBlock(uint256 v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v == 0) revert InvalidQuantity();
        miningPerBlock = v;
    }

    function setMinTicketsForMining(uint256 v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v < 1) revert InvalidQuantity();
        minTicketsForMining = v;
    }

    function setTicketsPerWeight(uint256 v) external {
        if (msg.sender != owner()) revert NotOwner();
        if (v < 1) revert InvalidQuantity();
        ticketsPerWeight = v;
    }

    // MODIFICAÇÃO: Funções para gerenciar vouchers
    function addVouchers(address to, uint256 qty) external {
        if (msg.sender != owner()) revert NotOwner();
        if (vouchersLocked) revert VouchersLocked(); // MODIFICAÇÃO: Uso do erro com parênteses
        if (to == address(0)) revert InvalidAddress();
        if (qty == 0) revert InvalidQuantity();
        availableVouchers[to] += qty;
        emit VouchersAdded(to, qty);
    }

    function lockVouchers() external {
        if (msg.sender != owner()) revert NotOwner();
        vouchersLocked = true;
        emit VouchersLockedEvent(); // MODIFICAÇÃO: Evento renomeado
    }

    // ============================ Views (pagination helpers) ============================

    function getRoundParticipantsLength(uint256 roundId) external view returns (uint256) {
        return roundParticipants[roundId].length;
    }

    function getRoundParticipantsPage(uint256 roundId, uint256 start, uint256 end)
        external view returns (address[] memory out)
    {
        address[] storage arr = roundParticipants[roundId];
        if (end > arr.length) end = arr.length;
        if (start >= end) revert BadRange();
        out = new address[](end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = arr[start + i];
        }
    }

    function getUserTicketsLength(uint256 roundId, address user)
        external view returns (uint256)
    {
        return userTickets[roundId][user].length;
    }

    function getUserTicketsPage(uint256 roundId, address user, uint256 start, uint256 end)
        external view returns (Ticket[] memory out)
    {
        Ticket[] storage arr = userTickets[roundId][user];
        if (end > arr.length) end = arr.length;
        if (start >= end) revert BadRange();
        out = new Ticket[](end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = arr[start + i];
        }
    }

    struct UserTickets { address user; Ticket[] tickets; }

    function getAllTicketsInRound(uint256 roundId, uint256 startParticipant, uint256 endParticipant)
        external view returns (UserTickets[] memory out)
    {
        if (!rounds[roundId].exists) revert RoundNotExist();
        address[] storage participants = roundParticipants[roundId];
        if (endParticipant > participants.length) endParticipant = participants.length;
        if (startParticipant >= endParticipant) revert BadRange();

        uint256[] memory ticketCounts = new uint256[](endParticipant - startParticipant);
        for (uint256 i = 0; i < endParticipant - startParticipant; i++) {
            address user = participants[startParticipant + i];
            if (user == address(0)) continue;
            uint256 ticketLen = userTickets[roundId][user].length;
            ticketCounts[i] = ticketLen;
        }

        out = new UserTickets[](endParticipant - startParticipant);
        uint256 outIndex = 0;
        for (uint256 i = 0; i < endParticipant - startParticipant; i++) {
            address user = participants[startParticipant + i];
            if (user == address(0) || ticketCounts[i] == 0) continue;
            Ticket[] storage userTicketArray = userTickets[roundId][user];
            Ticket[] memory tickets = new Ticket[](ticketCounts[i]);
            for (uint256 j = 0; j < ticketCounts[i]; j++) {
                tickets[j] = userTicketArray[j];
            }
            out[outIndex] = UserTickets({user: user, tickets: tickets});
            outIndex++;
        }

        if (outIndex < out.length) {
            UserTickets[] memory trimmed = new UserTickets[](outIndex);
            for (uint256 i = 0; i < outIndex; i++) {
                trimmed[i] = out[i];
            }
            return trimmed;
        }
        return out;
    }

    function previewMining(uint256 roundId) external view returns (uint256 soldTickets, uint256 numBlocks, uint256 totalMining, uint256 perTicket, uint256 remainder, bool finalized) {
        MiningRoundInfo memory m = miningRoundInfo[roundId];
        return (rounds[roundId].soldTickets, m.numBlocks, m.total, m.perTicket, m.remainder, m.finalized);
    }

    function previewMiningRules() external view returns (uint256 _minTicketsForMining, uint256 _ticketsPerWeight) {
        return (minTicketsForMining, ticketsPerWeight);
    }

    function previewMiningFor(address user, uint256 roundId) external view returns (uint256 userTicketCount, uint256 eligibleTickets, uint256 amount) {
        userTicketCount = userTicketQtyPerRound[roundId][user];
        MiningRoundInfo memory info = miningRoundInfo[roundId];
        if (!info.finalized || info.perTicket == 0 || userTicketCount < minTicketsForMining) {
            return (userTicketCount, 0, 0);
        }
        eligibleTickets = (ticketsPerWeight == 1) ? userTicketCount : (userTicketCount / ticketsPerWeight) * ticketsPerWeight;
        amount = info.perTicket * eligibleTickets;
    }

    function getUserTickets(uint256 roundId, address user) external view returns (Ticket[] memory) {
        if (!rounds[roundId].exists) revert RoundNotExist();
        if (user == address(0)) return new Ticket[](0);
        Ticket[] storage arr = userTickets[roundId][user];
        Ticket[] memory out = new Ticket[](arr.length);
        for (uint256 j = 0; j < arr.length; j++) { out[j] = arr[j]; }
        return out;
    }

    function getCurrentRoundSummary()
        external view
        returns (uint256 id, uint64 endTime, bool drawn, uint256 prizePool, uint256 liquidity, uint256 soldTickets, uint256[3] memory allocatedPerTier)
    {
        id = currentRoundId;
        Round storage r = rounds[id];
        endTime = r.endTime;
        drawn = r.drawn;
        prizePool = r.prizePoolMirror;
        liquidity = r.liquidityPoolMirror;
        soldTickets = r.soldTickets;
        allocatedPerTier = r.allocatedPrizePerTier;
    }

    function isRoundExists(uint256 roundId) external view returns (bool) { return rounds[roundId].exists; }
    function isRoundDrawn(uint256 roundId) external view returns (bool) { return rounds[roundId].drawn; }
    function getRoundFlags(uint256 roundId) external view returns (bool exists, bool drawn, bool winnersValidated) {
        Round storage r = rounds[roundId]; return (r.exists, r.drawn, r.winnersValidated);
    }

    function getRoundWinners(uint256 roundId)
        external view
        returns (address[] memory t0, address[] memory t1, address[] memory t2)
    {
        Winners storage w = winnersByRound[roundId];
        return (w.t0, w.t1, w.t2);
    }

    function getRoundWinnersPaged(uint256 roundId, uint8 tierIndex, uint256 start, uint256 end)
        external view
        returns (address[] memory slice)
    {
        if (tierIndex >= 3) revert InvalidTier();
        address[] storage arr =
            (tierIndex == 0) ? winnersByRound[roundId].t0 :
            (tierIndex == 1) ? winnersByRound[roundId].t1 :
                               winnersByRound[roundId].t2;

        if (end > arr.length) end = arr.length;
        if (start >= end) revert BadRange();

        uint256 len = end - start;
        slice = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            slice[i] = arr[start + i];
        }
    }

    function getRoundWinnersCount(uint256 roundId)
        external view
        returns (uint256 t0count, uint256 t1count, uint256 t2count)
    {
        Winners storage w = winnersByRound[roundId];
        return (w.t0.length, w.t1.length, w.t2.length);
    }

    // ============================ Round lifecycle ============================

    function startNewRound() external {
        if (msg.sender != owner()) revert NotOwner();
        if (rounds[currentRoundId].exists && !rounds[currentRoundId].drawn) revert RoundNotDrawn();
        if (rounds[currentRoundId].exists && rounds[currentRoundId].winnersValidated && !rounds[currentRoundId].noWinnersSettled) revert AlreadySettled();
        _startNewRound();
    }

    function bootstrapFirstRound() external {
        if (msg.sender != owner()) revert NotOwner();
        if (rounds[currentRoundId].exists && rounds[currentRoundId].endTime != 0) revert RoundNotExist();
        _startNewRound();
    }

    function endRoundNow() external whenNotPaused {
        if (msg.sender != owner()) revert NotOwner();
        Round storage r = rounds[currentRoundId];
        if (!r.exists || r.drawn) revert InvalidRound();
        r.endTime = uint64(block.timestamp);
        emit RoundEndedNow(currentRoundId, r.endTime);
    }

    // ============================ Compra / Sorteio / Validação ============================

    function buyTicket(uint16 mask, uint8 star, uint256 qty)
        external whenNotPaused nonReentrant
    {
        Round storage r = rounds[currentRoundId];
        if (!r.exists) revert RoundNotExist();
        if (r.drawn || block.timestamp >= r.endTime) revert RoundClosed();
        if (qty == 0 || qty > maxTicketsPerTx) revert InvalidQuantity();
        if (star >= 10) revert InvalidStar();
        if (_popcount12(mask) != prizeTiers[0].symbolsRequired) revert InvalidMask();
        if ((mask & 0xF000) != 0) revert InvalidMask();

        if (userTicketQtyPerRound[currentRoundId][msg.sender] + qty > maxTicketsPerRoundPerAddress)
            revert MaxTicketsPerRoundExceeded();

        _touchParticipant(currentRoundId, msg.sender);

        // MODIFICAÇÃO: Suporte a vouchers (bilhetes gratuitos)
        uint256 vouchersUsed = 0;
        uint256 maxVouchers = availableVouchers[msg.sender];
        if (maxVouchers > 0) {
            vouchersUsed = (qty > maxVouchers) ? maxVouchers : qty;
            availableVouchers[msg.sender] -= vouchersUsed;
            if (vouchersUsed > 0) emit VouchersUsed(msg.sender, vouchersUsed);
        }
        uint256 paidQty = qty - vouchersUsed;

        // MODIFICAÇÃO: Custo apenas para bilhetes pagos
        uint256 cost = _toPayUnits(ticketPrice * paidQty);
        if (paidQty > 0) {
            vault.collectFrom(msg.sender, cost);
        }

        // MODIFICAÇÃO: Valores internos baseados apenas nos pagos
        uint256 costInternal = _fromPayUnits(cost);
        uint256 prizeAmt = (costInternal * dist.prizePool) / 100;
        uint256 treasuryAmt = (costInternal * dist.treasury) / 100;
        uint256 commAmt = (costInternal * dist.commission) / 100;
        uint256 liqAmt = (costInternal * dist.liquidity) / 100;

        // MODIFICAÇÃO: Creditamos pools apenas com valores de pagos
        vault.creditPools(currentRoundId, IPaymentsVault.Pools({
            prize: _toPayUnits(prizeAmt),
            treasury: _toPayUnits(treasuryAmt),
            commission: _toPayUnits(commAmt),
            liquidity: _toPayUnits(liqAmt)
        }));

        r.prizePoolMirror += prizeAmt;
        r.liquidityPoolMirror += liqAmt;
        r.soldTickets += qty; // Inclui todos os bilhetes (pagos + vouchers)

        r.entropy = keccak256(abi.encodePacked(r.entropy, msg.sender, mask, star, qty, blockhash(block.number - 1)));

        userTickets[currentRoundId][msg.sender].push(Ticket({mask: mask, star: star, qty: uint96(qty)}));
        userTicketQtyPerRound[currentRoundId][msg.sender] += qty;

        emit Bought(msg.sender, currentRoundId, mask, star, qty, cost);

        // Optional affiliate hook
        if (affiliateHook != address(0)) {
            try IAffiliateHook(affiliateHook).onTicketBought(msg.sender, currentRoundId, qty, cost, _toPayUnits(commAmt)) {} catch {}
        }
    }

    function settleNoWinners(uint256 roundId) external {
        if (msg.sender != owner()) revert NotOwner();
        Round storage r = rounds[roundId];
        if (!r.drawn) revert RoundNotDrawn();
        if (!r.winnersValidated) revert WinnersAlreadyValidated();
        if (r.noWinnersSettled) revert AlreadySettled();

        uint256 t0 = r.allocatedPrizePerTier[0];
        uint256 t1 = r.allocatedPrizePerTier[1];
        uint256 t2 = r.allocatedPrizePerTier[2];

        bool t0No = (r.totalWinningQtyPerTier[0] == 0);
        bool t1No = (r.totalWinningQtyPerTier[1] == 0);
        bool t2No = (r.totalWinningQtyPerTier[2] == 0);

        uint256 carry = 0;
        uint256 toT1 = 0;
        uint256 toT2FromT0 = 0;
        uint256 toT2FromT1 = 0;
        uint256 toLiquidity = 0;

        if (t0No && t0 > 0) {
            uint256 carry0 = (t0 * t0CarryPct) / DENOM;
            toT1 = (t0 * t0ToT1Pct) / DENOM;
            toT2FromT0 = (t0 * t0ToT2Pct) / DENOM;

            carry += carry0;
            r.allocatedPrizePerTier[0] = 0;
            r.allocatedPrizePerTier[1] += toT1;
            r.allocatedPrizePerTier[2] += toT2FromT0;
        }
        if (t1No && t1 > 0) {
            uint256 carry1 = (t1 * t1CarryPct) / DENOM;
            toT2FromT1 = (t1 * t1ToT2Pct) / DENOM;

            carry += carry1;
            r.allocatedPrizePerTier[1] = 0;
            r.allocatedPrizePerTier[2] += toT2FromT1;
        }
        if (t2No && t2 > 0) {
            uint256 carry2 = (t2 * t2CarryPct) / DENOM;
            uint256 _toLiquidity = (t2 * t2ToLiquidityPct) / DENOM;

            carry += carry2;
            r.allocatedPrizePerTier[2] = 0;

            if (_toLiquidity > 0) {
                try vault.reallocateBetweenPools(roundId, IPaymentsVault.Pool.Prize, IPaymentsVault.Pool.Liquidity, _toPayUnits(_toLiquidity)) returns (bool okLiq) {
                    if (okLiq) {
                        toLiquidity = _toLiquidity;
                        r.prizePoolMirror -= _toLiquidity;
                        r.liquidityPoolMirror += _toLiquidity;
                    } else {
                        carry += _toLiquidity;
                    }
                } catch {
                    carry += _toLiquidity;
                }
            }
        }

        if (carry > 0) {
            if (r.prizePoolMirror < carry) revert PrizeUnderflow();
            r.carryOverToNextPrize += carry;
            r.prizePoolMirror -= carry;
        }

        r.noWinnersSettled = true;
        emit NoWinnersSettled(roundId, t0No, t1No, t2No, carry, toT1, toT2FromT0 + toT2FromT1, toLiquidity);
    }

    function commit(bytes32 c) external {
        if (msg.sender != owner()) revert NotOwner();
        Round storage r = rounds[currentRoundId];
        if (r.commitSet) revert CommitAlreadySet();
        r.commit = c;
        r.commitSet = true;
        emit CommitSet(currentRoundId, c);
    }

    function drawRound(bytes32 secret) external whenNotPaused {
        if (msg.sender != owner()) revert NotOwner();
        Round storage r = rounds[currentRoundId];
        if (!r.commitSet) revert CommitNotSet();
        if (keccak256(abi.encodePacked(secret)) != r.commit) revert InvalidReveal();
        if (!r.exists || r.drawn || block.timestamp < r.endTime) revert RoundNotReady();

        bytes32 seed = keccak256(abi.encodePacked(secret, blockhash(block.number - 1), currentRoundId));
        uint8 winningStar = uint8(uint256(seed) % 10);
        uint16 winningMask = _generateRandomMask(seed);

        r.winningMask = winningMask;
        r.winningStar = winningStar;
        for (uint8 i = 0; i < 3; i++) {
            r.allocatedPrizePerTier[i] = (r.prizePoolMirror * prizeTiers[i].percent) / 100;
        }
        _finalizeMining();
        r.drawn = true;

        r.commitSet = false;
        r.commit = bytes32(0);
        r.entropy = bytes32(0);

        emit RoundDrawn(currentRoundId, winningMask, winningStar, seed);

        _validateWinnersBatch(currentRoundId, autoValidateBatch);
    }

    function drawIfReady() external whenNotPaused nonReentrant {
        uint256 rid = currentRoundId;
        Round storage r = rounds[rid];
        if (!r.exists || r.drawn) revert InvalidRound();
        if (block.timestamp < r.endTime) revert RoundNotReady();
        _performDraw(rid);
    }

    function endRoundNowAndDraw() external whenNotPaused nonReentrant {
        if (msg.sender != owner()) revert NotOwner();
        uint256 rid = currentRoundId;
        Round storage r = rounds[rid];
        if (!r.exists || r.drawn) revert InvalidRound();
        r.endTime = uint64(block.timestamp);
        _performDraw(rid);
        emit RoundEndedNow(rid, r.endTime);
    }

    function validateWinnersPaged(uint256 roundId, uint256 start, uint256 end)
        external nonReentrant
    {
        if (msg.sender != owner()) revert NotOwner();
        Round storage r = rounds[roundId];
        if (!r.exists) revert RoundNotExist();
        if (!r.drawn) revert RoundNotDrawn();
        if (r.winnersValidated) revert WinnersAlreadyValidated();

        address[] storage users = roundParticipants[roundId];
        if (end > users.length) end = users.length;
        if (start >= end) revert BadRange();

        if (start == 0) {
            r.totalWinningQtyPerTier[0] = 0;
            r.totalWinningQtyPerTier[1] = 0;
            r.totalWinningQtyPerTier[2] = 0;
        }

        for (uint256 i = start; i < end; i++) {
            address user = users[i];
            if (user == address(0)) continue;
            for (uint8 tierIndex = 0; tierIndex < 3; tierIndex++) {
                uint256 winningQty = _userWinningQty(roundId, user, r.winningMask, r.winningStar, tierIndex);
                if (winningQty > 0) {
                    r.totalWinningQtyPerTier[tierIndex] += winningQty;
                    emit Congratulations(user, roundId, tierIndex, winningQty);

                    if (!winnerMarked[roundId][tierIndex][user]) {
                        winnerMarked[roundId][tierIndex][user] = true;

                        if (tierIndex == 0) {
                            winnersByRound[roundId].t0.push(user);
                        } else if (tierIndex == 1) {
                            winnersByRound[roundId].t1.push(user);
                        } else {
                            winnersByRound[roundId].t2.push(user);
                        }

                        emit WinnerRecorded(roundId, user, tierIndex, winningQty);
                    }
                }
            }
        }

        if (end == users.length) {
            r.winnersValidated = true;
            emit WinnersValidated(roundId, r.totalWinningQtyPerTier);
            for (uint8 i = 0; i < 3; i++) {
                uint256 tot = r.totalWinningQtyPerTier[i];
                perWinningTicket[roundId][i] = (tot == 0) ? 0 : (r.allocatedPrizePerTier[i] / tot);
            }
        }
    }

    function _validateWinnersBatch(uint256 roundId, uint256 maxUsers) internal returns (bool done) {
        Round storage r = rounds[roundId];
        if (!r.exists || !r.drawn) revert RoundNotReady();
        if (r.winnersValidated) revert WinnersAlreadyValidated();

        address[] storage users = roundParticipants[roundId];
        uint256 total = users.length;
        if (total == 0) {
            r.winnersValidated = true;
            emit WinnersValidated(roundId, r.totalWinningQtyPerTier);
            emit WinnersValidationProgress(roundId, 0, 0);
            return true;
        }

        uint256 start = winnersValidationCursor[roundId];
        if (start == 0) {
            r.totalWinningQtyPerTier[0] = 0;
            r.totalWinningQtyPerTier[1] = 0;
            r.totalWinningQtyPerTier[2] = 0;
        }

        uint256 end = start + maxUsers;
        if (end > total) end = total;

        for (uint256 i = start; i < end; i++) {
            address user = users[i];
            if (user == address(0)) continue;
            for (uint8 tierIndex = 0; tierIndex < 3; tierIndex++) {
                uint256 winningQty = _userWinningQty(roundId, user, r.winningMask, r.winningStar, tierIndex);
                if (winningQty > 0) {
                    r.totalWinningQtyPerTier[tierIndex] += winningQty;
                    emit Congratulations(user, roundId, tierIndex, winningQty);

                    if (!winnerMarked[roundId][tierIndex][user]) {
                        winnerMarked[roundId][tierIndex][user] = true;

                        if (tierIndex == 0) {
                            winnersByRound[roundId].t0.push(user);
                        } else if (tierIndex == 1) {
                            winnersByRound[roundId].t1.push(user);
                        } else {
                            winnersByRound[roundId].t2.push(user);
                        }

                        emit WinnerRecorded(roundId, user, tierIndex, winningQty);
                    }
                }
            }
        }

        // <<< ESTA É A LINHA QUE FICOU CORROMPIDA >>>
        winnersValidationCursor[roundId] = end;  // apenas isso

        emit WinnersValidationProgress(roundId, end, total);

        if (end == total) {
            r.winnersValidated = true;
            for (uint8 i = 0; i < 3; i++) {
                uint256 tot = r.totalWinningQtyPerTier[i];
                perWinningTicket[roundId][i] = (tot == 0) ? 0 : (r.allocatedPrizePerTier[i] / tot);
            }
            winnersValidationCursor[roundId] = 0;
            emit WinnersValidated(roundId, r.totalWinningQtyPerTier);
            return true;
        }
        return false;
    }


    function validateWinnersAuto(uint256 roundId, uint256 maxUsers)
        external whenNotPaused nonReentrant
        returns (bool done)
    {
        if (maxUsers < 1 || maxUsers > 5000) revert InvalidBatch();
        return _validateWinnersBatch(roundId, maxUsers);
    }

    // ============================ Claims / Withdraws ============================

    function claimTier(uint256 roundId, uint8 tierIndex) external nonReentrant {
        require(tierIndex < 3, "Invalid tier");
        Round storage r = rounds[roundId];
        require(r.exists && r.drawn && r.winnersValidated, "Round not ready");
        require(block.timestamp < r.endTime + claimDeadline, "Claim deadline passed");

        uint256 myQty = _userWinningQty(roundId, msg.sender, r.winningMask, r.winningStar, tierIndex);
        require(myQty > 0, "No winning tickets");

        uint256 alreadyClaimed = userClaimedTickets[roundId][msg.sender][tierIndex];
        require(alreadyClaimed < myQty, "All tickets already claimed");

        uint256 eligibleQty = myQty - alreadyClaimed;
        require(eligibleQty > 0, "No eligible tickets to claim");

        uint256 perTicket = perWinningTicket[roundId][tierIndex];
        require(perTicket > 0, "No prize available");

        uint256 amount = perTicket * eligibleQty;
        if (amount > r.allocatedPrizePerTier[tierIndex]) {
            amount = r.allocatedPrizePerTier[tierIndex];
        }

        userClaimedTickets[roundId][msg.sender][tierIndex] = myQty;
        r.allocatedPrizePerTier[tierIndex] -= amount;
        r.prizePoolMirror -= amount;

        // MODIFICAÇÃO: Convertemos o valor do prêmio para o formato do token
        vault.payPrize(msg.sender, roundId, _toPayUnits(amount), tierIndex);
        emit PrizeClaimed(msg.sender, roundId, amount, tierIndex);
    }

    function claimMining(uint256 roundId) external nonReentrant {
        Round storage r = rounds[roundId];
        if (!r.exists || !r.drawn) revert RoundNotReady();
        if (miningClaimed[msg.sender][roundId]) revert AlreadyClaimed();

        uint256 userTicketCount = userTicketQtyPerRound[roundId][msg.sender];
        if (userTicketCount < minTicketsForMining) revert NotEnoughTickets();

        MiningRoundInfo storage info = miningRoundInfo[roundId];
        if (!info.finalized) revert MiningNotFinalized();
        if (info.perTicket == 0) revert NoRewardAvailable();

        uint256 eligibleTickets = (ticketsPerWeight == 1) ? userTicketCount : (userTicketCount / ticketsPerWeight) * ticketsPerWeight;
        if (eligibleTickets == 0) revert NoEligibleTickets();

        uint256 amount = info.perTicket * eligibleTickets;
        if (amount == 0) revert NoRewardAvailable();

        miningClaimed[msg.sender][roundId] = true;
        miningToken.mint(msg.sender, amount);
        emit MiningClaimed(msg.sender, roundId, amount);
    }

    function withdrawLiquidityPoolFunds(uint256 roundId) external {
        if (msg.sender != owner()) revert NotOwner();
        if (liquidityPool == address(0)) revert LiquidityPoolNotSet();
        Round storage r = rounds[roundId];
        if (!r.exists || !r.drawn || r.liquidityWithdrawn) revert InvalidRound();
        // MODIFICAÇÃO: Convertemos o valor retornado pelo vault para o formato interno
        uint256 paid = _fromPayUnits(vault.withdrawLiquidity(roundId, liquidityPool));
        r.liquidityPoolMirror = 0;
        r.liquidityWithdrawn = true;
        emit LiquidityWithdrawn(roundId, paid, liquidityPool);
    }

    function withdrawUnclaimed(uint256 roundId) external {
        if (msg.sender != owner()) revert NotOwner();
        if (treasury == address(0)) revert TreasuryNotSet();
        Round storage r = rounds[roundId];
        if (!r.exists || !r.drawn) revert InvalidRound();
        if (block.timestamp < r.endTime + claimDeadline) revert ClaimPeriodActive();
        // MODIFICAÇÃO: Convertemos os valores para o formato do token antes de enviar ao vault
        uint256 prizeR = _toPayUnits(r.prizePoolMirror);
        uint256 liqR = _toPayUnits(r.liquidityPoolMirror);
        // MODIFICAÇÃO: Convertemos o valor retornado pelo vault para o formato interno
        uint256 total = _fromPayUnits(vault.withdrawUnclaimed(roundId, treasury, prizeR, 0, liqR));
        r.prizePoolMirror = 0;
        r.liquidityPoolMirror = 0;
        emit UnclaimedWithdrawn(roundId, total, treasury);
    }

    // ============================ Internals ============================

    function _startNewRound() internal {
        uint256 newId = currentRoundId + 1;
        Round storage r = rounds[newId];
        r.exists = true;
        r.endTime = uint64(block.timestamp) + roundDuration;

        if (currentRoundId > 0 && rounds[currentRoundId].carryOverToNextPrize > 0) {
            r.prizePoolMirror += rounds[currentRoundId].carryOverToNextPrize;
            rounds[currentRoundId].carryOverToNextPrize = 0;
        }
        for (uint8 i = 0; i < 3; i++) {
            r.allocatedPrizePerTier[i] = (r.prizePoolMirror * prizeTiers[i].percent) / 100;
        }
        r.commitBlock = uint64(block.number);
        r.entropy = keccak256(abi.encodePacked(blockhash(block.number - 1), newId, address(this)));
        currentRoundId = newId;
        emit RoundStarted(newId, r.endTime);
    }

    function _performDraw(uint256 rid) private {
        Round storage r = rounds[rid];
        if (!r.exists || r.drawn) revert RoundNotReady();

        // usar commitBlock se estiver dentro da janela de 256 blocos
        bytes32 bh;
        if (block.number > r.commitBlock && (block.number - r.commitBlock) <= 256) {
            bh = blockhash(r.commitBlock);
        } else {
            bh = blockhash(block.number - 1);
        }

        bytes32 seed = keccak256(abi.encodePacked(r.entropy, bh, rid, r.soldTickets, address(this)));
        uint8 winningStar = uint8(uint256(seed) % 10);
        uint16 winningMask = _generateRandomMask(seed);

        r.winningMask = winningMask;
        r.winningStar = winningStar;

        for (uint8 i = 0; i < 3; i++) {
            r.allocatedPrizePerTier[i] = (r.prizePoolMirror * prizeTiers[i].percent) / 100;
        }

        _finalizeMining();
        r.drawn = true;
        r.entropy = bytes32(0);

        emit RoundDrawn(rid, winningMask, winningStar, seed);

        _validateWinnersBatch(rid, autoValidateBatch);
    }

    function _finalizeMining() internal {
        if (address(miningToken) == address(0)) revert MiningTokenNotSet();

        uint256 rid = currentRoundId;
        Round storage r = rounds[rid];

        uint256 sold = r.soldTickets;
        if (sold == 0) {
            miningRewardPerRound[rid] = 0;
            MiningRoundInfo storage z = miningRoundInfo[rid];
            z.numBlocks = 0; z.total = 0; z.perTicket = 0; z.remainder = 0; z.finalized = true;
            return;
        }

        uint256 numBlocks = (sold + ticketsPerMiningBlock - 1) / ticketsPerMiningBlock;
        uint256 totalPlanned = numBlocks * miningPerBlock;

        uint256 reward = totalPlanned;
        if (reward > 0 && mintedSoFar + reward > maxMiningSupply) {
            reward = maxMiningSupply - mintedSoFar;
        }
        if (reward == 0) {
            miningRewardPerRound[rid] = 0;
            MiningRoundInfo storage z2 = miningRoundInfo[rid];
            z2.numBlocks = numBlocks; z2.total = 0; z2.perTicket = 0; z2.remainder = 0; z2.finalized = true;
            return;
        }

        uint256 stakingShare = (reward * miningStakingBps) / 10000;
        uint256 userShare = reward - stakingShare;

        if (stakingShare > 0) {
            stakingSharePerRound[rid] = stakingShare;
            miningToken.mint(address(this), stakingShare);
            stakingEscrowTotal += stakingShare;
            emit StakingEscrowed(rid, stakingShare);

            if (stakingAddress != address(0)) {
                try IZodPlayStaking(stakingAddress).totalStakeWeight() returns (uint256 tw) {
                    if (tw > 0) {
                        IERC20 zpm = IERC20(address(miningToken));
                        uint256 amt = stakingShare;
                        stakingSharePerRound[rid] = 0;
                        stakingEscrowTotal -= amt;
                        zpm.safeTransfer(stakingAddress, amt);
                        IZodPlayStaking(stakingAddress).accrueMiningReward(amt);
                        emit StakingEscrowFlushed(rid, amt);
                        emit MiningRewardAccruedToStaking(rid, amt);
                    } else {
                        emit AutoFlushToStakingSkipped(rid, stakingShare, "No active stake");
                    }
                } catch {
                    emit AutoFlushToStakingSkipped(rid, stakingShare, "Staking check failed");
                }
            }
        }

        uint256 perTicket = userShare / sold;
        uint256 rem = userShare % sold;

        mintedSoFar += reward;
        miningRewardPerRound[rid] = userShare;

        MiningRoundInfo storage info = miningRoundInfo[rid];
        info.numBlocks = numBlocks;
        info.total = reward;
        info.perTicket = perTicket;
        info.remainder = rem;
        info.finalized = true;

        emit MiningFinalized(rid, sold, numBlocks, reward, userShare, perTicket, rem);
    }

    function _userWinningQty(uint256 roundId, address user, uint16 wMask, uint8 wStar, uint8 tierIndex) internal view returns (uint256 qty) {
        PrizeTier memory tier = prizeTiers[tierIndex];
        Ticket[] storage arr = userTickets[roundId][user];
        for (uint256 i = 0; i < arr.length; i++) {
            uint8 matched = _countMatchingSymbols(arr[i].mask, wMask);
            bool ok = (matched == tier.symbolsRequired) && (tier.starRequired == 0 || arr[i].star == wStar);
            if (ok) qty += uint256(arr[i].qty);
        }
    }

    function _countMatchingSymbols(uint16 userMask, uint16 winningMask) internal pure returns (uint8) {
        uint16 combined = userMask & winningMask;
        return _popcount12(combined);
    }

    function _generateRandomMask(bytes32 seed) internal view returns (uint16) {
        uint8[12] memory idx = [0,1,2,3,4,5,6,7,8,9,10,11];
        uint256 rnd = uint256(keccak256(abi.encodePacked(seed)));
        for (uint8 i = 11; i > 0; i--) {
            uint256 j = rnd % (i + 1);
            (idx[i], idx[uint8(j)]) = (idx[uint8(j)], idx[i]);
            rnd = uint256(keccak256(abi.encodePacked(rnd)));
        }
        uint16 mask = 0;
        for (uint8 k = 0; k < prizeTiers[0].symbolsRequired; k++) {
            mask |= uint16(1) << idx[k];
        }
        if (_popcount12(mask) != prizeTiers[0].symbolsRequired) revert InvalidMask();
        return mask;
    }

    function _getTokenDecimals(address t) private view returns (uint8) {
        (bool ok, bytes memory data) = t.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint8));
        return 18;
    }

    function _touchParticipant(uint256 rid, address user) internal {
        if (!isParticipant[rid][user]) {
            isParticipant[rid][user] = true;
            roundParticipants[rid].push(user);
        }
    }

    function _popcount12(uint16 x) internal pure returns (uint8) {
        uint16 v = x & 0x0FFF;
        uint8 c;
        while (v != 0) { v &= (v - 1); c++; }
        return c;
    }
}