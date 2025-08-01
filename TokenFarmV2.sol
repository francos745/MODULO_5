// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./TokenFarm.sol";

/**
 * @title TokenFarmV2
 * @notice Versión 2 del TokenFarm con características adicionales
 * @dev Esta es la implementación V2 para ser usada con proxy
 */
contract TokenFarmV2 is TokenFarm {
    // Nuevas variables de estado para V2
    uint256 public constant VERSION = 2;
    
    // Variables adicionales para V2
    mapping(address => uint256) public userBoostMultiplier; // Multiplicador de boost por usuario
    uint256 public maxBoostMultiplier = 200; // 2x máximo (200%)
    bool public boostEnabled = true;
    
    // Nuevos eventos
    event BoostMultiplierSet(address indexed user, uint256 multiplier);
    event BoostStatusChanged(bool enabled);
    event MaxBoostMultiplierChanged(uint256 oldMax, uint256 newMax);

    // Constructor para proxy (inicialización vacía)
    constructor() TokenFarm(DAppToken(address(0)), LPToken(address(0))) {}

    /**
     * @notice Inicializa el contrato V2 (usado por proxy)
     * @param _dappToken Dirección del token DAPP
     * @param _lpToken Dirección del token LP
     */
    function initializeV2(DAppToken _dappToken, LPToken _lpToken) external {
        require(address(dappToken) == address(0), "Already initialized");
        dappToken = _dappToken;
        lpToken = _lpToken;
        owner = msg.sender;
        rewardPerBlock = 1e18;
        withdrawalFee = 100;
    }

    /**
     * @notice Establece multiplicador de boost para un usuario
     * @param _user Usuario al que aplicar el boost
     * @param _multiplier Multiplicador en porcentaje (100 = 1x, 200 = 2x)
     */
    function setUserBoostMultiplier(address _user, uint256 _multiplier) external onlyOwner {
        require(_multiplier >= 100 && _multiplier <= maxBoostMultiplier, "Invalid multiplier");
        userBoostMultiplier[_user] = _multiplier;
        emit BoostMultiplierSet(_user, _multiplier);
    }

    /**
     * @notice Cambia el estado del sistema de boost
     * @param _enabled Si el boost está habilitado
     */
    function setBoostEnabled(bool _enabled) external onlyOwner {
        boostEnabled = _enabled;
        emit BoostStatusChanged(_enabled);
    }

    /**
     * @notice Cambia el multiplicador máximo de boost
     * @param _maxMultiplier Nuevo multiplicador máximo
     */
    function setMaxBoostMultiplier(uint256 _maxMultiplier) external onlyOwner {
        require(_maxMultiplier >= 100 && _maxMultiplier <= 500, "Invalid max multiplier"); // Máximo 5x
        uint256 oldMax = maxBoostMultiplier;
        maxBoostMultiplier = _maxMultiplier;
        emit MaxBoostMultiplierChanged(oldMax, _maxMultiplier);
    }

    /**
     * @notice Calcula recompensas con boost aplicado
     * @param beneficiary Usuario para calcular recompensas
     */
    function distributeRewards(address beneficiary) internal override {
        UserInfo storage user = userInfo[beneficiary];
        uint256 lastCheckpoint = user.checkpoint;
        
        if (block.number <= lastCheckpoint || totalStakingBalance == 0 || user.stakingBalance == 0) {
            return;
        }
        
        uint256 blocksPassed = block.number - lastCheckpoint;
        uint256 userShare = (user.stakingBalance * 1e18) / totalStakingBalance;
        uint256 baseRewards = (rewardPerBlock * blocksPassed * userShare) / 1e18;
        
        // Aplicar boost si está habilitado
        uint256 finalRewards = baseRewards;
        if (boostEnabled && userBoostMultiplier[beneficiary] > 0) {
            finalRewards = (baseRewards * userBoostMultiplier[beneficiary]) / 100;
        }
        
        user.pendingRewards += finalRewards;
        user.checkpoint = block.number;
    }

    /**
     * @notice Obtiene el multiplicador efectivo de un usuario
     * @param _user Usuario a consultar
     * @return Multiplicador efectivo (100 = 1x)
     */
    function getEffectiveMultiplier(address _user) external view returns (uint256) {
        if (!boostEnabled || userBoostMultiplier[_user] == 0) {
            return 100; // 1x
        }
        return userBoostMultiplier[_user];
    }

    /**
     * @notice Calcula recompensas pendientes con boost incluido
     * @param _user Usuario a consultar
     * @return Recompensas pendientes con boost
     */
    function pendingRewards(address _user) external view override returns (uint256) {
        UserInfo memory user = userInfo[_user];
        
        if (block.number <= user.checkpoint || totalStakingBalance == 0 || user.stakingBalance == 0) {
            return user.pendingRewards;
        }
        
        uint256 blocksPassed = block.number - user.checkpoint;
        uint256 userShare = (user.stakingBalance * 1e18) / totalStakingBalance;
        uint256 baseRewards = (rewardPerBlock * blocksPassed * userShare) / 1e18;
        
        // Aplicar boost si está habilitado
        uint256 newRewards = baseRewards;
        if (boostEnabled && userBoostMultiplier[_user] > 0) {
            newRewards = (baseRewards * userBoostMultiplier[_user]) / 100;
        }
        
        return user.pendingRewards + newRewards;
    }

    /**
     * @notice Función especial para migración de datos desde V1
     * @param _users Array de usuarios a migrar
     * @param _stakingBalances Array de balances de staking
     * @param _pendingRewards Array de recompensas pendientes
     */
    function migrateUsersFromV1(
        address[] calldata _users,
        uint256[] calldata _stakingBalances,
        uint256[] calldata _pendingRewards
    ) external onlyOwner {
        require(
            _users.length == _stakingBalances.length && 
            _users.length == _pendingRewards.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < _users.length; i++) {
            UserInfo storage user = userInfo[_users[i]];
            user.stakingBalance = _stakingBalances[i];
            user.pendingRewards = _pendingRewards[i];
            user.checkpoint = block.number;
            user.hasStaked = _stakingBalances[i] > 0;
            user.isStaking = _stakingBalances[i] > 0;
            
            if (_stakingBalances[i] > 0) {
                stakers.push(_users[i]);
                totalStakingBalance += _stakingBalances[i];
            }
        }
    }
}
