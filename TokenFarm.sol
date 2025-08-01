// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./DappToken.sol";
import "./LPToken.sol";

/**
 * @title Proportional Token Farm
 * @notice Una granja de staking donde las recompensas se distribuyen proporcionalmente al total stakeado.
 * @dev Implementa yield farming con recompensas proporcionales, fees de retiro, y sistema de proxy
 */
contract TokenFarm {
    //
    // Variables de estado
    //
    string public name = "Proportional Token Farm";
    address public owner;
    DAppToken public dappToken;
    LPToken public lpToken;

    // Bonus 4: Recompensas variables por bloque
    uint256 public rewardPerBlock = 1e18; // Recompensa por bloque (total para todos los usuarios)
    uint256 public constant MIN_REWARD_PER_BLOCK = 0.1e18;
    uint256 public constant MAX_REWARD_PER_BLOCK = 10e18;
    
    uint256 public totalStakingBalance; // Total de tokens en staking

    // Bonus 5: Comisión de retiro
    uint256 public withdrawalFee = 100; // 1% (100/10000)
    uint256 public constant MAX_WITHDRAWAL_FEE = 1000; // 10% máximo
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public collectedFees; // Fees acumuladas

    address[] public stakers;

    // Bonus 2: Struct para información de usuario
    struct UserInfo {
        uint256 stakingBalance;
        uint256 checkpoint;
        uint256 pendingRewards;
        bool hasStaked;
        bool isStaking;
    }

    mapping(address => UserInfo) public userInfo;

    // Eventos
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount, uint256 fee);
    event RewardsDistributed(uint256 totalUsers);
    event RewardPerBlockChanged(uint256 oldRate, uint256 newRate);
    event WithdrawalFeeChanged(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed owner, uint256 amount);

    // Bonus 1: Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "TokenFarm: caller is not the owner");
        _;
    }

    modifier onlyStaker() {
        require(userInfo[msg.sender].isStaking, "TokenFarm: caller is not staking");
        _;
    }

    modifier validAmount(uint256 _amount) {
        require(_amount > 0, "TokenFarm: amount must be greater than 0");
        _;
    }

    // Constructor
    constructor(DAppToken _dappToken, LPToken _lpToken) {
        dappToken = _dappToken;
        lpToken = _lpToken;
        owner = msg.sender;
    }

    /**
     * @notice Deposita tokens LP para staking.
     * @param _amount Cantidad de tokens LP a depositar.
     */
    function deposit(uint256 _amount) external validAmount(_amount) {
        // Transferir tokens LP del usuario a este contrato
        lpToken.transferFrom(msg.sender, address(this), _amount);
        
        UserInfo storage user = userInfo[msg.sender];
        
        // Actualizar el balance de staking del usuario
        user.stakingBalance += _amount;
        
        // Incrementar totalStakingBalance
        totalStakingBalance += _amount;
        
        // Si el usuario nunca ha hecho staking antes, agregarlo al array stakers
        if (!user.hasStaked) {
            stakers.push(msg.sender);
            user.hasStaked = true;
        }
        
        // Actualizar isStaking del usuario a true
        user.isStaking = true;
        
        // Si checkpoints del usuario está vacío, inicializarlo con el número de bloque actual
        if (user.checkpoint == 0) {
            user.checkpoint = block.number;
        }
        
        // Llamar a distributeRewards para calcular y actualizar las recompensas pendientes
        distributeRewards(msg.sender);
        
        // Emitir evento de depósito
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Retira todos los tokens LP en staking.
     */
    function withdraw() external onlyStaker {
        UserInfo storage user = userInfo[msg.sender];
        uint256 balance = user.stakingBalance;
        
        // Verificar que el balance de staking sea mayor a 0
        require(balance > 0, "TokenFarm: staking balance is zero");
        
        // Llamar a distributeRewards para calcular y actualizar las recompensas pendientes
        distributeRewards(msg.sender);
        
        // Restablecer stakingBalance del usuario a 0
        user.stakingBalance = 0;
        
        // Reducir totalStakingBalance
        totalStakingBalance -= balance;
        
        // Actualizar isStaking del usuario a false
        user.isStaking = false;
        
        // Transferir los tokens LP de vuelta al usuario
        lpToken.transfer(msg.sender, balance);
        
        // Emitir evento de retiro
        emit Withdraw(msg.sender, balance);
    }

    /**
     * @notice Reclama recompensas pendientes con fee de retiro.
     */
    function claimRewards() external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 pendingAmount = user.pendingRewards;
        
        // Verificar que el monto de recompensas pendientes sea mayor a 0
        require(pendingAmount > 0, "TokenFarm: no pending rewards");
        
        // Bonus 5: Calcular fee de retiro
        uint256 fee = (pendingAmount * withdrawalFee) / FEE_DENOMINATOR;
        uint256 netAmount = pendingAmount - fee;
        
        // Restablecer las recompensas pendientes del usuario a 0
        user.pendingRewards = 0;
        
        // Acumular fees
        collectedFees += fee;
        
        // Transferir las recompensas netas al usuario
        dappToken.mint(msg.sender, netAmount);
        
        // Emitir evento de reclamo de recompensas
        emit RewardsClaimed(msg.sender, netAmount, fee);
    }

    /**
     * @notice Distribuye recompensas a todos los usuarios en staking.
     */
    function distributeRewardsAll() external onlyOwner {
        uint256 userCount = 0;
        
        // Iterar sobre todos los usuarios en staking
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            if (userInfo[staker].isStaking) {
                distributeRewards(staker);
                userCount++;
            }
        }
        
        // Emitir evento indicando que las recompensas han sido distribuidas
        emit RewardsDistributed(userCount);
    }

    /**
     * @notice Calcula y distribuye las recompensas proporcionalmente al staking total.
     * @param beneficiary Dirección del usuario para calcular recompensas
     */
    function distributeRewards(address beneficiary) internal virtual {
        UserInfo storage user = userInfo[beneficiary];
        uint256 lastCheckpoint = user.checkpoint;
        
        // Verificar condiciones para distribución
        if (block.number <= lastCheckpoint || totalStakingBalance == 0 || user.stakingBalance == 0) {
            return;
        }
        
        // Calcular bloques transcurridos
        uint256 blocksPassed = block.number - lastCheckpoint;
        
        // Calcular proporción del usuario
        uint256 userShare = (user.stakingBalance * 1e18) / totalStakingBalance;
        
        // Calcular recompensas
        uint256 rewards = (rewardPerBlock * blocksPassed * userShare) / 1e18;
        
        // Actualizar recompensas pendientes
        user.pendingRewards += rewards;
        
        // Actualizar checkpoint
        user.checkpoint = block.number;
    }

    // Bonus 4: Función para cambiar recompensas por bloque
    /**
     * @notice Cambia la tasa de recompensas por bloque (solo owner)
     * @param _newRewardPerBlock Nueva tasa de recompensas por bloque
     */
    function setRewardPerBlock(uint256 _newRewardPerBlock) external onlyOwner {
        require(
            _newRewardPerBlock >= MIN_REWARD_PER_BLOCK && 
            _newRewardPerBlock <= MAX_REWARD_PER_BLOCK,
            "TokenFarm: reward rate out of bounds"
        );
        
        // Distribuir recompensas a todos antes de cambiar la tasa
        for (uint256 i = 0; i < stakers.length; i++) {
            if (userInfo[stakers[i]].isStaking) {
                distributeRewards(stakers[i]);
            }
        }
        
        uint256 oldRate = rewardPerBlock;
        rewardPerBlock = _newRewardPerBlock;
        
        emit RewardPerBlockChanged(oldRate, _newRewardPerBlock);
    }

    // Bonus 5: Funciones para manejo de fees
    /**
     * @notice Cambia el fee de retiro (solo owner)
     * @param _newFee Nuevo fee de retiro en basis points (100 = 1%)
     */
    function setWithdrawalFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= MAX_WITHDRAWAL_FEE, "TokenFarm: fee too high");
        
        uint256 oldFee = withdrawalFee;
        withdrawalFee = _newFee;
        
        emit WithdrawalFeeChanged(oldFee, _newFee);
    }

    /**
     * @notice Permite al owner retirar las fees acumuladas
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = collectedFees;
        require(amount > 0, "TokenFarm: no fees to withdraw");
        
        collectedFees = 0;
        dappToken.mint(owner, amount);
        
        emit FeesWithdrawn(owner, amount);
    }

    // Funciones de vista
    /**
     * @notice Obtiene información completa del usuario
     * @param _user Dirección del usuario
     * @return Información del usuario
     */
    function getUserInfo(address _user) external view returns (UserInfo memory) {
        return userInfo[_user];
    }

    /**
     * @notice Calcula recompensas pendientes actualizadas de un usuario
     * @param _user Dirección del usuario
     * @return Recompensas pendientes actualizadas
     */
    function pendingRewards(address _user) external view virtual returns (uint256) {
        UserInfo memory user = userInfo[_user];
        
        if (block.number <= user.checkpoint || totalStakingBalance == 0 || user.stakingBalance == 0) {
            return user.pendingRewards;
        }
        
        uint256 blocksPassed = block.number - user.checkpoint;
        uint256 userShare = (user.stakingBalance * 1e18) / totalStakingBalance;
        uint256 newRewards = (rewardPerBlock * blocksPassed * userShare) / 1e18;
        
        return user.pendingRewards + newRewards;
    }

    /**
     * @notice Obtiene el número total de stakers
     * @return Número de stakers
     */
    function getStakersCount() external view returns (uint256) {
        return stakers.length;
    }

    /**
     * @notice Obtiene información del staker por índice
     * @param _index Índice en el array de stakers
     * @return Dirección del staker
     */
    function getStakerByIndex(uint256 _index) external view returns (address) {
        require(_index < stakers.length, "TokenFarm: index out of bounds");
        return stakers[_index];
    }

    /**
     * @notice Mintea LP tokens para testing (solo owner)
     * @param to Dirección que recibirá los LP tokens
     * @param amount Cantidad de LP tokens a mintear
     */
    function mintLPTokensForTesting(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TokenFarm: cannot mint to zero address");
        require(amount > 0, "TokenFarm: amount must be greater than 0");
        lpToken.mint(to, amount);
        emit LPTokensMinted(to, amount);
    }

    /**
     * @notice Transfiere ownership del LP token (solo owner)
     * @param newOwner Nueva dirección que será owner del LP token
     */
    function transferLPTokenOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "TokenFarm: new owner is the zero address");
        lpToken.transferOwnership(newOwner);
        emit LPTokenOwnershipTransferred(newOwner);
    }

    // Eventos
    event LPTokensMinted(address indexed to, uint256 amount);
    event LPTokenOwnershipTransferred(address indexed newOwner);
}
