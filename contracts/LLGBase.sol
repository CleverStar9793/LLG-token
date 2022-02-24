pragma solidity 0.8.5;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ReentrancyGuard.sol";
import "./IERC20Metadata.sol";
import "./IPancakeRouter02.sol";
import "./IPancakeFactory.sol";
import "./IPinkAntiBot.sol";




abstract contract LLGBase is Context, IERC20Metadata, Ownable, ReentrancyGuard {
	// MAIN TOKEN PROPERTIES
	string private constant NAME = "MMG";
	string private constant SYMBOL = "MMG";
	uint8 private constant DECIMALS = 9;
	uint8 private _liquidityFee; //% of each transaction that will be added as liquidity
	uint8 private _rewardFee; //% of each transaction that will be used for BNB reward pool
    uint8 private _marketingFee; //% of each transaction that will be used for marketing
    uint8 private _devFee; //% of each transaction that will be used for development
	uint8 private _poolFee; //The total fee to be taken and added to the pool, this includes all fees

	uint256 private constant _totalTokens = 100000000 * 10**DECIMALS;	//total supply
	mapping (address => uint256) private _balances; //The balance of each address.  This is before applying distribution rate.  To get the actual balance, see balanceOf() method
	mapping (address => mapping (address => uint256)) private _allowances;

	// FEES & REWARDS
	bool private _isSwapEnabled; // True if the contract should swap for liquidity & reward pool, false otherwise
	bool private _isFeeEnabled; // True if fees should be applied on transactions, false otherwise
	bool private _isTokenHoldEnabled;
	address public constant BURN_WALLET = 0x000000000000000000000000000000000000dEaD; //The address that keeps track of all tokens burned
	uint256 private _tokenSwapThreshold = _totalTokens / 10000; //There should be at least 0.0001% of the total supply in the contract before triggering a swap
	uint256 private _totalFeesPooled; // The total fees pooled (in number of tokens)
	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	mapping (address => bool) private _addressesExcludedFromFees; // The list of addresses that do not pay a fee for transactions
	mapping (address => bool) private _addressesExcludedFromHold; // The list of addresses that hold token amount

	// TRANSACTION LIMIT
	uint256 private _transactionLimit = _totalTokens; // The amount of tokens that can be sold at once
	bool private _isBuyingAllowed; // This is used to make sure that the contract is activated before anyone makes a purchase on PCS.  The contract will be activated once liquidity is added.

	// HOLD LIMIT
	uint256 private _maxHoldAmount;

    // marketing and dev address
    address private _marketingWallet = 0xB0F8dD8469dcB6E1Eb50a818FE206f0D1299936e;
    address private _devAddress = 0xF565aaf0b8EB813a1c8C956D2C59F1ce27FD2366;
    
	// PANCAKESWAP INTERFACES (For swaps)
	address private _pancakeSwapRouterAddress;
	IPancakeRouter02 private _pancakeswapV2Router;
	address private _pancakeswapV2Pair;
	address private _autoLiquidityWallet;
	
	IPinkAntiBot public pinkAntiBot;
	bool public antiBotEnabled;

	// EVENTS
	event Swapped(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiqudity, uint256 bnbIntoLiquidity);
	event AutoBurned(uint256 bnbAmount);

	//Router address will be: 0x029290c564Ef921c56a784AA16C97E930dAF7372 or for testnet: 0x029290c564Ef921c56a784AA16C97E930dAF7372
	//PinkAntiBot address will be: 0x029290c564Ef921c56a784AA16C97E930dAF7372 or for testnet: 0x029290c564Ef921c56a784AA16C97E930dAF7372
	constructor (address routerAddress, address pinkAntiBot_) {
		_balances[_msgSender()] = totalSupply();
		
		// Exclude contract from fees
		_addressesExcludedFromFees[address(this)] = true;
		_addressesExcludedFromFees[_marketingWallet] = true;
		_addressesExcludedFromFees[_devAddress] = true;
		_addressesExcludedFromFees[_msgSender()] = true;

		_addressesExcludedFromHold[address(this)] = true;
		_addressesExcludedFromHold[_marketingWallet] = true;
		_addressesExcludedFromHold[_devAddress] = true;
		_addressesExcludedFromHold[_msgSender()] = true;

		// Initialize PancakeSwap V2 router and LLG <-> BNB pair.
		setPancakeSwapRouter(routerAddress);

		_maxHoldAmount = 1200000 * 10**DECIMALS;

		// 3% liquidity fee, 10% reward fee, 3% marketing fee, 4% dev fee
		setFees(3, 0, 3, 4);

		emit Transfer(address(0), _msgSender(), totalSupply());
		
		// Create an instance of the PinkAntiBot variable from the provided address
        pinkAntiBot = IPinkAntiBot(pinkAntiBot_);
        // Register the deployer to be the token owner with PinkAntiBot. You can
        // later change the token owner in the PinkAntiBot contract
        pinkAntiBot.setTokenOwner(msg.sender);
        antiBotEnabled = true;
	}
	
    // Use this function to control whether to use PinkAntiBot or not instead
    // of managing this in the PinkAntiBot contract
    function setEnableAntiBot(bool _enable) external onlyOwner {
        antiBotEnabled = _enable;
    }


	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function activate() public onlyOwner {
		setSwapEnabled(true);
		setFeeEnabled(true);
		setTokenHoldEnabled(true);
		setAutoLiquidityWallet(owner());
		setTransactionLimit(600000);
		activateBuying();
		onActivated();
	}


	function onActivated() internal virtual { }


	function balanceOf(address account) public view override returns (uint256) {
		return _balances[account];
	}
	

	function transfer(address recipient, uint256 amount) public override returns (bool) {
		doTransfer(_msgSender(), recipient, amount);
		return true;
	}
	

	function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		doTransfer(sender, recipient, amount);
		doApprove(sender, _msgSender(), _allowances[sender][_msgSender()] - amount); // Will fail when there is not enough allowance
		return true;
	}
	

	function approve(address spender, uint256 amount) public override returns (bool) {
		doApprove(_msgSender(), spender, amount);
		return true;
	}
	
	
	function doTransfer(address sender, address recipient, uint256 amount) internal virtual {
		require(sender != address(0), "Transfer from the zero address is not allowed");
		require(recipient != address(0), "Transfer to the zero address is not allowed");
		if(antiBotEnabled) {
		    pinkAntiBot.onPreTransferCheck(sender, recipient, amount);
		}
		require(amount > 0, "Transfer amount must be greater than zero");
		require(!isPancakeSwapPair(sender) || _isBuyingAllowed, "Buying is not allowed before contract activation");
		
		// Ensure that amount is within the limit in case we are selling
		if (isTransferLimited(sender, recipient)) {
			require(amount <= _transactionLimit, "Transfer amount exceeds the maximum allowed");
		}

		// Perform a swap if needed.  A swap in the context of this contract is the process of swapping the contract's token balance with BNBs in order to provide liquidity and increase the reward pool
		executeSwapIfNeeded(sender, recipient);

		onBeforeTransfer(sender, recipient, amount);

		// Calculate fee rate
		uint256 feeRate = calculateFeeRate(sender, recipient);
		
		uint256 feeAmount = amount * feeRate / 100;
		uint256 transferAmount = amount - feeAmount;

		bool applyTokenHold = _isTokenHoldEnabled && !isPancakeSwapPair(recipient) && !_addressesExcludedFromHold[recipient];

		if (applyTokenHold) {
			require(_balances[recipient] + transferAmount < _maxHoldAmount, "Cannot hold more than Maximum hold amount");
		}

		// Update balances
		updateBalances(sender, recipient, amount, feeAmount);

		// Update total fees, this is just a counter provided for visibility
		_totalFeesPooled += feeAmount;

		emit Transfer(sender, recipient, transferAmount); 

		onTransfer(sender, recipient, amount);
	}

	function onBeforeTransfer(address sender, address recipient, uint256 amount) internal virtual { }

	function onTransfer(address sender, address recipient, uint256 amount) internal virtual { }


	function updateBalances(address sender, address recipient, uint256 sentAmount, uint256 feeAmount) private {
		// Calculate amount to be received by recipient
		uint256 receivedAmount = sentAmount - feeAmount;

		// Update balances
		_balances[sender] -= sentAmount;
		_balances[recipient] += receivedAmount;
		
		// Add fees to contract
		_balances[address(this)] += feeAmount;
	}


	function doApprove(address owner, address spender, uint256 amount) private {
		require(owner != address(0), "Cannot approve from the zero address");
		require(spender != address(0), "Cannot approve to the zero address");

		_allowances[owner][spender] = amount;
		
		emit Approval(owner, spender, amount);
	}


	function calculateFeeRate(address sender, address recipient) private view returns(uint256) {
		bool applyFees = _isFeeEnabled && !_addressesExcludedFromFees[sender] && !_addressesExcludedFromFees[recipient];
		if (applyFees) {
			if (isPancakeSwapPair(recipient) || isPancakeSwapPair(sender)) {
				return _poolFee;
			}
		}

		return 0;
	}

	
	function executeSwapIfNeeded(address sender, address recipient) private {
		if (!isMarketTransfer(sender, recipient)) {
			return;
		}

		// Check if it's time to swap for liquidity & reward pool
		uint256 tokensAvailableForSwap = balanceOf(address(this));
		if (tokensAvailableForSwap >= _tokenSwapThreshold) {

			// Limit to threshold
			tokensAvailableForSwap = _tokenSwapThreshold;

			// Make sure that we are not stuck in a loop (Swap only once)
			bool isSelling = isPancakeSwapPair(recipient);
			if (isSelling) {
				executeSwap(tokensAvailableForSwap);
			}
		}
	}


	function executeSwap(uint256 amount) private {
		// Allow pancakeSwap to spend the tokens of the address
		doApprove(address(this), _pancakeSwapRouterAddress, amount);

		uint256 tokensReservedForLiquidity = amount * _liquidityFee / _poolFee;
		uint256 tokensReservedForMarketing = amount * _marketingFee / _poolFee;
		uint256 tokensReservedForDev = amount * _devFee / _poolFee;
		uint256 tokensReservedForReward = amount - tokensReservedForLiquidity - tokensReservedForMarketing - tokensReservedForDev;

		// For the liquidity portion, half of it will be swapped for BNB and the other half will be used to add the BNB into the liquidity
		uint256 tokensToSwapForLiquidity = tokensReservedForLiquidity / 2;
		uint256 tokensToAddAsLiquidity = tokensToSwapForLiquidity;

		uint256 tokensToSwap = tokensReservedForReward + tokensToSwapForLiquidity + tokensReservedForMarketing + tokensReservedForDev;
		uint256 bnbSwapped = swapTokensForBNB(tokensToSwap);
		
		// Calculate what portion of the swapped BNB is for liquidity and supply it using the other half of the token liquidity portion.  The remaining BNBs in the contract represent the reward pool
		uint256 bnbToBeAddedToLiquidity = bnbSwapped * tokensToSwapForLiquidity / tokensToSwap;
		(,uint bnbAddedToLiquidity,) = _pancakeswapV2Router.addLiquidityETH{value: bnbToBeAddedToLiquidity}(address(this), tokensToAddAsLiquidity, 0, 0, _autoLiquidityWallet, block.timestamp + 360);

		// Keep track of how many BNB were added to liquidity this way
		_totalBNBLiquidityAddedFromFees += bnbAddedToLiquidity;
		
		//send bnb to marketing wallet
		uint256 bnbToBeSendToMarketing = bnbSwapped * tokensReservedForMarketing / tokensToSwap;
		(bool sent, ) = _marketingWallet.call{value: bnbToBeSendToMarketing}("");
		require(sent, "Failed to send BNB to marketing wallet");
		
		//send bnb to dev wallet
		uint256 bnbToBeSendToDev = bnbSwapped * tokensReservedForDev / tokensToSwap;
		(sent, ) = _devAddress.call{value: bnbToBeSendToDev}("");
		require(sent, "Failed to send BNB to dev wallet");
		
		emit Swapped(tokensToSwap, bnbSwapped, tokensToAddAsLiquidity, bnbToBeAddedToLiquidity);
	}


	// This function swaps a {tokenAmount} of LLG tokens for BNB and returns the total amount of BNB received
	function swapTokensForBNB(uint256 tokenAmount) internal returns(uint256) {
		uint256 initialBalance = address(this).balance;
		
		// Generate pair for LLG -> WBNB
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = _pancakeswapV2Router.WETH();

		// Swap
		_pancakeswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp + 360);
		
		// Return the amount received
		return address(this).balance - initialBalance;
	}


	function swapBNBForTokens(uint256 bnbAmount, address to) internal returns(bool) { 
		// Generate pair for WBNB -> LLG
		address[] memory path = new address[](2);
		path[0] = _pancakeswapV2Router.WETH();
		path[1] = address(this);


		// Swap and send the tokens to the 'to' address
		try _pancakeswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbAmount }(0, path, to, block.timestamp + 360) { 
			return true;
		} 
		catch { 
			return false;
		}
	}

	
	// Returns true if the transfer between the two given addresses should be limited by the transaction limit and false otherwise
	function isTransferLimited(address sender, address recipient) private view returns(bool) {
		bool isSelling = isPancakeSwapPair(recipient);
		return isSelling && isMarketTransfer(sender, recipient);
	}


	function isSwapTransfer(address sender, address recipient) private view returns(bool) {
		bool isContractSelling = sender == address(this) && isPancakeSwapPair(recipient);
		return isContractSelling;
	}


	// Function that is used to determine whether a transfer occurred due to a user buying/selling/transfering and not due to the contract swapping tokens
	function isMarketTransfer(address sender, address recipient) internal virtual view returns(bool) {
		return !isSwapTransfer(sender, recipient);
	}


	// Returns how many more $LLG tokens are needed in the contract before triggering a swap
	function amountUntilSwap() public view returns (uint256) {
		uint256 balance = balanceOf(address(this));
		if (balance > _tokenSwapThreshold) {
			// Swap on next relevant transaction
			return 0;
		}

		return _tokenSwapThreshold - balance;
	}


	function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
		doApprove(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
		return true;
	}


	function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
		doApprove(_msgSender(), spender, _allowances[_msgSender()][spender] - subtractedValue);
		return true;
	}


	function setPancakeSwapRouter(address routerAddress) public onlyOwner {
		require(routerAddress != address(0), "Cannot use the zero address as router address");

		_pancakeSwapRouterAddress = routerAddress; 
		_pancakeswapV2Router = IPancakeRouter02(_pancakeSwapRouterAddress);
		_pancakeswapV2Pair = IPancakeFactory(_pancakeswapV2Router.factory()).createPair(address(this), _pancakeswapV2Router.WETH());

		onPancakeSwapRouterUpdated();
	}


	function onPancakeSwapRouterUpdated() internal virtual { }


	function isPancakeSwapPair(address addr) internal view returns(bool) {
		return _pancakeswapV2Pair == addr;
	}


	// This function can also be used in case the fees of the contract need to be adjusted later on as the volume grows
	function setFees(uint8 liquidityFee, uint8 rewardFee, uint8 marketingFee, uint8 devFee) public onlyOwner {
		require(liquidityFee >= 0 && liquidityFee <= 5, "Liquidity fee must be between 0% and 5%");
		require(rewardFee >= 0 && rewardFee <= 10, "Reward fee must be between 1% and 15%");
        require(marketingFee >= 0 && marketingFee <= 5, "Marketing fee must be between 0% and 5%");
        require(devFee >= 0 && devFee <= 5, "Dev fee must be between 1% and 5%");
		
		_liquidityFee = liquidityFee;
		_rewardFee = rewardFee;
        _marketingFee = marketingFee;
        _devFee = devFee;
		
		// Enforce invariant
		_poolFee = _rewardFee + _liquidityFee + _marketingFee + _devFee;
	}

	function setTransactionLimit(uint256 limit) public onlyOwner {
		_transactionLimit = limit;
	}

		
	function transactionLimit() public view returns (uint256) {
		return _transactionLimit;
	}
	
	function setHoldLimit(uint256 limit) public onlyOwner {
		_maxHoldAmount = limit;
	}

		
	function holdLimit() public view returns (uint256) {
		return _maxHoldAmount;
	}

	function setTokenSwapThreshold(uint256 threshold) public onlyOwner {
		require(threshold > 0, "Threshold must be greater than 0");
		_tokenSwapThreshold = threshold;
	}


	function tokenSwapThreshold() public view returns (uint256) {
		return _tokenSwapThreshold;
	}


	function name() public override pure returns (string memory) {
		return NAME;
	}


	function symbol() public override pure returns (string memory) {
		return SYMBOL;
	}


	function totalSupply() public override pure returns (uint256) {
		return _totalTokens;
	}
	

	function decimals() public override pure returns (uint8) {
		return DECIMALS;
	}
	

	function allowance(address user, address spender) public view override returns (uint256) {
		return _allowances[user][spender];
	}


	function pancakeSwapRouterAddress() public view returns (address) {
		return _pancakeSwapRouterAddress;
	}


	function pancakeSwapPairAddress() public view returns (address) {
		return _pancakeswapV2Pair;
	}


	function autoLiquidityWallet() public view returns (address) {
		return _autoLiquidityWallet;
	}


	function setAutoLiquidityWallet(address liquidityWallet) public onlyOwner {
		_autoLiquidityWallet = liquidityWallet;
	}
	
	
	function devmarketingWallet() public view returns (address) {
		return _marketingWallet;
	}


	function setMarketingWallet(address marketingWallet) public onlyOwner {
		_marketingWallet = marketingWallet;
	}


	function totalFeesPooled() public view returns (uint256) {
		return _totalFeesPooled;
	}

	
	function totalBNBLiquidityAddedFromFees() public view returns (uint256) {
		return _totalBNBLiquidityAddedFromFees;
	}


	function isSwapEnabled() public view returns (bool) {
		return _isSwapEnabled;
	}


	function setSwapEnabled(bool isEnabled) public onlyOwner {
		_isSwapEnabled = isEnabled;
	}


	function isFeeEnabled() public view returns (bool) {
		return _isFeeEnabled;
	}


	function setFeeEnabled(bool isEnabled) public onlyOwner {
		_isFeeEnabled = isEnabled;
	}

	function isTokenHoldEnabled() public view returns (bool) {
		return _isTokenHoldEnabled;
	}


	function setTokenHoldEnabled(bool isEnabled) public onlyOwner {
		_isTokenHoldEnabled = isEnabled;
	}


	function isExcludedFromFees(address addr) public view returns(bool) {
		return _addressesExcludedFromFees[addr];
	}


	function setExcludedFromFees(address addr, bool value) public onlyOwner {
		_addressesExcludedFromFees[addr] = value;
	}

	function isExcludedFromHold(address addr) public view returns(bool) {
		return _addressesExcludedFromHold[addr];
	}


	function setExcludedFromHold(address addr, bool value) public onlyOwner {
		_addressesExcludedFromHold[addr] = value;
	}


	function activateBuying() public onlyOwner {
		_isBuyingAllowed = true;
	}

	// Ensures that the contract is able to receive BNB
	receive() external payable {}
}