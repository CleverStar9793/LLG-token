// SPDX-License-Identifier: MIT

pragma solidity 0.8.5;

import "./LLGBase.sol";

// Implements rewards & burns
contract LLG is LLGBase {

	// REWARD CYCLE
	uint256 private _rewardCyclePeriod = 43200; // The duration of the reward cycle (e.g. can claim rewards once 12 hours)
	uint256 private _rewardCycleExtensionThreshold; // If someone sends or receives more than a % of their balance in a transaction, their reward cycle date will increase accordingly
	mapping(address => uint256) private _nextAvailableClaimDate; // The next available reward claim date for each address

	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	uint256 private _totalBNBClaimed; // The total number of BNB claimed by all addresses
	uint256 private _totalBNBAsLLGClaimed; // The total number of BNB that was converted to LLG and claimed by all addresses
	mapping(address => uint256) private _bnbRewardClaimed; // The amount of BNB claimed by each address
	mapping(address => uint256) private _bnbAsLLGClaimed; // The amount of BNB converted to LLG and claimed by each address
	mapping(address => bool) private _addressesExcludedFromRewards; // The list of addresses excluded from rewards
	mapping(address => mapping(address => bool)) private _rewardClaimApprovals; //Used to allow an address to claim rewards on behalf of someone else
	mapping(address => uint256) private _claimRewardAsTokensPercentage; //Allows users to optionally use a % of the reward pool to buy LLG automatically
	uint256 private _minRewardBalance; //The minimum balance required to be eligible for rewards
	uint256 private _maxClaimAllowed = 100 ether; // Can only claim up to 100 bnb at a time.
	uint256 private _globalRewardDampeningPercentage = 3; // Rewards are reduced by 3% at the start to fill the main BNB pool faster and ensure consistency in rewards
	uint256 private _mainBnbPoolSize = 5000 ether; // Any excess BNB after the main pool will be used as reserves to ensure consistency in rewards
	bool private _rewardAsTokensEnabled; //If enabled, the contract will give out tokens instead of BNB according to the preference of each user
	uint256 private _gradualBurnMagnitude; // The contract can optionally burn tokens (By buying them from reward pool).  This is the magnitude of the burn (1 = 0.01%).
	uint256 private _gradualBurnTimespan = 1 days; //Burn every 1 day by default
	uint256 private _lastBurnDate; //The last burn date

	// AUTO-CLAIM
	bool private _autoClaimEnabled;
	uint256 private _maxGasForAutoClaim = 600000; // The maximum gas to consume for processing the auto-claim queue
	address[] _rewardClaimQueue;
	mapping(address => uint) _rewardClaimQueueIndices;
	uint256 private _rewardClaimQueueIndex;
	mapping(address => bool) _addressesInRewardClaimQueue; // Mapping between addresses and false/true depending on whether they are queued up for auto-claim or not
	bool private _reimburseAfterLLGClaimFailure; // If true, and LLG reward claim portion fails, the portion will be given as BNB instead
	bool private _processingQueue; //Flag that indicates whether the queue is currently being processed and sending out rewards
	mapping(address => bool) private _whitelistedExternalProcessors; //Contains a list of addresses that are whitelisted for low-gas queue processing 
	uint256 private _sendWeiGasLimit;
	bool private _excludeNonHumansFromRewards = true;

	event RewardClaimed(address recipient, uint256 amountBnb, uint256 amountTokens, uint256 nextAvailableClaimDate); 
	event Burned(uint256 bnbAmount);

	constructor (address routerAddress, address pinkAntiBot_) LLGBase(routerAddress, pinkAntiBot_) {
		// Exclude addresses from rewards
		_addressesExcludedFromRewards[BURN_WALLET] = true;
		_addressesExcludedFromRewards[owner()] = true;
		_addressesExcludedFromRewards[address(this)] = true;
		_addressesExcludedFromRewards[address(0)] = true;

		// If someone sends or receives more than 15% of their balance in a transaction, their reward cycle date will increase accordingly
		setRewardCycleExtensionThreshold(15);
	}


	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function onActivated() internal override {
		super.onActivated();

		setRewardAsTokensEnabled(true);
		setAutoClaimEnabled(true);
		setReimburseAfterLLGClaimFailure(true);
		setMinRewardBalance(50000 * 10**decimals());  //At least 50000 tokens are required to be eligible for rewards
		setGradualBurnMagnitude(1); //Buy tokens using 0.01% of reward pool and burn them
		_lastBurnDate = block.timestamp;
	}

	function onBeforeTransfer(address sender, address recipient, uint256 amount) internal override {
        super.onBeforeTransfer(sender, recipient, amount);

		if (!isMarketTransfer(sender, recipient)) {
			return;
		}

        // Extend the reward cycle according to the amount transferred.  This is done so that users do not abuse the cycle (buy before it ends & sell after they claim the reward)
		_nextAvailableClaimDate[recipient] += calculateRewardCycleExtension(balanceOf(recipient), amount);
		_nextAvailableClaimDate[sender] += calculateRewardCycleExtension(balanceOf(sender), amount);
		
		bool isSelling = isPancakeSwapPair(recipient);
		if (!isSelling) {
			// Wait for a dip, stellar diamond hands
			return;
		}

		// Process gradual burns
		bool burnTriggered = processGradualBurn();

		// Do not burn & process queue in the same transaction
		if (!burnTriggered && isAutoClaimEnabled()) {
			// Trigger auto-claim
			try this.processRewardClaimQueue(_maxGasForAutoClaim) { } catch { }
		}
    }


	function onTransfer(address sender, address recipient, uint256 amount) internal override {
        super.onTransfer(sender, recipient, amount);

		if (!isMarketTransfer(sender, recipient)) {
			return;
		}

		// Update auto-claim queue after balances have been updated
		updateAutoClaimQueue(sender);
		updateAutoClaimQueue(recipient);
    }
	
	
	function processGradualBurn() private returns(bool) {
		if (!shouldBurn()) {
			return false;
		}

		uint256 burnAmount = address(this).balance * _gradualBurnMagnitude / 10000;
		doBuyAndBurn(burnAmount);
		return true;
	}


	function updateAutoClaimQueue(address user) private {
		bool isQueued = _addressesInRewardClaimQueue[user];

		if (!isIncludedInRewards(user)) {
			if (isQueued) {
				// Need to dequeue
				uint index = _rewardClaimQueueIndices[user];
				address lastUser = _rewardClaimQueue[_rewardClaimQueue.length - 1];

				// Move the last one to this index, and pop it
				_rewardClaimQueueIndices[lastUser] = index;
				_rewardClaimQueue[index] = lastUser;
				_rewardClaimQueue.pop();

				// Clean-up
				delete _rewardClaimQueueIndices[user];
				delete _addressesInRewardClaimQueue[user];
			}
		} else {
			if (!isQueued) {
				// Need to enqueue
				_rewardClaimQueue.push(user);
				_rewardClaimQueueIndices[user] = _rewardClaimQueue.length - 1;
				_addressesInRewardClaimQueue[user] = true;
			}
		}
	}


    function claimReward() isHuman nonReentrant external {
		claimReward(msg.sender);
	}


	function claimReward(address user) public {
		require(msg.sender == user || isClaimApproved(user, msg.sender), "You are not allowed to claim rewards on behalf of this user");
		require(isRewardReady(user), "Claim date for this address has not passed yet");
		require(isIncludedInRewards(user), "Address is excluded from rewards, make sure there is enough LLG balance");

		bool success = doClaimReward(user);
		require(success, "Reward claim failed");
	}


	function doClaimReward(address user) private returns (bool) {
		// Update the next claim date & the total amount claimed
		_nextAvailableClaimDate[user] = block.timestamp + rewardCyclePeriod();

		(uint256 claimBnb, uint256 claimBnbAsTokens, uint256 taxFee) = calculateClaimRewards(user);
        
        claimBnb = claimBnb - claimBnb * taxFee / 100;
        claimBnbAsTokens = claimBnbAsTokens - claimBnbAsTokens * taxFee / 100;
        
		bool tokenClaimSuccess = true;
        // Claim LLG tokens
		if (!claimLLG(user, claimBnbAsTokens)) {
			// If token claim fails for any reason, award whole portion as BNB
			if (_reimburseAfterLLGClaimFailure) {
				claimBnb += claimBnbAsTokens;
			} else {
				tokenClaimSuccess = false;
			}

			claimBnbAsTokens = 0;
		}

		// Claim BNB
		bool bnbClaimSuccess = claimBNB(user, claimBnb);

		// Fire the event in case something was claimed
		if (tokenClaimSuccess || bnbClaimSuccess) {
			emit RewardClaimed(user, claimBnb, claimBnbAsTokens, _nextAvailableClaimDate[user]);
		}
		
		return bnbClaimSuccess && tokenClaimSuccess;
	}


	function claimBNB(address user, uint256 bnbAmount) private returns (bool) {
		if (bnbAmount == 0) {
			return true;
		}

		// Send the reward to the caller
		if (_sendWeiGasLimit > 0) {
			(bool sent,) = user.call{value : bnbAmount, gas: _sendWeiGasLimit}("");
			if (!sent) {
				return false;
			}
		} else {
			(bool sent,) = user.call{value : bnbAmount}("");
			if (!sent) {
				return false;
			}
		}

	
		_bnbRewardClaimed[user] += bnbAmount;
		_totalBNBClaimed += bnbAmount;
		return true;
	}


	function claimLLG(address user, uint256 bnbAmount) private returns (bool) {
		if (bnbAmount == 0) {
			return true;
		}

		bool success = swapBNBForTokens(bnbAmount, user);
		if (!success) {
			return false;
		}

		_bnbAsLLGClaimed[user] += bnbAmount;
		_totalBNBAsLLGClaimed += bnbAmount;
		return true;
	}


	// Processes users in the claim queue and sends out rewards when applicable. The amount of users processed depends on the gas provided, up to 1 cycle through the whole queue. 
	// Note: Any external processor can process the claim queue (e.g. even if auto claim is disabled from the contract, an external contract/user/service can process the queue for it 
	// and pay the gas cost). "gas" parameter is the maximum amount of gas allowed to be consumed
	function processRewardClaimQueue(uint256 gas) public {
		require(gas > 0, "Gas limit is required");

		uint256 queueLength = _rewardClaimQueue.length;

		if (queueLength == 0) {
			return;
		}

		uint256 gasUsed = 0;
		uint256 gasLeft = gasleft();
		uint256 iteration = 0;
		_processingQueue = true;

		// Keep claiming rewards from the list until we either consume all available gas or we finish one cycle
		while (gasUsed < gas && iteration < queueLength) {
			if (_rewardClaimQueueIndex >= queueLength) {
				_rewardClaimQueueIndex = 0;
			}

			address user = _rewardClaimQueue[_rewardClaimQueueIndex];
			if (isRewardReady(user) && isIncludedInRewards(user)) {
				doClaimReward(user);
			}

			uint256 newGasLeft = gasleft();
			
			if (gasLeft > newGasLeft) {
				uint256 consumedGas = gasLeft - newGasLeft;
				gasUsed += consumedGas;
				gasLeft = newGasLeft;
			}

			iteration++;
			_rewardClaimQueueIndex++;
		}

		_processingQueue = false;
	}

	// Allows a whitelisted external contract/user/service to process the queue and have a portion of the gas costs refunded.
	// This can be used to help with transaction fees and payout response time when/if the queue grows too big for the contract.
	// "gas" parameter is the maximum amount of gas allowed to be used.
	function processRewardClaimQueueAndRefundGas(uint256 gas) external {
		require(_whitelistedExternalProcessors[msg.sender], "Not whitelisted - use processRewardClaimQueue instead");

		uint256 startGas = gasleft();
		processRewardClaimQueue(gas);
		uint256 gasUsed = startGas - gasleft();

		payable(msg.sender).transfer(gasUsed);
	}


	function isRewardReady(address user) public view returns(bool) {
		return _nextAvailableClaimDate[user] <= block.timestamp;
	}


	function isIncludedInRewards(address user) public view returns(bool) {
		if (_excludeNonHumansFromRewards) {
			if (isContract(user)) {
				return false;
			}
		}

		return balanceOf(user) >= _minRewardBalance && !_addressesExcludedFromRewards[user];
	}


	// This function calculates how much (and if) the reward cycle of an address should increase based on its current balance and the amount transferred in a transaction
	function calculateRewardCycleExtension(uint256 balance, uint256 amount) public view returns (uint256) {
		uint256 basePeriod = rewardCyclePeriod();

		if (balance == 0) {
			// Receiving $LLG on a zero balance address:
			// This means that either the address has never received tokens before (So its current reward date is 0) in which case we need to set its initial value
			// Or the address has transferred all of its tokens in the past and has now received some again, in which case we will set the reward date to a date very far in the future
			return block.timestamp + basePeriod;
		}

		uint256 rate = amount * 100 / balance;

		// Depending on the % of $LLG tokens transferred, relative to the balance, we might need to extend the period
		if (rate >= _rewardCycleExtensionThreshold) {

			// If new balance is X percent higher, then we will extend the reward date by X percent
			uint256 extension = basePeriod * rate / 100;

			// Cap to the base period
			if (extension >= basePeriod) {
				extension = basePeriod;
			}

			return extension;
		}

		return 0;
	}


	function calculateClaimRewards(address ofAddress) public view returns (uint256, uint256, uint256) {
		uint256 reward = calculateBNBReward(ofAddress);
        uint256 taxFee = 0;
        if (reward >= 35 * 10**16) {
            taxFee = 20;
        } else if(reward >= 20 * 10**16) {
            taxFee = 10;
        }
		uint256 claimBnbAsTokens = 0;
		if (_rewardAsTokensEnabled) {
			uint256 percentage = _claimRewardAsTokensPercentage[ofAddress];
			claimBnbAsTokens = reward * percentage / 100;
		} 

		uint256 claimBnb = reward - claimBnbAsTokens;

		return (claimBnb, claimBnbAsTokens, taxFee);
	}


	function calculateBNBReward(address ofAddress) public view returns (uint256) {
		uint256 holdersAmount = totalAmountOfTokensHeld();

		uint256 balance = balanceOf(ofAddress);
		uint256 bnbPool =  address(this).balance * (100 - _globalRewardDampeningPercentage) / 100;

		// Limit to main pool size.  The rest of the pool is used as a reserve to improve consistency
		if (bnbPool > _mainBnbPoolSize) {
			bnbPool = _mainBnbPoolSize;
		}

		// If an address is holding X percent of the supply, then it can claim up to X percent of the reward pool
		uint256 reward = bnbPool * balance / holdersAmount;

		if (reward > _maxClaimAllowed) {
			reward = _maxClaimAllowed;
		}

		return reward;
	}


	function onPancakeSwapRouterUpdated() internal override { 
		_addressesExcludedFromRewards[pancakeSwapRouterAddress()] = true;
		_addressesExcludedFromRewards[pancakeSwapPairAddress()] = true;
	}


	function isMarketTransfer(address sender, address recipient) internal override view returns(bool) {
		// Not a market transfer when we are burning or sending out rewards
		return super.isMarketTransfer(sender, recipient) && !isBurnTransfer(sender, recipient) && !_processingQueue;
	}


	function isBurnTransfer(address sender, address recipient) private view returns (bool) {
		return isPancakeSwapPair(sender) && recipient == BURN_WALLET;
	}


	function shouldBurn() public view returns(bool) {
		return _gradualBurnMagnitude > 0 && block.timestamp - _lastBurnDate > _gradualBurnTimespan;
	}


	// Up to 1% manual buyback & burn
	function buyAndBurn(uint256 bnbAmount) external onlyOwner {
		require(bnbAmount <= address(this).balance / 100, "Manual burn amount is too high!");
		require(bnbAmount > 0, "Amount must be greater than zero");

		doBuyAndBurn(bnbAmount);
	}


	function doBuyAndBurn(uint256 bnbAmount) private {
		if (bnbAmount > address(this).balance) {
			bnbAmount = address(this).balance;
		}

		if (bnbAmount == 0) {
			return;
		}

		if (swapBNBForTokens(bnbAmount, BURN_WALLET)) {
			emit Burned(bnbAmount);
		}

		_lastBurnDate = block.timestamp;
	}


	function isContract(address account) public view returns (bool) {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
	}


	function totalAmountOfTokensHeld() public view returns (uint256) {
		return totalSupply() - balanceOf(address(0)) - balanceOf(BURN_WALLET) - balanceOf(pancakeSwapPairAddress());
	}


    function bnbRewardClaimed(address byAddress) public view returns (uint256) {
		return _bnbRewardClaimed[byAddress];
	}


    function bnbRewardClaimedAsLLG(address byAddress) public view returns (uint256) {
		return _bnbAsLLGClaimed[byAddress];
	}


    function totalBNBClaimed() public view returns (uint256) {
		return _totalBNBClaimed;
	}


    function totalBNBClaimedAsLLG() public view returns (uint256) {
		return _totalBNBAsLLGClaimed;
	}


    function rewardCyclePeriod() public view returns (uint256) {
		return _rewardCyclePeriod;
	}


	function setRewardCyclePeriod(uint256 period) public onlyOwner {
		require(period >= 3600 && period <= 86400, "RewardCycle must be updated to between 1 and 24 hours");
		_rewardCyclePeriod = period;
	}


	function setRewardCycleExtensionThreshold(uint256 threshold) public onlyOwner {
		_rewardCycleExtensionThreshold = threshold;
	}


	function nextAvailableClaimDate(address ofAddress) public view returns (uint256) {
		return _nextAvailableClaimDate[ofAddress];
	}


	function maxClaimAllowed() public view returns (uint256) {
		return _maxClaimAllowed;
	}


	function setMaxClaimAllowed(uint256 value) public onlyOwner {
		require(value > 0, "Value must be greater than zero");
		_maxClaimAllowed = value;
	}


	function minRewardBalance() public view returns (uint256) {
		return _minRewardBalance;
	}


	function setMinRewardBalance(uint256 balance) public onlyOwner {
		_minRewardBalance = balance;
	}


	function maxGasForAutoClaim() public view returns (uint256) {
		return _maxGasForAutoClaim;
	}


	function setMaxGasForAutoClaim(uint256 gas) public onlyOwner {
		_maxGasForAutoClaim = gas;
	}


	function isAutoClaimEnabled() public view returns (bool) {
		return _autoClaimEnabled;
	}


	function setAutoClaimEnabled(bool isEnabled) public onlyOwner {
		_autoClaimEnabled = isEnabled;
	}


	function isExcludedFromRewards(address addr) public view returns (bool) {
		return _addressesExcludedFromRewards[addr];
	}


	// Will be used to exclude unicrypt fees/token vesting addresses from rewards
	function setExcludedFromRewards(address addr, bool isExcluded) public onlyOwner {
		_addressesExcludedFromRewards[addr] = isExcluded;
		updateAutoClaimQueue(addr);
	}


	function globalRewardDampeningPercentage() public view returns(uint256) {
		return _globalRewardDampeningPercentage;
	}


	function setGlobalRewardDampeningPercentage(uint256 value) public onlyOwner {
		require(value <= 90, "Cannot be greater than 90%");
		_globalRewardDampeningPercentage = value;
	}


	function approveClaim(address byAddress, bool isApproved) public {
		require(byAddress != address(0), "Invalid address");
		_rewardClaimApprovals[msg.sender][byAddress] = isApproved;
	}


	function isClaimApproved(address ofAddress, address byAddress) public view returns(bool) {
		return _rewardClaimApprovals[ofAddress][byAddress];
	}


	function isRewardAsTokensEnabled() public view returns(bool) {
		return _rewardAsTokensEnabled;
	}


	function setRewardAsTokensEnabled(bool isEnabled) public onlyOwner {
		_rewardAsTokensEnabled = isEnabled;
	}


	function gradualBurnMagnitude() public view returns (uint256) {
		return _gradualBurnMagnitude;
	}


	function setGradualBurnMagnitude(uint256 magnitude) public onlyOwner {
		require(magnitude <= 100, "Must be equal or less to 100");
		_gradualBurnMagnitude = magnitude;
	}


	function gradualBurnTimespan() public view returns (uint256) {
		return _gradualBurnTimespan;
	}


	function setGradualBurnTimespan(uint256 timespan) public onlyOwner {
		require(timespan >= 5 minutes, "Cannot be less than 5 minutes");
		_gradualBurnTimespan = timespan;
	}


	function claimRewardAsTokensPercentage(address ofAddress) public view returns(uint256) {
		return _claimRewardAsTokensPercentage[ofAddress];
	}


	function setClaimRewardAsTokensPercentage(uint256 percentage) public {
		require(percentage <= 100, "Cannot exceed 100%");
		_claimRewardAsTokensPercentage[msg.sender] = percentage;
	}


	function mainBnbPoolSize() public view returns (uint256) {
		return _mainBnbPoolSize;
	}


	function setMainBnbPoolSize(uint256 size) public onlyOwner {
		require(size >= 10 ether, "Size is too small");
		_mainBnbPoolSize = size;
	}


	function isInRewardClaimQueue(address addr) public view returns(bool) {
		return _addressesInRewardClaimQueue[addr];
	}

	
	function reimburseAfterLLGClaimFailure() public view returns(bool) {
		return _reimburseAfterLLGClaimFailure;
	}


	function setReimburseAfterLLGClaimFailure(bool value) public onlyOwner {
		_reimburseAfterLLGClaimFailure = value;
	}


	function lastBurnDate() public view returns(uint256) {
		return _lastBurnDate;
	}


	function rewardClaimQueueLength() public view returns(uint256) {
		return _rewardClaimQueue.length;
	}


	function rewardClaimQueueIndex() public view returns(uint256) {
		return _rewardClaimQueueIndex;
	}


	function isWhitelistedExternalProcessor(address addr) public view returns(bool) {
		return _whitelistedExternalProcessors[addr];
	}


	function setWhitelistedExternalProcessor(address addr, bool isWhitelisted) public onlyOwner {
		 require(addr != address(0), "Invalid address");
		_whitelistedExternalProcessors[addr] = isWhitelisted;
	}

	function setSendWeiGasLimit(uint256 amount) public onlyOwner {
		_sendWeiGasLimit = amount;
	}

	function setExcludeNonHumansFromRewards(bool exclude) public onlyOwner {
		_excludeNonHumansFromRewards = exclude;
	}
}