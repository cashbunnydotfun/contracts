//SPDX-License-Identifier: MIT
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

    address public marketingWallet = 0x000000000000000000000000000000000000dEaD;
    address public constant deadWallet = 0x000000000000000000000000000000000000dEaD;

    struct Taxes {
        uint256 marketing;
        uint256 liquidity;
        uint256 burn;
    }

    Taxes public buytaxes = Taxes(1, 0, 1);
    Taxes public sellTaxes = Taxes(2, 2, 0); 

    modifier lockTheSwap() {
        if (!_interlock) {
            _interlock = true;
            _;
            _interlock = false;
        }
    }

    constructor() BEP20("CashBunny", "BUNNY") {
        _tokengeneration(msg.sender, 15000000000 * 10**decimals());
        IRouter _router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address _pair = IFactory(_router.factory()).createPair(address(this), _router.WETH());
        router = _router;
        pair = _pair;
    }
    
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

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

    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "BEP20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > 0, "Transfer amount must be greater than zero");

        uint256 feeswap;
        uint256 feesum;
        uint256 fee;
        Taxes memory currentTaxes;

        if (_interlock)
            fee = 0;

        else if (recipient == pair) {
            feeswap = sellTaxes.liquidity + sellTaxes.marketing;
            feesum = feeswap + sellTaxes.burn;
            currentTaxes = sellTaxes;
        } else if (recipient != pair) {
            feeswap = buytaxes.liquidity + buytaxes.marketing;
            feesum = feeswap + buytaxes.burn;
            currentTaxes = buytaxes;
        }

        fee = (amount * feesum) / 100;

        //rest to recipient
        super._transfer(sender, recipient, amount - fee);
        if (fee > 0) {
            //send the fee to the marketing Wallet
            if (feeswap > 0) {
                uint256 feeAmount = (amount * feeswap) / 100 ;
                super._transfer(sender, marketingWallet, feeAmount);
            }
             //send burn fee
            if (currentTaxes.burn > 0) {
                uint256 burnAmount = (currentTaxes.burn * amount) / 100;
                uint256 individualShare = burnAmount / 4;
                for (uint256 i=0; i<4; i++) {
                    super._transfer(sender, marketingWallet, individualShare);
                }
            }

        }
    }

    function swapTokensForETH(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }


    function rescueBNB(uint256 weiAmount) external {
        payable(owner()).transfer(weiAmount);
    }

    function rescueBSC20(address tokenAdd, uint256 amount) external onlyOwner {
       require(tokenAdd != address(this), "Owner can't claim contract's balance of its own tokens");
        IBEP20(tokenAdd).transfer(owner(), amount);
    }

    // fallbacks
    receive() external payable {}
}