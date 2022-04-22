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
    address public amp;
    address public lyte;
    address public current;

    address public loop;
    address public ampOracle;

    // price
    uint256 public ampPriceOne;
    uint256 public ampPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of AMP price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochAmpPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra AMP during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 ampAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 ampAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event LoopFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

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
        epochSupplyContractionLeft = (getAmpPrice() > ampPriceCeiling) ? 0 : getAmpCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(amp).operator() == address(this) &&
                IBasisAsset(lyte).operator() == address(this) &&
                IBasisAsset(current).operator() == address(this) &&
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
    function getAmpPrice() public view returns (uint256 ampPrice) {
        try IOracle(ampOracle).consult(amp, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult AMP price from the oracle");
        }
    }

    function getAmpUpdatedPrice() public view returns (uint256 _ampPrice) {
        try IOracle(ampOracle).twap(amp, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult AMP price from the oracle");
        }
    }

    // lyteget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableAmpLeft() public view returns (uint256 _burnableAmpLeft) {
        uint256 _ampPrice = getAmpPrice();
        if (_ampPrice <= ampPriceOne) {
            uint256 _ampSupply = getAmpCirculatingSupply();
            uint256 _bondMaxSupply = _ampSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(lyte).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableAmp = _maxMintableBond.mul(_ampPrice).div(1e18);
                _burnableAmpLeft = Math.min(epochSupplyContractionLeft, _maxBurnableAmp);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _ampPrice = getAmpPrice();
        if (_ampPrice > ampPriceCeiling) {
            uint256 _totalAmp = IERC20(amp).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalAmp.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _ampPrice = getAmpPrice();
        if (_ampPrice <= ampPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = ampPriceOne;
            } else {
                uint256 _bondAmount = ampPriceOne.mul(1e18).div(_ampPrice); // to burn 1 AMP
                uint256 _discountAmount = _bondAmount.sub(ampPriceOne).mul(discountPercent).div(10000);
                _rate = ampPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _ampPrice = getAmpPrice();
        if (_ampPrice > ampPriceCeiling) {
            uint256 _ampPricePremiumThreshold = ampPriceOne.mul(premiumThreshold).div(100);
            if (_ampPrice >= _ampPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _ampPrice.sub(ampPriceOne).mul(premiumPercent).div(10000);
                _rate = ampPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = ampPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _amp,
        address _lyte,
        address _current,
        address _ampOracle,
        address _loop,
        uint _startTime
    ) public notInitialized {
        amp = _amp;
        lyte = _lyte;
        current = _current;
        ampOracle = _ampOracle;
        loop = _loop;
        startTime = _startTime;

        ampPriceOne = 10**18;
        ampPriceCeiling = ampPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [400, 300, 225, 150, 100, 75, 50, 40];        

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for loop
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn AMP and mint LYTE)
        maxDebtRatioPercent = 3500; // Upto 35% supply of LYTE to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 4;
        bootstrapSupplyExpansionPercent = 250;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(amp).balanceOf(address(this));

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

    function setAmpOracle(address _ampOracle) external onlyOperator {
        ampOracle = _ampOracle;
    }

    function setAmpPriceCeiling(uint256 _ampPriceCeiling) external onlyOperator {
        require(_ampPriceCeiling >= ampPriceOne && _ampPriceCeiling <= ampPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        ampPriceCeiling = _ampPriceCeiling;
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

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
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
        require(_premiumThreshold >= ampPriceCeiling, "_premiumThreshold exceeds ampPriceCeiling");
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

    function _updateAmpPrice() internal {
        try IOracle(ampOracle).update() {} catch {}
    }

    function getAmpCirculatingSupply() public view returns (uint256) {
        IERC20 ampErc20 = IERC20(amp);
        uint256 totalSupply = ampErc20.totalSupply();
        uint256 balanceExcluded = 0;
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _ampAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_ampAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 ampPrice = getAmpPrice();
        require(ampPrice == targetPrice, "Treasury: AMP price moved");
        require(
            ampPrice < ampPriceOne, // price < $1
            "Treasury: ampPrice not eligible for bond purchase"
        );

        require(_ampAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _ampAmount.mul(_rate).div(1e18);
        uint256 ampSupply = getAmpCirculatingSupply();
        uint256 newBondSupply = IERC20(lyte).totalSupply().add(_bondAmount);
        require(newBondSupply <= ampSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(amp).burnFrom(msg.sender, _ampAmount);
        IBasisAsset(lyte).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_ampAmount);
        _updateAmpPrice();

        emit BoughtBonds(msg.sender, _ampAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 ampPrice = getAmpPrice();
        require(ampPrice == targetPrice, "Treasury: AMP price moved");
        require(
            ampPrice > ampPriceCeiling, // price > $1.01
            "Treasury: ampPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _ampAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(amp).balanceOf(address(this)) >= _ampAmount, "Treasury: treasury has no more lyteget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _ampAmount));

        IBasisAsset(lyte).burnFrom(msg.sender, _bondAmount);
        IERC20(amp).safeTransfer(msg.sender, _ampAmount);

        _updateAmpPrice();

        emit RedeemedBonds(msg.sender, _ampAmount, _bondAmount);
    }

    function _sendToMasonry(uint256 _amount) internal {
        IBasisAsset(amp).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(amp).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(block.timestamp, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(amp).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(block.timestamp, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(amp).safeApprove(loop, 0);
        IERC20(amp).safeApprove(loop, _amount);
        IMasonry(loop).allocateSeigniorage(_amount);
        emit LoopFunded(block.timestamp, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _ampSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_ampSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateAmpPrice();
        previousEpochAmpPrice = getAmpPrice();
        uint256 ampSupply = getAmpCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToMasonry(ampSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochAmpPrice > ampPriceCeiling) {
                // Expansion ($AMP Price > 1 $FUSE): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(lyte).totalSupply();
                uint256 _percentage = previousEpochAmpPrice.sub(ampPriceOne);
                uint256 _savedForBond;
                uint256 _savedForLoop;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(ampSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForLoop = ampSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = ampSupply.mul(_percentage).div(1e18);
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
                    IBasisAsset(amp).mint(address(this), _savedForBond);
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
        require(address(_token) != address(amp), "amp");
        require(address(_token) != address(current), "current");
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
