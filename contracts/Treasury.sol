pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IMasonry.sol";

contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public current;
    address public lyte;
    address public amp;

    address public loop;
    address public currentOracle;

    // price
    uint256 public currentPriceOne;
    uint256 public currentPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of CURRENT price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochCurrentPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra CURRENT during debt phase

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 currentAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 currentAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event LoopFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(block.timestamp >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(block.timestamp >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getCurrentPrice() > currentPriceCeiling) ? 0 : getCurrentCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(current).operator() == address(this) &&
                IBasisAsset(lyte).operator() == address(this) &&
                IBasisAsset(amp).operator() == address(this) &&
                Operator(loop).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getCurrentPrice() public view returns (uint256 currentPrice) {
        try IOracle(currentOracle).consult(current, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult CURRENT price from the oracle");
        }
    }

    function getCurrentUpdatedPrice() public view returns (uint256 _currentPrice) {
        try IOracle(currentOracle).twap(current, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult CURRENT price from the oracle");
        }
    }

    // lyteget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableCurrentLeft() public view returns (uint256 _burnableCurrentLeft) {
        uint256 _currentPrice = getCurrentPrice();
        if (_currentPrice <= currentPriceOne) {
            uint256 _currentSupply = getCurrentCirculatingSupply();
            uint256 _bondMaxSupply = _currentSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(lyte).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableCurrent = _maxMintableBond.mul(_currentPrice).div(1e18);
                _burnableCurrentLeft = Math.min(epochSupplyContractionLeft, _maxBurnableCurrent);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _currentPrice = getCurrentPrice();
        if (_currentPrice > currentPriceCeiling) {
            uint256 _totalCurrent = IERC20(current).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalCurrent.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _currentPrice = getCurrentPrice();
        if (_currentPrice <= currentPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = currentPriceOne;
            } else {
                uint256 _bondAmount = currentPriceOne.mul(1e18).div(_currentPrice); // to burn 1 CURRENT
                uint256 _discountAmount = _bondAmount.sub(currentPriceOne).mul(discountPercent).div(10000);
                _rate = currentPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _currentPrice = getCurrentPrice();
        if (_currentPrice > currentPriceCeiling) {
            uint256 _currentPricePremiumThreshold = currentPriceOne.mul(premiumThreshold).div(100);
            if (_currentPrice >= _currentPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _currentPrice.sub(currentPriceOne).mul(premiumPercent).div(10000);
                _rate = currentPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = currentPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _current,
        address _lyte,
        address _amp,
        address _currentOracle,
        address _loop
    ) public notInitialized {
        current = _current;
        lyte = _lyte;
        amp = _amp;
        currentOracle = _currentOracle;
        loop = _loop;
        startTime = block.timestamp + 2 hours;

        currentPriceOne = 10**18;
        currentPriceCeiling = currentPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [400, 300, 225, 150, 100, 75, 50, 40];        

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for loop
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn CURRENT and mint LYTE)
        maxDebtRatioPercent = 3500; // Upto 35% supply of LYTE to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 4;
        bootstrapSupplyExpansionPercent = 250;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(current).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLoop(address _loop) external onlyOperator {
        loop = _loop;
    }

    function setCurrentOracle(address _currentOracle) external onlyOperator {
        currentOracle = _currentOracle;
    }

    function setCurrentPriceCeiling(uint256 _currentPriceCeiling) external onlyOperator {
        require(_currentPriceCeiling >= currentPriceOne && _currentPriceCeiling <= currentPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        currentPriceCeiling = _currentPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= currentPriceCeiling, "_premiumThreshold exceeds currentPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCurrentPrice() internal {
        try IOracle(currentOracle).update() {} catch {}
    }

    function getCurrentCirculatingSupply() public view returns (uint256) {
        IERC20 currentErc20 = IERC20(current);
        uint256 totalSupply = currentErc20.totalSupply();
        uint256 balanceExcluded = 0;
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _currentAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_currentAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 currentPrice = getCurrentPrice();
        require(currentPrice == targetPrice, "Treasury: CURRENT price moved");
        require(
            currentPrice < currentPriceOne, // price < $1
            "Treasury: currentPrice not eligible for bond purchase"
        );

        require(_currentAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _currentAmount.mul(_rate).div(1e18);
        uint256 currentSupply = getCurrentCirculatingSupply();
        uint256 newBondSupply = IERC20(lyte).totalSupply().add(_bondAmount);
        require(newBondSupply <= currentSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(current).burnFrom(msg.sender, _currentAmount);
        IBasisAsset(lyte).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_currentAmount);
        _updateCurrentPrice();

        emit BoughtBonds(msg.sender, _currentAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 currentPrice = getCurrentPrice();
        require(currentPrice == targetPrice, "Treasury: CURRENT price moved");
        require(
            currentPrice > currentPriceCeiling, // price > $1.01
            "Treasury: currentPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _currentAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(current).balanceOf(address(this)) >= _currentAmount, "Treasury: treasury has no more lyteget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _currentAmount));

        IBasisAsset(lyte).burnFrom(msg.sender, _bondAmount);
        IERC20(current).safeTransfer(msg.sender, _currentAmount);

        _updateCurrentPrice();

        emit RedeemedBonds(msg.sender, _currentAmount, _bondAmount);
    }

    function _sendToMasonry(uint256 _amount) internal {
        IBasisAsset(current).mint(address(this), _amount);

        IERC20(current).safeApprove(loop, 0);
        IERC20(current).safeApprove(loop, _amount);
        IMasonry(loop).allocateSeigniorage(_amount);
        emit LoopFunded(block.timestamp, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _currentSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_currentSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateCurrentPrice();
        previousEpochCurrentPrice = getCurrentPrice();
        uint256 currentSupply = getCurrentCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToMasonry(currentSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochCurrentPrice > currentPriceCeiling) {
                // Expansion ($CURRENT Price > 1 $FUSE): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(lyte).totalSupply();
                uint256 _percentage = previousEpochCurrentPrice.sub(currentPriceOne);
                uint256 _savedForBond;
                uint256 _savedForLoop;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(currentSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForLoop = currentSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = currentSupply.mul(_percentage).div(1e18);
                    _savedForLoop = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForLoop);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForLoop > 0) {
                    _sendToMasonry(_savedForLoop);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(current).mint(address(this), _savedForBond);
                    emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(current), "current");
        require(address(_token) != address(amp), "amp");
        require(address(_token) != address(lyte), "lyte");
        _token.safeTransfer(_to, _amount);
    }

    function loopSetOperator(address _operator) external onlyOperator {
        IMasonry(loop).setOperator(_operator);
    }

    function loopSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IMasonry(loop).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function loopAllocateSeigniorage(uint256 amount) external onlyOperator {
        IMasonry(loop).allocateSeigniorage(amount);
    }

    function loopGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IMasonry(loop).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
