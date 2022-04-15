// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./owner/Operator.sol";

contract Ampere is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 50,000 Amp
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 35000 ether;
    uint256 public constant COMMUNITY_FUND_POOL_ALLOCATION = 5000 ether;
    uint256 public constant DEV_FUND_POOL_ALLOCATION = 4900 ether;
    uint256 public constant DAO_ALLOCATION = 5000 ether;

    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public communityFundRewardRate;
    uint256 public devFundRewardRate;
    uint256 public daoRewardRate;

    address public communityFund;
    address public devFund;
    address public daoFund;

    uint256 public communityFundLastClaimed;
    uint256 public devFundLastClaimed;
    uint256 public daoFundLastClaimed;

    bool public rewardPoolDistributed = false;

    uint256 public taxRate = 100;
    address public taxCollectorAddress;
    mapping(address => bool) public excludedAddresses;
    address public taxOffice;

    bool public openTrading = false;
    mapping(address => bool) public whitelistAddresses;

    modifier onlyTaxOffice() {
        require(taxOffice == msg.sender, "Caller is not the tax office");
        _;
    }

    modifier onlyOperatorOrTaxOffice() {
        require(isOperator() || taxOffice == msg.sender, "Caller is not the operator or the tax office");
        _;
    }

    constructor(uint256 _startTime, address _communityFund, address _devFund, address _daoFund) public ERC20("Ampere", "AMP") {
        _mint(msg.sender, 100 ether); // mint 100 AMP for initial pools deployment

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        communityFundLastClaimed = startTime;
        devFundLastClaimed = startTime;
        daoFundLastClaimed = startTime;

        communityFundRewardRate = COMMUNITY_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        daoRewardRate = DIGITS_DAO_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_communityFund != address(0), "Address cannot be 0");
        communityFund = _communityFund;

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;

        excludeAddress(msg.sender);
        whitelistAddresses[msg.sender] = true;
    }

    function setTreasuryFund(address _communityFund) external {
        require(msg.sender == communityFund, "!dev");
        require(_communityFund != address(0), "zero");
        communityFund = _communityFund;
    }

    function setDevFund(address _devFund) external {
        require(msg.sender == devFund, "!dev");
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedTreasuryFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (communityFundLastClaimed >= _now) return 0;
        _pending = _now.sub(communityFundLastClaimed).mul(communityFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (devFundLastClaimed >= _now) return 0;
        _pending = _now.sub(devFundLastClaimed).mul(devFundRewardRate);
    }

    function unclaimedDaoFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (daoFundLastClaimed >= _now) return 0;
        _pending = _now.sub(daoFundLastClaimed).mul(daoRewardRate);
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedTreasuryFund();
        if (_pending > 0 && communityFund != address(0)) {
            _mint(communityFund, _pending);
            communityFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
            devFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedDaoFund();
        if (_pending > 0 && daoFund != address(0)) {
            _mint(daoFund, _pending);
            daoFundLastClaimed = block.timestamp;
        }
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        if (taxRate == 0 || excludedAddresses[sender]) {
            _transfer(sender, recipient, amount);
        } else {
            _transferWithTax(sender, recipient, amount);
        }

        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function _transferWithTax(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        uint256 taxAmount = amount.mul(taxRate).div(10000);
        uint256 amountAfterTax = amount.sub(taxAmount);

        _transfer(sender, taxCollectorAddress, taxAmount);

        // Transfer amount after tax to recipient
        _transfer(sender, recipient, amountAfterTax);

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        require(openTrading || whitelistAddresses[sender], "Trade not opened");
        super._transfer(sender, recipient, amount);
    }

    function setTaxRate(uint256 _taxRate) public onlyOperatorOrTaxOffice {
        require(_taxRate <= 100, "tax equal or bigger to 1%");
        taxRate = _taxRate;
    }

    function excludeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(!excludedAddresses[_address], "address can't be excluded");
        excludedAddresses[_address] = true;
        return true;
    }

    function includeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(excludedAddresses[_address], "address can't be included");
        excludedAddresses[_address] = false;
        return true;
    }

    function setTaxOffice(address _taxOffice) public onlyOperatorOrTaxOffice {
        require(_taxOffice != address(0), "tax office address cannot be 0 address");
        taxOffice = _taxOffice;
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyTaxOffice {
        require(_taxCollectorAddress != address(0), "tax collector address must be non-zero address");
        taxCollectorAddress = _taxCollectorAddress;
    }

    function OpenTrade() external onlyOperatorOrTaxOffice {
        require(!openTrading, "Trade already opened.");
        openTrading = true;
    }

    function includeToWhitelist(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(!whitelistAddresses[_address], "address can't be included");
        whitelistAddresses[_address] = true;
        return true;
    }

    function excludeFromWhitlist(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(whitelistAddresses[_address], "address can't be excluded");
        whitelistAddresses[_address] = false;
        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
