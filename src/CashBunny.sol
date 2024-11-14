// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./abstract/Ownable.sol";
import "./libraries/BEP20.sol";
import "./libraries/Address.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IFactory.sol";

contract CashBunny is BEP20, Ownable {
    using Address for address payable;

    IRouter private router;
    address private pair;
    bool private _interlock = false;
    address[5] public internalWallets;
    address public raffleContract;
    bool initialized = false;
    uint256 defaultTax;

    /// @dev Modifier to prevent reentrancy attacks during swapping operations.
    modifier lockTheSwap {
        /// @notice Ensures that swap functions can only be called once at a time to prevent reentrancy.
        if (!_interlock) {
            _interlock = true;
            _;
            _interlock = false;
        }
    }

    /// @param _pancakeswap_router Address of the PancakeSwap router
    /// @param _initialSupply Initial token supply to mint
    /// @param _internalWallets Array of addresses that will receive fees
    /// @dev Constructor for initializing the contract with necessary parameters, creating token, and setting up pair on PancakeSwap.
    constructor(
        address _pancakeswap_router, 
        uint256 _initialSupply,
        address[5] memory _internalWallets
    ) BEP20("CashBunny", "BUNNY") Ownable() {
        _tokengeneration(msg.sender, _initialSupply * 10**decimals());
        IRouter _router = IRouter(_pancakeswap_router);
        address _pair = IFactory(_router.factory()).createPair(address(this), _router.WETH());
        internalWallets = _internalWallets;
        raffleContract = address(0);
        router = _router;
        pair = _pair;
    }

    /// @dev Approves `spender` to transfer up to `amount` tokens from the caller's account.
    /// @param spender The address which will transfer the tokens.
    /// @param amount The amount of tokens to approve for transfer.
    /// @return bool True if the operation was successful.
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /// @dev Transfers `amount` tokens from `sender` to `recipient` using the allowance mechanism.
    /// @param sender Address from which tokens are transferred.
    /// @param recipient Address to which tokens are transferred.
    /// @param amount The amount of tokens to transfer.
    /// @return bool True if the operation was successful.
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "BEP20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    /// @dev Increases the allowance of another address to spend tokens on behalf of the caller.
    /// @param spender The address which will spend the tokens.
    /// @param addedValue The amount by which the allowance will be increased.
    /// @return bool True if the operation was successful.
    function increaseAllowance(address spender, uint256 addedValue) public override returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /// @dev Decreases the allowance of another address to spend tokens on behalf of the caller.
    /// @param spender The address which will spend the tokens.
    /// @param subtractedValue The amount by which the allowance will be decreased.
    /// @return bool True if the operation was successful.
    function decreaseAllowance(address spender, uint256 subtractedValue) public override returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "BEP20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }

    /// @dev Transfers `amount` tokens from the caller to `recipient`.
    /// @param recipient The address to transfer to.
    /// @param amount The amount of tokens to transfer.
    /// @return bool True if the transfer was successful.
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    /// @dev Internal transfer function handling token transfers with fee application.
    /// @param sender The address transferring tokens.
    /// @param recipient The address receiving tokens.
    /// @param amount The amount of tokens to transfer.
    function _transfer(address sender, address recipient, uint256 amount) internal override  {
        require(amount > 0, "Transfer amount must be greater than zero");

        uint256 feeswap;
        uint256 fee;

        if (_interlock) {
            fee = 0; // No fee if already in the swap lock
        } else {
            fee = (amount * feeswap) / 100;
        }
        
        //send to recipient
        super._transfer(sender, recipient, amount - fee);
        if (fee > 0) {
            //send the fee to the internal wallets including the raffle contract
            if (defaultTax > 0) {
                uint256 feeAmount = (amount * defaultTax) / 100;
                _swapFeesAndTransfer(feeAmount);
            }
        }
    }

    /// @dev Internal function to swap token fees for ETH and distribute the ETH to internal wallets or raffle contract.
    /// @param _feeAmount The amount of tokens to be swapped for ETH to cover fees.
    function _swapFeesAndTransfer(uint256 _feeAmount) internal lockTheSwap {
        uint256 individualShare = 0;  
        uint256 initialBalance = address(this).balance;
        swapTokensForETH(_feeAmount);
        uint256 deltaBalance = address(this).balance - initialBalance;
        
        if (raffleContract == address(0)) {
            /// Distribute ETH only among internal wallets when no raffle contract is set.
            individualShare = deltaBalance / internalWallets.length;
            for (uint256 i=0; i<internalWallets.length; i++) {
                payable(internalWallets[i]).sendValue(individualShare);
            }
        } else {
            /// Distribute ETH between internal wallets and the raffle contract.
            individualShare = deltaBalance / (internalWallets.length + 1);
            for (uint256 i=0; i<internalWallets.length; i++) {
                payable(internalWallets[i]).sendValue(individualShare);
            }
            payable(raffleContract).sendValue(individualShare);
        }
    }

    /// @dev Converts an amount of tokens to ETH via the PancakeSwap router.
    /// @param tokenAmount The amount of tokens to swap for ETH.
    /// @notice This function is private and can only be called within this contract.
    function swapTokensForETH(uint256 tokenAmount) private {
        // Define the path for swapping tokens. Here, we're swapping from this token to WETH.
        address[] memory path = new address[](2);
        path[0] = address(this); // This contract's token address
        path[1] = router.WETH(); // Wrapped Ether address from the router

        // Approve the router to spend the specified amount of tokens from this contract.
        _approve(address(this), address(router), tokenAmount);

        // Execute the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, // Amount of tokens we're selling
            0,           // Minimum amount of ETH to receive. Set to 0 for no slippage protection
            path,        // The path of tokens to swap through
            address(this), // Address to send the ETH to (this contract)
            block.timestamp // Deadline for the transaction to complete
        );
    }

    /// @dev Burns a specific amount of tokens from an account, reducing the total supply.
    /// @param account The account whose tokens will be burnt.
    /// @param amount The amount of tokens to burn.
    /// @return bool True if the burn was successful.
    function burnFrom(address account, uint256 amount) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[account][_msgSender()];
        require(currentAllowance >= amount, "BEP20: burn amount exceeds allowance");

        // Decrease allowance and burn tokens
        _approve(account, _msgSender(), currentAllowance - amount);
        _burn(account, amount);

        return true;
    }

    /// @dev Sets the address of the raffle contract, initializes the contract, and renounces ownership.
    /// @param _raffleContract The address of the raffle contract.
    function setRaffleContract(address _raffleContract) external onlyOwner {
        require(_raffleContract != address(0), "invalid address");
        raffleContract = _raffleContract;
        initialized = true;
        renounceOwnership(); // Once set, ownership is renounced to prevent further changes
    }

    /// @dev Fallback function to receive ETH.
    receive() external payable {}
}