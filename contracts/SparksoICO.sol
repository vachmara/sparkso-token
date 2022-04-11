// contracts/SparksoIco.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./TokenVesting.sol";

/**
 * @title Sparkso ICO contract
 */
contract SparksoICO is TokenVesting {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // address of the ERC20 token
    IERC20 private immutable _token;

    // Address where funds are collected
    address payable private _wallet;

    // Backend address use to sign and authentificate user purchase
    address private _systemAddress;

    // Bonus is a percentage of your token purchased in addition to your given tokens.
    // If bonus is 30% you will have : number_tokens + number_tokens * (30 / 100)
    // Bonus is different for each stages
    uint8[4] private _bonus;

    // Stages of the ICO
    uint8 public constant STAGES = 4;

    // Manage the current stage of the ICO
    uint8 private _currentStage = 0;

    // Count first 500 purchases
    uint16 private _countAdresses = 0;

    // Delay the ICO _colsingTime
    uint256 private _delay = 0;

    // Total amount wei raised
    uint256 private _weiRaised = 0;

    // Rate is different for each stages.
    // The rate is the conversion between wei and the smallest and indivisible token unit.
    // If the token has 18 decimals, rate of one will be equivalent to: 1 TOKEN * 10 ^ 18 = 1 ETH * 10 ^ 18
    uint256[4] private _rate;

    // Wei goal is different for each stages
    uint256[4] private _weiGoals;

    // Wei goal base on _weiGoals
    uint256 private _totalWeiGoal;

    // Wei mini to invest (used only for the first stage)
    uint256[2] private _minWei;

    // Cliff values for each stages
    uint256[4] private _cliffValues;

    // Vesting value for stage 2,3 and 4 (cf. Whitepaper)
    uint256 private _vestingValue;

    // Vesting slice period
    uint256 private _slicePeriod;

    // Opening ICO time
    uint256 private _openingTime;

    // Closing ICO time
    uint256 private _closingTime;

    // First 500 addresses purchasing tokens
    mapping(address => uint8) private _firstAddresses;

    // Purchased cliff or not
    bool private _cliff;

    // Purchased vest or not
    bool private _vest;

    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     * @param cliff cliff tokens or not
     * @param vesting vesting tokens or not
     */
    event TokensPurchase(
        address indexed purchaser,
        address indexed beneficiary,
        uint256 value,
        uint256 amount,
        bool cliff,
        bool vesting
    );

    /**
     * @dev Reverts if the beneficiary has already purchase whithin the first 500.
     */
    modifier onlyOnePurchase(address _beneficiary) {
        require(
            _firstAddresses[_beneficiary] == 0,
            "Sparkso ICO: One transaction per wallet for the 500 first."
        );
        _;
    }

    /**
     * @dev Reverts if the purchase is not sign by the backend system wallet address
     */
    modifier onlyValidSignature(uint256 timestamp, bytes memory signature) {
        // Encode the msg.sender with the timestamp to
        bytes32 msgHash = keccak256(abi.encodePacked(msg.sender, timestamp));
        bytes32 signedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)
        );
        require(
            signedHash.recover(signature) == _systemAddress,
            "Sparkso ICO: Invalid purchase signature."
        );
        _;
    }

    constructor(
        address systemAddress_,
        address payable wallet_,
        address token_
    ) TokenVesting(token_) {
        require(
            systemAddress_ != address(0x0),
            "Sparkso ICO: system address is the zero address"
        );
        require(
            wallet_ != address(0x0),
            "Sparkso ICO: wallet is the zero address"
        );
        require(
            token_ != address(0x0),
            "Sparkso ICO: token contract is the zero address"
        );

        _systemAddress = systemAddress_;
        _wallet = wallet_;
        _token = IERC20(token_);

        // Constant corresponding to the number of _token allocated to each stage
        // Use to calulate rates
        uint88[4] memory TOKENS_ALLOCATED = [
            14070000 * 10**18,
            35175000 * 10**18,
            42210000 * 10**18,
            49245000 * 10**18
        ];

        // Input values Rate and Bonus
        _bonus = [20, 15, 10, 0];

        // Input values in MATIC multiply by 10^18 to convert into wei
        _weiGoals = [
            422221 * 10**18, // Stage 1 wei goal (ETH or chain governance currency)
            1583330 * 10**18, // Stage 2 wei goal (ETH or chain governance currency)
            2533328 * 10**18, // Stage 3 wei goal (ETH or chain governance currency)
            3324993 * 10**18 // Stage 4 wei goal (ETH or chain governance currency)
        ];

        for (uint256 i = 0; i < STAGES; i++)
            _rate[i] = TOKENS_ALLOCATED[i] / _weiGoals[i];

        _minWei = [
            375 * 10**18, // Stage 1 first 500 people
            150 * 10**18
        ];

        // Calculate _totalWeiGoal
        for (uint8 i = 0; i < STAGES; i++) _totalWeiGoal += _weiGoals[i];

        // 30 days into seconds
        uint256 monthSecond = 30 * 24 * 3600;

        // Input values in seconds corresponding to cliff for each stages
        _cliffValues = [0, 0, 1 * monthSecond, 2 * monthSecond];
        // Input value in seconds corresponding to vesting for each stages
        _vestingValue = 3 * monthSecond;
        // Input value in second corresponding to token time release slices
        _slicePeriod = 10 * 24 * 3600;

        // Input value timestamp in second of the opening ICO time
        _openingTime = 1646485200; // The 5th march 2022
        _closingTime = _openingTime + (monthSecond * 4);

        // Cliff is applied only for stage 3 and 4 (cf. Whitepaper)
        _cliff = false;
        // Vesting is applied only for stage 2, 3 and 4 (cf. Whitepaper)
        _vest = false;
    }

    // -----------------------------------------
    // External interface
    // -----------------------------------------

    /**
     * @return _countAddresses
     */
    function countAdresses() external view returns (uint16) {
        return _countAdresses;
    }

    /**
     * @return _weiRaised total amount wei raised.
     */
    function weiRaised() external view returns (uint256) {
        return _weiRaised;
    }

    /**
     * @return _currentStage of the ICO.
     */
    function currentStage() external view returns (uint8) {
        return _currentStage;
    }

    /**
     * @return _rate number of token units a buyer gets per wei for each stages.
     */
    function rate() external view returns (uint256[4] memory) {
        return _rate;
    }

    /**
     * @return _weiGoals number of tokens allocated for each stages
     */
    function weiGoals() external view returns (uint256[4] memory) {
        return _weiGoals;
    }

    /**
     * @return _bonus for each stages
     */
    function bonus() external view returns (uint8[4] memory) {
        return _bonus;
    }

    /**
     * @return _openingTime of the ICO
     */
    function openingTime() external view returns (uint256) {
        return _openingTime;
    }

    /**
     * @return _closingTime of the ICO 
     */
    function closingTime() external view returns (uint256) {
        return _closingTime + _delay;
    }

    /**
     * @dev low level token purchase
     * @param _beneficiary Address performing the token purchase
     * @param _timestamp Timestamp + msg.sender address use to build signature
     * @param _signature Signature need to be sign by system wallet
     */
    function buyTokens(
        address _beneficiary,
        uint256 _timestamp,
        bytes memory _signature
    ) public payable onlyValidSignature(_timestamp, _signature) {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(_beneficiary, weiAmount);

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(weiAmount);

        // update state
        _weiRaised = _weiRaised + weiAmount;

        _processPurchase(_beneficiary, tokens);
        emit TokensPurchase(
            msg.sender,
            _beneficiary,
            weiAmount,
            tokens,
            _cliff,
            _vest
        );

        _updatePurchasingState();

        _forwardFunds();
        _postValidatePurchase(_beneficiary);
    }

    /**
     * @dev Delay the ICO _closingTime
     * @param _timeToDelay Add a time delay in seconds
     */
    function delayICO(uint256 _timeToDelay) public nonReentrant onlyOwner {
        require(
            _timeToDelay > 0,
            "Sparkso ICO: the delay need to be superior to 0."
        );
        _delayICO(_timeToDelay);
    }

    /**
     * @dev Update the wei goals with the associated rates and the minimum wei to participate to first ICO stage.
     * @dev This functionnality will be used to control crypto assets volatility.
     * @param _newWeiGoal The current stage new wei goal.
     * @param _newMinWei Array of the new minimal wei to participate to the first stage.
     */
    function updateICO(uint256 _newWeiGoal, uint256[2] memory _newMinWei)
        public
        nonReentrant
        onlyOwner
    {   
        if (_currentStage == 0)
            require(
                _newMinWei.length == 2,
                "Sparkso ICO: _newMinWei array must have a length of 2."
            );

        
        _updateICO(_newWeiGoal, _newMinWei);
    }

    // -----------------------------------------
    // Internal interface
    // -----------------------------------------

    /**
     * @dev Determines how ETH is stored/forwarded on purchases.
     */
    function _forwardFunds() internal {
        Address.sendValue(_wallet, msg.value);
    }

    /**
     * @dev Delay the ICO
     */
    function _delayICO(uint256 _time) internal virtual {
        // Convert the delay time into seconds and add to the current delay
        _delay = _delay + _time;
    }

    /**
     * @dev Update the current wei goals, mininum wei goal and rates of the ICO
     * @param _newWeiGoal The current stage new wei goal.
     * @param _newMinWei Array of the new minimal wei to participate to the first stage.
     */
    function _updateICO(uint256 _newWeiGoal, uint256[2] memory _newMinWei)
        internal
    {
        // Constant corresponding to the number of tokens allocated to each stage
        // Use to calulate rates
        uint88[4] memory TOKENS_ALLOCATED = [
            14070000 * 10**18,
            35175000 * 10**18,
            42210000 * 10**18,
            49245000 * 10**18
        ];
        if (_currentStage == 0) {
            for (uint8 i = 0; i < 2; i++) {
                require(
                    _newMinWei[i] >= 0,
                    "SparksoICO: _newMinWei need to be superior or equal to 0."
                );
                _minWei[i] = _newMinWei[i];
            }
        }

        _weiGoals[_currentStage] = _newWeiGoal;
        
        uint256  currentStageVestingTokens = this.getVestingSchedulesTotalAmount();

        // Substract sum of allocated tokens in previous stages
        for(uint i = 0; i < _currentStage; i++) currentStageVestingTokens -= TOKENS_ALLOCATED[i];
        
        uint256 currentStageTokensRemaining = TOKENS_ALLOCATED[_currentStage] - currentStageVestingTokens;
        
        uint256 weiRaised_ = _weiRaised;
        // Update the wei raised for the current stage
        for(uint i = 0; i < _currentStage; i++) weiRaised_ -= _weiGoals[i];

        _rate[_currentStage] = currentStageTokensRemaining / (_newWeiGoal - weiRaised_);
        
        // Calculate _totalWeiGoal
        for (uint8 i = 0; i < STAGES; i++) _totalWeiGoal += _weiGoals[i];
    }

    /**
     * @dev Update ICO stage and add addresses if it is 500 first purchase
     * @param _beneficiary Address performing the token purchase
     */
    function _postValidatePurchase(address _beneficiary) internal {
        // Add address if in the 500 first buyers
        if (_getCountAddresses() < 500) {
            _firstAddresses[_beneficiary] = 1;
            _countAdresses++;
        }

        uint256 weiGoal = 0;
        for (uint8 i = 0; i <= _currentStage; i++)
            weiGoal = weiGoal + _weiGoals[i];

        if (_weiRaised >= weiGoal && _currentStage < STAGES) {
            _currentStage++;
            // Cliff is applied only for stage 3 and 4 (cf. Whitepaper)
            _cliff = _currentStage >= 2 ? true : false;
            // Vesting is applied only for stage 2, 3 and 4 (cf. Whitepaper)
            _vest = _currentStage != 0 ? true : false;
        }
    }

    /**
     * @dev Create a vesting schedule starting at the closing time of the ICO
     * @param _beneficiary Address performing the token purchase
     * @param _tokenAmount Number of tokens to be emitted
     */
    function _deliverTokens(address _beneficiary, uint256 _tokenAmount)
        internal
    {
        uint256 vestingValue = _currentStage == 0 ? 1 : _vestingValue;
        uint256 slicePeriod = _currentStage == 0 ? 1 : _slicePeriod;

        _createVestingSchedule(
            _beneficiary,
            _closingTime,
            _cliffValues[_currentStage],
            vestingValue,
            slicePeriod,
            false,
            _tokenAmount
        );
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Not necessarily emits/sends tokens.
     * @param _beneficiary Address receiving the tokens
     * @param _tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address _beneficiary, uint256 _tokenAmount)
        internal
    {
        _deliverTokens(_beneficiary, _tokenAmount);
    }

    /**
     * @dev Calculate the number of tokens depending on current ICO stage with corresponding rate and bonus
     * @param _weiAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function _getTokenAmount(uint256 _weiAmount)
        internal
        view
        returns (uint256)
    {
        uint256 rate_ = _rate[_currentStage];
        uint256 tokens = _weiAmount * rate_;
        uint256 bonus_ = _getCountAddresses() > 500
            ? tokens * _bonus[_currentStage]
            : tokens * 30; // 500 first bonus equal to 30%
        return tokens + (bonus_ / 100);
    }

    /**
     * @return the number of people (within the 500 ones) who purchased tokens
     */
    function _getCountAddresses() internal view virtual returns (uint256) {
        return _countAdresses;
    }

    /**
     * @return current time minus the actual delay to control the closing times
     */
    function _getCurrentTime() internal view virtual override returns (uint256) {
        return block.timestamp - _delay;
    }

    /**
     * @dev Validation of an incoming purchase.
     * @param _beneficiary Address performing the token purchase
     * @param _weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount)
        internal
        view
        onlyOnePurchase(_beneficiary)
    {
        require(
            _beneficiary != address(0x0),
            "Sparkso ICO: beneficiary address should be defined."
        );
        require(
            _getCurrentTime() >= _openingTime,
            "Sparkso ICO: ICO didn't start."
        );
        require(
            _getCurrentTime() <= _closingTime,
            "Sparkso ICO: ICO is now closed, times up."
        );
        require(
            _weiRaised < _totalWeiGoal,
            "Sparkso ICO: ICO is now closed, all funds are raised."
        );

        if (_currentStage > 0)
            require(
                _weiAmount > 0,
                "Sparkso ICO: Amount need to be superior to 0."
            );
        else {
            // Minimum wei for the first 500 people else the second minimum wei
            uint256 minWei = _getCountAddresses() < 500
                ? _minWei[0]
                : _minWei[1];
            require(
                _weiAmount >= minWei,
                "Sparkso ICO: Amount need to be superior to the minimum wei defined."
            );
        }
    }

    /**
     * @dev Update purchasing state.
     */
    function _updatePurchasingState() internal pure {}
}
