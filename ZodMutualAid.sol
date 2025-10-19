// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// NOVO COMENTÁRIO: Imports mantidos – ferramentas de segurança do OpenZeppelin, como no PHP com try-catch.
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IZodStaking {
    function depositByRouter(address user, uint256 amount) external;
}

contract ZodMutualAid is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // NOVO COMENTÁRIO: Declaração dos eventos existentes e novos.
    // Evento pra quando um usuário se registra no contrato, com ou sem upline.
    event Registered(address indexed user, address indexed upline, uint256 treeId);
    // Evento pra quando uma nova árvore é criada com um root.
    event NewTree(uint256 indexed treeId, address indexed root);
    // Evento pra quando os valores dos níveis (D) são configurados.
    event LevelsConfigured(uint256[5] values);
    // Evento pra quando um novo board é criado.
    event BoardCreated(uint256 indexed boardId, uint8 level, uint256 indexed treeId, address indexed center);
    // Evento pra quando um novo board é criado pra um construtor que virou gerente.
    event NewBoardForConstructor(uint256 indexed oldBoardId, uint256 newBoardId, address indexed newCenter);
    
    // NOVO COMENTÁRIO: Novos eventos adicionados pra corrigir os erros de compilação.
    // Registra quando uma quantia é creditada ao beneficiário do upline em um board.
    event UpstreamCredited(uint256 indexed boardId, address indexed beneficiary, uint256 amount);
    // Registra quando uma quantia fica pendente pra ser creditada em um board.
    event UpstreamPending(uint256 indexed boardId, uint256 amount);
    // Registra quando valores são reservados pro advanceEscrow ou recycleEscrow de um usuário.
    event EscrowReserved(address indexed user, uint8 level, uint256 advanceAmount, uint256 recycleAmount);
    // Registra o progresso do ciclo de um gerente em um nível.
    event ManagerCycleProgress(address indexed center, uint8 level, uint8 cycleCount);
    // Registra quando a role de um usuário muda (ex.: Doador -> Construtor -> Gerente).
    event RoleChanged(address indexed user, uint8 level, Role newRole, uint256 directs);
    // Registra o processamento de uma doação, com detalhes de quem doou, pra quem, e valores.
    event DonationProcessed(
        uint256 indexed boardId,
        uint8 level,
        uint256 indexed treeId,
        address indexed donor,
        address payTo,
        uint256 toStaking,
        uint256 remainingBase,
        uint256 toUp
    );
    // Registra quando um usuário saca uma quantia do saldo disponível.
    event Withdraw(address indexed user, uint256 amount);
    // Registra quando o advanceEscrow é usado pra avançar pro próximo nível.
    event AutoAdvanceUsed(address indexed user, uint8 nextLevel, uint256 targetBoard);
    // Registra quando o recycleEscrow é usado pra reciclar no mesmo nível.
    event AutoRecycleUsed(address indexed user, uint8 level, uint256 targetBoard);

    IERC20 public immutable usdt;
    IZodStaking public staking;

    uint8 public constant MAX_LEVEL = 4; // NOVO COMENTÁRIO: 4 níveis, como PHP.
    uint8 public constant MIN_LEVEL = 1;

    uint8 public BOARD_LOGICAL_CAP = 13; // NOVO COMENTÁRIO: 13 posições (1 gerente + 4 construtores + 8 doadores).
    uint8 public MAX_ASC_DEPTH = 12;
    uint8 public MANAGER_CYCLE_TARGET = 10; // NOVO COMENTÁRIO: Mantido, mas menos usado, já que divisão é por directs.
    uint64 public MIN_AUTOGAP_BLOCKS = 2;
    bool public useBuckets = true;

    uint256[5] public D; // NOVO COMENTÁRIO: [5,15,60,240] pra níveis 1-4.

    uint256 public nextTreeId = 1;
    mapping(address => bool) public registered;
    mapping(address => address) public uplineOf;
    mapping(address => uint256) public treeOf;
    mapping(uint256 => address) public treeRoot;

    enum Role { Doador, Construtor, Gerente }
    mapping(address => mapping(uint8 => uint256)) public directs;
    mapping(address => mapping(uint8 => Role)) public roleOf;
    mapping(address => mapping(uint8 => bool)) public firstDonationDone;
    mapping(address => mapping(uint8 => bool)) public hasPassedLevel;

    mapping(address => uint256) public availableBalance;
    mapping(address => mapping(uint8 => uint256)) public advanceEscrow;
    mapping(address => mapping(uint8 => uint256)) public recycleEscrow;
    mapping(address => mapping(uint8 => bool)) public recycleOptIn;

    mapping(address => mapping(uint8 => bool)) public autoAdvance;
    mapping(address => mapping(uint8 => bool)) public autoRecycle;
    mapping(address => mapping(uint8 => uint256)) private _lastAutoBlock;
    mapping(address => mapping(uint8 => uint256)) private _lastAutoExec;

    mapping(address => mapping(uint8 => uint256)) public advanceTargetBoard;
    mapping(address => mapping(uint8 => uint256)) public recycleTargetBoard;
    mapping(address => mapping(uint8 => uint256)) public preferredBoard;

    uint256 public nextBoardId = 1;

    struct Board {
        uint256 id;
        uint8 level;
        uint256 treeId;
        bool active;
        address center; // NOVO COMENTÁRIO: Gerente.
        uint8 occupancy;
        address upBeneficiary;
        uint256 upPending;
        uint8 cycleCount;
        uint256 cycles;
        address[12] donors; // NOVO COMENTÁRIO: 8 doadores + espaço extra.
        address[4] constructors; // NOVO COMENTÁRIO: Novo! Rastreia 4 construtores.
    }
    mapping(uint256 => Board) public boards;

    mapping(uint256 => mapping(uint8 => uint256[])) public boardsByTreeLevel;
    mapping(uint256 => mapping(uint8 => mapping(uint8 => uint256[]))) public boardsBucket;
    mapping(uint256 => mapping(uint8 => mapping(uint8 => mapping(uint256 => uint256)))) private _bucketIndex;
    mapping(uint256 => uint8) public boardLoad;

    mapping(address => mapping(uint8 => uint256)) public managerBoard;

    bool public autoCreateIfNoBoard = true;
    bool public requirePreviousLevelClosed = true;
    bool public mustBeActiveOnPrevLevel = false;
    bool public mustFollowUplineOnRecycle = true;

    mapping(uint8 => bool) public canEnterLevelDirect;

    uint256 private _totAvail;
    uint256 private _totAdvEscrow;
    uint256 private _totRecEscrow;
    uint256 private _totUpPending;

    constructor(address _usdt, address _staking) Ownable(msg.sender) {
        require(_usdt != address(0), "USDT zero");
        require(_staking != address(0), "Staking zero");
        usdt = IERC20(_usdt);
        staking = IZodStaking(_staking);
        D[1] = 5; D[2] = 15; D[3] = 60; D[4] = 240;
        canEnterLevelDirect[1] = true;
        canEnterLevelDirect[2] = true;
    }

    function setLevels(uint256[4] calldata values) external onlyOwner {
        for (uint8 i = 1; i <= MAX_LEVEL; i++) {
            require(values[i-1] > 0, "level=0");
            D[i] = values[i-1];
        }
        emit LevelsConfigured(D);
    }

    function setParams(uint8 cap, uint8 maxAscDepth, uint8 cycleTarget, uint64 autoGapBlocks, bool useBuckets_) external onlyOwner {
        require(cap >= 2 && cap <= 13, "cap 2..13");
        BOARD_LOGICAL_CAP = cap;
        MAX_ASC_DEPTH = maxAscDepth;
        MANAGER_CYCLE_TARGET = cycleTarget;
        MIN_AUTOGAP_BLOCKS = autoGapBlocks;
        useBuckets = useBuckets_;
    }

    function register(address upline) external {
        require(!registered[msg.sender], "already");
        if (upline == address(0)) {
            uint256 tid = nextTreeId++;
            treeRoot[tid] = msg.sender;
            treeOf[msg.sender] = tid;
            registered[msg.sender] = true;
            emit NewTree(tid, msg.sender);
            emit Registered(msg.sender, address(0), tid);
        } else {
            require(registered[upline], "upline not registered");
            uint256 tid2 = treeOf[upline];
            treeOf[msg.sender] = tid2;
            uplineOf[msg.sender] = upline;
            registered[msg.sender] = true;
            emit Registered(msg.sender, upline, tid2);
        }
    }

    function donate(uint256 boardId, uint256 amount) external nonReentrant whenNotPaused {
        require(registered[msg.sender], "not registered");
        Board storage b = boards[boardId];
        require(b.active, "board inactive");
        require(b.level >= MIN_LEVEL && b.level <= MAX_LEVEL, "bad level");
        require(amount == D[b.level], "amount != D[level]");

        usdt.safeTransferFrom(msg.sender, address(this), amount);

        uint256 toStaking = amount / 2;
        _safeStake(msg.sender, toStaking);

        uint256 basePart = amount - toStaking;
        uint256 toUp = 0;
        if (b.level < MAX_LEVEL) {
            uint256 repUp = D[b.level + 1] / 10;
            if (repUp > 0) {
                if (b.upBeneficiary != address(0)) {
                    availableBalance[b.upBeneficiary] += repUp;
                    _totAvail += repUp;
                    toUp = repUp;
                    emit UpstreamCredited(boardId, b.upBeneficiary, repUp);
                } else {
                    b.upPending += repUp;
                    _totUpPending += repUp;
                    emit UpstreamPending(boardId, b.upPending);
                }
            }
        }
        uint256 remainingBase = basePart - toUp;

        address payTo = b.center;
        address directUp = uplineOf[msg.sender];
        if (directUp != address(0) && _isCenterOfBoard(boardId, directUp) && roleOf[directUp][b.level] == Role.Construtor) {
            payTo = directUp;
        }

        (uint256 addedAdv, uint256 addedRec, uint256 netAvail) = _reserveForReceiver(payTo, b.level, remainingBase);
        if (netAvail > 0) {
            availableBalance[payTo] += netAvail;
            _totAvail += netAvail;
        }
        emit EscrowReserved(payTo, b.level, addedAdv, addedRec);

        // NOVO COMENTÁRIO: Adiciona doador ao board, e atualiza construtores se necessário.
        if (roleOf[msg.sender][b.level] == Role.Doador && payTo == b.center) {
            if (b.occupancy < BOARD_LOGICAL_CAP) {
                b.donors[b.occupancy - 1] = msg.sender;
                _updateBoardLoadOnChange(b.id, b.treeId, b.level, b.occupancy, b.occupancy + 1);
            }
            b.cycleCount += 1;
            emit ManagerCycleProgress(b.center, b.level, b.cycleCount);
        }

        // NOVO COMENTÁRIO: Checa se upline vira gerente com 2 indicados.
        if (!firstDonationDone[msg.sender][b.level]) {
            firstDonationDone[msg.sender][b.level] = true;
            if (directUp != address(0)) {
                directs[directUp][b.level] += 1;
                Role newRole = _roleFromDirects(directs[directUp][b.level]);
                if (newRole != roleOf[directUp][b.level]) {
                    roleOf[directUp][b.level] = newRole;
                    emit RoleChanged(directUp, b.level, newRole, directs[directUp][b.level]);
                    // NOVO COMENTÁRIO: Se vira construtor, adiciona ao array constructors.
                    if (newRole == Role.Construtor) {
                        for (uint8 i = 0; i < 4; i++) {
                            if (b.constructors[i] == address(0)) {
                                b.constructors[i] = directUp;
                                break;
                            }
                        }
                    }
                    // NOVO COMENTÁRIO: Se vira gerente (directs >= 2), cria novo board com indicados como construtores.
                    if (newRole == Role.Gerente) {
                        uint256 newBoardId = _createBoardForConstructor(directUp, b.level, b.treeId, msg.sender);
                        emit NewBoardForConstructor(boardId, newBoardId, directUp);
                    }
                }
            }
        }

        _processAutoActions(payTo, b.level);
        if (payTo != b.center) _processAutoActions(b.center, b.level);

        _assertSolvency();
        emit DonationProcessed(boardId, b.level, b.treeId, msg.sender, payTo, toStaking, remainingBase, toUp);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(availableBalance[msg.sender] >= amount, "insufficient");
        availableBalance[msg.sender] -= amount;
        _totAvail -= amount;
        _assertSolvency();
        usdt.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function useAdvanceEscrow(uint8 nextLevel) external nonReentrant whenNotPaused {
        require(nextLevel >= MIN_LEVEL && nextLevel <= MAX_LEVEL, "bad level");
        uint256 need = D[nextLevel];
        require(advanceEscrow[msg.sender][nextLevel] >= need, "escrow not full");
        advanceEscrow[msg.sender][nextLevel] -= need;
        _totAdvEscrow -= need;
        uint256 tgt = _resolveAdvanceTarget(msg.sender, nextLevel);
        require(tgt != 0, "no target board");
        _internalDonate(tgt, msg.sender, need);
        _assertSolvency();
        emit AutoAdvanceUsed(msg.sender, nextLevel, tgt);
    }

    function useRecycleEscrow(uint8 level) external nonReentrant whenNotPaused {
        require(level >= MIN_LEVEL && level <= MAX_LEVEL, "bad level");
        require(recycleOptIn[msg.sender][level], "recycle off");
        uint256 need = D[level];
        require(recycleEscrow[msg.sender][level] >= need, "escrow not full");
        recycleEscrow[msg.sender][level] -= need;
        _totRecEscrow -= need;
        uint256 tgt = _resolveRecycleTarget(msg.sender, level);
        require(tgt != 0, "no target board");
        _internalDonate(tgt, msg.sender, need);
        _assertSolvency();
        emit AutoRecycleUsed(msg.sender, level, tgt);
    }

    function _safeStake(address user, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = usdt.balanceOf(address(this));
        require(bal >= amount, "Insufficient USDT for staking");
        usdt.safeApprove(address(staking), 0);
        usdt.safeApprove(address(staking), amount);
        staking.depositByRouter(user, amount);
    }

    function _createBoardForConstructor(address newCenter, uint8 level, uint256 treeId, address newConstructor) internal returns (uint256 id) {
        // NOVO COMENTÁRIO: Cria tabuleiro pra construtor que virou gerente, com 2 indicados como construtores.
        require(registered[newCenter], "center not registered");
        id = nextBoardId++;
        Board storage b = boards[id];
        b.id = id;
        b.level = level;
        b.treeId = treeId;
        b.active = true;
        b.center = newCenter;
        b.occupancy = 1;
        // NOVO COMENTÁRIO: Adiciona o indicado atual como primeiro construtor.
        b.constructors[0] = newConstructor;
        b.occupancy += 1;
        directs[newConstructor][level] += 1; // NOVO COMENTÁRIO: Indicado vira construtor.
        roleOf[newConstructor][level] = Role.Construtor;
        emit RoleChanged(newConstructor, level, Role.Construtor, directs[newConstructor][level]);

        boardsByTreeLevel[treeId][level].push(id);
        managerBoard[newCenter][level] = id;
        if (useBuckets) {
            _insertBoardInBucket(treeId, level, 1, id);
        }
        if (level < MAX_LEVEL && advanceTargetBoard[newCenter][level+1] == 0) {
            advanceTargetBoard[newCenter][level+1] = _chooseBoardFor(_userOrUpline(newCenter), uint8(level+1), treeId);
        }
        if (recycleTargetBoard[newCenter][level] == 0) {
            recycleTargetBoard[newCenter][level] = _chooseBoardFor(newCenter, level, treeId);
        }
        emit BoardCreated(id, level, treeId, newCenter);
        return id;
    }

    function _isCenterOfBoard(uint256 boardId, address user) internal view returns (bool) {
        return boards[boardId].center == user;
    }

    function _roleFromDirects(uint256 d) internal pure returns (Role) {
        if (d >= 2) return Role.Gerente;
        if (d >= 1) return Role.Construtor;
        return Role.Doador;
    }

    function _reserveForReceiver(address user, uint8 level, uint256 amount)
        internal
        returns (uint256 addedAdv, uint256 addedRec, uint256 netAvail)
    {
        uint256 remaining = amount;
        if (!hasPassedLevel[user][level] && level < MAX_LEVEL) {
            uint8 nextL = level + 1;
            uint256 needAdv = D[nextL];
            uint256 curAdv = advanceEscrow[user][nextL];
            if (curAdv < needAdv) {
                uint256 add = needAdv - curAdv;
                if (add > remaining) add = remaining;
                if (add > 0) {
                    advanceEscrow[user][nextL] = curAdv + add;
                    _totAdvEscrow += add;
                    remaining -= add;
                    addedAdv = add;
                    if (advanceTargetBoard[user][nextL] == 0) {
                        advanceTargetBoard[user][nextL] = _chooseBoardFor(_userOrUpline(user), nextL, treeOf[user]);
                    }
                }
            }
        }
        if (recycleOptIn[user][level]) {
            uint256 needRec = D[level];
            uint256 curRec = recycleEscrow[user][level];
            if (curRec < needRec) {
                uint256 add2 = needRec - curRec;
                if (add2 > remaining) add2 = remaining;
                if (add2 > 0) {
                    recycleEscrow[user][level] = curRec + add2;
                    _totRecEscrow += add2;
                    remaining -= add2;
                    addedRec = add2;
                    if (recycleTargetBoard[user][level] == 0) {
                        recycleTargetBoard[user][level] = _chooseBoardFor(user, level, treeOf[user]);
                    }
                }
            }
        }
        netAvail = remaining;
    }

    function _processAutoActions(address user, uint8 level) internal whenNotPaused {
        if (_lastAutoBlock[user][level] == block.number) return;
        if (block.number < _lastAutoExec[user][level] + MIN_AUTOGAP_BLOCKS) return;
        _lastAutoBlock[user][level] = block.number;
        _lastAutoExec[user][level] = block.number;

        if (!hasPassedLevel[user][level] && level < MAX_LEVEL && autoAdvance[user][level+1]) {
            uint8 nextL = level + 1;
            uint256 need = D[nextL];
            if (advanceEscrow[user][nextL] >= need) {
                uint256 tgt = _resolveAdvanceTarget(user, nextL);
                if (tgt != 0) {
                    advanceEscrow[user][nextL] -= need;
                    _totAdvEscrow -= need;
                    _internalDonate(tgt, user, need);
                    emit AutoAdvanceUsed(user, nextL, tgt);
                }
            }
        }
        if (recycleOptIn[user][level] && autoRecycle[user][level]) {
            uint256 needR = D[level];
            if (recycleEscrow[user][level] >= needR) {
                uint256 tgtR = _resolveRecycleTarget(user, level);
                if (tgtR != 0) {
                    recycleEscrow[user][level] -= needR;
                    _totRecEscrow -= needR;
                    _internalDonate(tgtR, user, needR);
                    emit AutoRecycleUsed(user, level, tgtR);
                }
            }
        }
    }

    function _internalDonate(uint256 boardId, address user, uint256 amount) internal whenNotPaused {
        Board storage b = boards[boardId];
        require(b.active, "board inactive");
        require(treeOf[user] == b.treeId, "wrong tree");
        require(amount == D[b.level], "amount != D[level]");

        uint256 toStaking = amount / 2;
        _safeStake(user, toStaking);

        uint256 basePart = amount - toStaking;
        uint256 toUp = 0;
        if (b.level < MAX_LEVEL) {
            uint256 repUp = D[b.level + 1] / 10;
            if (repUp > 0) {
                if (b.upBeneficiary != address(0)) {
                    availableBalance[b.upBeneficiary] += repUp;
                    _totAvail += repUp;
                    toUp = repUp;
                    emit UpstreamCredited(boardId, b.upBeneficiary, repUp);
                } else {
                    b.upPending += repUp;
                    _totUpPending += repUp;
                    emit UpstreamPending(boardId, b.upPending);
                }
            }
        }
        uint256 remainingBase = basePart - toUp;

        address payTo = b.center;
        address directUp = uplineOf[user];
        if (directUp != address(0) && _isCenterOfBoard(boardId, directUp) && roleOf[directUp][b.level] == Role.Construtor) {
            payTo = directUp;
        }

        (uint256 addedAdv, uint256 addedRec, uint256 netAvail) = _reserveForReceiver(payTo, b.level, remainingBase);
        if (netAvail > 0) {
            availableBalance[payTo] += netAvail;
            _totAvail += netAvail;
        }
        emit EscrowReserved(payTo, b.level, addedAdv, addedRec);

        if (!firstDonationDone[user][b.level]) {
            firstDonationDone[user][b.level] = true;
            if (directUp != address(0)) {
                directs[directUp][b.level] += 1;
                Role newRole = _roleFromDirects(directs[directUp][b.level]);
                if (newRole != roleOf[directUp][b.level]) {
                    roleOf[directUp][b.level] = newRole;
                    emit RoleChanged(directUp, b.level, newRole, directs[directUp][b.level]);
                    if (newRole == Role.Construtor) {
                        for (uint8 i = 0; i < 4; i++) {
                            if (b.constructors[i] == address(0)) {
                                b.constructors[i] = directUp;
                                break;
                            }
                        }
                    }
                    if (newRole == Role.Gerente) {
                        uint256 newBoardId = _createBoardForConstructor(directUp, b.level, b.treeId, user);
                        emit NewBoardForConstructor(boardId, newBoardId, directUp);
                    }
                }
            }
        }

        if (roleOf[user][b.level] == Role.Doador && payTo == b.center) {
            if (b.occupancy < BOARD_LOGICAL_CAP) {
                b.donors[b.occupancy - 1] = user;
                _updateBoardLoadOnChange(b.id, b.treeId, b.level, b.occupancy, b.occupancy + 1);
            }
            b.cycleCount += 1;
            emit ManagerCycleProgress(b.center, b.level, b.cycleCount);
        }

        _processAutoActions(payTo, b.level);
        if (payTo != b.center) _processAutoActions(b.center, b.level);

        _assertSolvency();
    }

    function _resolveAdvanceTarget(address user, uint8 nextLevel) internal returns (uint256) {
        uint256 tgt = advanceTargetBoard[user][nextLevel];
        if (tgt != 0 && _hasVacancy(tgt)) return tgt;
        tgt = _chooseBoardFor(_userOrUpline(user), nextLevel, treeOf[user]);
        advanceTargetBoard[user][nextLevel] = tgt;
        preferredBoard[user][nextLevel] = tgt;
        return tgt;
    }

    function _resolveRecycleTarget(address user, uint8 level) internal returns (uint256) {
        uint256 tgt = recycleTargetBoard[user][level];
        if (tgt != 0 && _hasVacancy(tgt)) return tgt;
        tgt = _chooseBoardFor(user, level, treeOf[user]);
        recycleTargetBoard[user][level] = tgt;
        preferredBoard[user][level] = tgt;
        return tgt;
    }

    function _userOrUpline(address user) internal view returns (address) {
        address up = uplineOf[user];
        return up != address(0) ? up : user;
    }

    function _chooseBoardFor(address preferUpline, uint8 level, uint256 tid) internal returns (uint256) {
        if (mustFollowUplineOnRecycle) {
            uint256 upBoard = managerBoard[preferUpline][level];
            if (_hasVacancy(upBoard)) return upBoard;
        }
        uint256 asc = _findAscendantBoard(preferUpline, level);
        if (asc != 0) return asc;
        uint256 any = _findAnyBoardWithLeastLoad(tid, level);
        if (any != 0) return any;
        if (autoCreateIfNoBoard) {
            return _createBoardForConstructor(preferUpline, level, tid, preferUpline);
        }
        return 0;
    }

    function _findAscendantBoard(address from, uint8 level) internal view returns (uint256) {
        address cur = uplineOf[from];
        for (uint8 hops = 0; hops < MAX_ASC_DEPTH && cur != address(0); hops++) {
            uint256 bId = managerBoard[cur][level];
            if (_hasVacancy(bId)) return bId;
            cur = uplineOf[cur];
        }
        return 0;
    }

    function _findAnyBoardWithLeastLoad(uint256 tid, uint8 level) internal view returns (uint256) {
        if (useBuckets) {
            for (uint8 load = 1; load < BOARD_LOGICAL_CAP; load++) {
                uint256[] storage arr = boardsBucket[tid][level][load];
                if (arr.length > 0) {
                    uint256 candidate = arr[0];
                    if (_hasVacancy(candidate)) return candidate;
                }
            }
            return 0;
        } else {
            uint256[] storage list = boardsByTreeLevel[tid][level];
            uint256 best = 0;
            uint8 bestLoad = type(uint8).max;
            uint256 limit = list.length > 30 ? 30 : list.length;
            for (uint256 i = 0; i < limit; i++) {
                uint256 id = list[i];
                if (!_hasVacancy(id)) continue;
                uint8 load = boards[id].occupancy;
                if (load < bestLoad) {
                    bestLoad = load;
                    best = id;
                }
            }
            return best;
        }
    }

    function _hasVacancy(uint256 boardId) internal view returns (bool) {
        if (boardId == 0) return false;
        Board storage b = boards[boardId];
        return b.active && b.occupancy < BOARD_LOGICAL_CAP;
    }

    function _insertBoardInBucket(uint256 tid, uint8 level, uint8 load, uint256 boardId) internal {
        if (!useBuckets) return;
        boardsBucket[tid][level][load].push(boardId);
        _bucketIndex[tid][level][load][boardId] = boardsBucket[tid][level][load].length - 1;
        boardLoad[boardId] = load;
    }

    function _removeBoardFromBucket(uint256 tid, uint8 level, uint8 load, uint256 boardId) internal {
        if (!useBuckets) return;
        uint256[] storage arr = boardsBucket[tid][level][load];
        if (arr.length == 0) return;

        uint256 idx = _bucketIndex[tid][level][load][boardId];
        if (idx >= arr.length || arr[idx] != boardId) {
            bool found = false;
            for (uint256 i = 0; i < arr.length; i++) {
                if (arr[i] == boardId) {
                    idx = i;
                    found = true;
                    break;
                }
            }
            if (!found) return;
        }

        uint256 lastId = arr[arr.length - 1];
        arr[idx] = lastId;
        _bucketIndex[tid][level][load][lastId] = idx;
        arr.pop();
        delete _bucketIndex[tid][level][load][boardId];
    }

    function _updateBoardLoadOnChange(uint256 boardId, uint256 tid, uint8 level, uint8 oldLoad, uint8 newLoad) internal {
        if (oldLoad == newLoad) return;
        if (newLoad == 0) newLoad = 1;
        if (newLoad >= BOARD_LOGICAL_CAP) newLoad = BOARD_LOGICAL_CAP - 1;

        boards[boardId].occupancy = newLoad;

        if (useBuckets) {
            if (oldLoad != 0) _removeBoardFromBucket(tid, level, oldLoad, boardId);
            _insertBoardInBucket(tid, level, newLoad, boardId);
        }
        boardLoad[boardId] = newLoad;
    }

    function getBoard(uint256 boardId)
        external view
        returns (
            uint8 level,
            uint256 treeId,
            bool active,
            address center,
            uint8 occupancy,
            address upBeneficiary,
            uint256 upPending,
            uint8 cycleCount,
            uint256 cycles,
            address[12] memory donors,      // NOVO COMENTÁRIO: Adicionado 'memory' pra corrigir TypeError
            address[4] memory constructors  // NOVO COMENTÁRIO: Adicionado 'memory' pra corrigir TypeError
        )
    {
        Board storage b = boards[boardId];
        return (b.level, b.treeId, b.active, b.center, b.occupancy, b.upBeneficiary, b.upPending, b.cycleCount, b.cycles, b.donors, b.constructors);
    }

    function listBoardsByTreeLevel(uint256 tid, uint8 level) external view returns (uint256[] memory) {
        return boardsByTreeLevel[tid][level];
    }

    function _assertSolvency() internal view {
        uint256 liab = _totAvail + _totAdvEscrow + _totRecEscrow + _totUpPending;
        require(usdt.balanceOf(address(this)) >= liab, "USDT<Liabilities");
    }
}