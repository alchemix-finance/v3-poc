// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantsTest.t.sol";

contract InvariantBaseTest is InvariantsTest {
    address internal immutable USER;

    uint256 internal immutable MAX_TEST_VALUE = 1e28;

    constructor() {
        USER = makeAddr("User");
    }

    function setUp() public virtual override {
        selectors.push(this.depositCollateral.selector);
        selectors.push(this.withdrawCollateral.selector);
        selectors.push(this.borrowCollateral.selector);
        selectors.push(this.repayDebt.selector);
        selectors.push(this.repayDebtViaBurn.selector);
        selectors.push(this.transmuterStake.selector);
        selectors.push(this.transmuterClaim.selector);
        selectors.push(this.mine.selector);

        super.setUp();
    }

    function _targetSenders() internal virtual override {
        _targetSender(makeAddr("Sender1"));
        _targetSender(makeAddr("Sender2"));
        _targetSender(makeAddr("Sender3"));
        _targetSender(makeAddr("Sender4"));
        _targetSender(makeAddr("Sender5"));
        _targetSender(makeAddr("Sender6"));
        _targetSender(makeAddr("Sender7"));
        _targetSender(makeAddr("Sender8"));
    }

    function _deposit(uint256 tokenId, uint256 amount, address onBehalf) internal logCall(onBehalf, "deposit") {
        fakeUnderlyingToken.mint(onBehalf, amount);
        vm.startPrank(onBehalf);
        fakeUnderlyingToken.approve(address(fakeYieldToken), amount);
        fakeYieldToken.mint(amount, onBehalf);

        alchemist.deposit(amount, onBehalf, tokenId);
        vm.stopPrank();
    }

    function _borrow(uint256 tokenId, uint256 amount, address onBehalf) internal logCall(onBehalf, "borrow") {
        vm.prank(onBehalf);
        alchemist.mint(tokenId, amount, onBehalf);
    }

    function _withdraw(uint256 tokenId, uint256 amount, address onBehalf) internal logCall(onBehalf, "withdraw") {
        vm.prank(onBehalf);
        alchemist.withdraw(amount, onBehalf, tokenId);
    }

    function _repay(uint256 tokenId, uint256 amount, address onBehalf) internal logCall(onBehalf, "repay") {
        vm.roll(block.number + 1);
        fakeUnderlyingToken.mint(onBehalf, amount);
        vm.startPrank(onBehalf);
        fakeUnderlyingToken.approve(address(fakeYieldToken), amount);
        fakeYieldToken.mint(amount, onBehalf);

        alchemist.repay(amount, tokenId);
        vm.stopPrank();
    }

    function _burn(uint256 tokenId, uint256 amount, address onBehalf) internal logCall(onBehalf, "burn") {
        vm.prank(onBehalf);
        alchemist.burn(amount, tokenId);
    }

    function _stake(uint256 amount, address onBehalf) internal logCall(onBehalf, "stake") {
        vm.startPrank(onBehalf);
        alToken.mint(onBehalf, amount);
        alToken.approve(address(transmuterLogic), amount);
        transmuterLogic.createRedemption(amount);
        vm.stopPrank();
    }

    function _claim(uint256 tokenId, address onBehalf) internal logCall(onBehalf, "claim") {
        vm.roll(block.number + 10);
        vm.startPrank(onBehalf);
        transmuterLogic.claimRedemption(tokenId);
        vm.stopPrank();
    }

    /* HANDLERS */

    function depositCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomDepositor(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        amount = bound(amount, 0, MAX_TEST_VALUE);
        if (amount == 0) return;

        uint256 tokenId;

        try AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT)) {
            tokenId = AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT));
        } catch {
            tokenId = 0;
        }

        _deposit(tokenId, amount, onBehalf);
    }

    function withdrawCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomWithdrawer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT));

        (uint256 collat, uint256 debt,) = alchemist.getCDP(tokenId);
        uint256 debtToCollateral = alchemist.convertDebtTokensToYield(debt);
        uint256 maxWithdraw = (collat * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()) > debtToCollateral
            ? (collat * FIXED_POINT_SCALAR / alchemist.minimumCollateralization()) - debtToCollateral
            : 0;

        amount = bound(amount, 0, maxWithdraw);
        if (amount == 0) return;

        _withdraw(tokenId, amount, onBehalf);
    }

    function borrowCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomMinter(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT));

        amount = bound(amount, 0, alchemist.getMaxBorrowable(tokenId));
        if (amount == 0) return;

        _borrow(tokenId, amount, onBehalf);
    }

    function repayDebt(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomRepayer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT));
        (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        amount = bound(amount, 0, debt);
        if (amount == 0) return;


        _repay(tokenId, amount, onBehalf);
    }

    function repayDebtViaBurn(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomBurner(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        // Roll before we check CDP so new earmark does not accumulate and cause illegal state after checking account
        vm.roll(block.number + 1);

        uint256 tokenId = AlchemistNFTHelper.getFirstTokenId(onBehalf, address(alchemistNFT));

        (, uint256 debt, uint256 earmarked) = alchemist.getCDP(tokenId);

        uint256 burnable = (debt - earmarked) > (alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked()) 
        ? (alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked()) 
        : (debt - earmarked);

        amount = bound(amount, 0, burnable);
        if (amount == 0) return;

        _burn(tokenId, amount, onBehalf);
    }

    function transmuterStake(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomNonZero(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 maxStakeable = alchemist.totalSyntheticsIssued() - transmuterLogic.totalLocked();

        amount = bound(amount, 0, maxStakeable);
        if (amount == 0) return;

        _stake(amount, onBehalf);
    }

    function transmuterClaim(uint256 onBehalfSeed) external {
        address onBehalf = _randomClaimer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        _claim(ITransmuter(address(transmuterLogic)).tokenOfOwnerByIndex(onBehalf, 0), onBehalf);
    }
}
