// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategyInitializable,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/Uniswap/IUniswapRouter.sol";
import "../interfaces/Uniswap/IUniswapFactory.sol";

import {VaultAPI} from "../interfaces/VaultAPI.sol";

contract AssetBurnStrategy is BaseStrategyInitializable {
    using SafeERC20 for ERC20;
    using Address for address;
    using SafeMath for uint256;

    VaultAPI public underlyingVault;
    address public asset;
    address public weth;
    address public uniswapRouterV2;
    address public uniswapFactory;

    address[] internal _path;

    uint256 constant MAX_BPS = 10000;
    uint256 public burningProfitRatio;

    uint256 public targetSupply;

    uint256 public maxLossUnderlyingVault;

    modifier onlyGovernanceOrManagement() {
        require(
            msg.sender == governance() || msg.sender == vault.management(),
            "!authorized"
        );
        _;
    }

    constructor(
        address _vault,
        address _underlyingVault,
        address _asset,
        address _weth,
        address _uniswapRouterV2,
        address _uniswapFactory
    ) public BaseStrategyInitializable(_vault) {
        _init(
            _underlyingVault,
            _asset,
            _weth,
            _uniswapRouterV2,
            _uniswapFactory
        );
    }

    function init(
        address _vault,
        address _onBehalfOf,
        address _underlyingVault,
        address _asset,
        address _weth,
        address _uniswapRouterV2,
        address _uniswapFactory
    ) external {
        super._initialize(_vault, _onBehalfOf, _onBehalfOf, _onBehalfOf);

        _init(
            _underlyingVault,
            _asset,
            _weth,
            _uniswapRouterV2,
            _uniswapFactory
        );
    }

    function _init(
        address _underlyingVault,
        address _asset,
        address _weth,
        address _uniswapRouterV2,
        address _uniswapFactory
    ) internal {
        require(
            address(want) == VaultAPI(_underlyingVault).token(),
            "Vault want is different from the underlying vault token"
        );

        underlyingVault = VaultAPI(_underlyingVault);
        asset = _asset;

        weth = _weth;
        uniswapRouterV2 = _uniswapRouterV2;
        uniswapFactory = _uniswapFactory;

        if (
            address(want) == weth ||
            address(want) == 0x6B175474E89094C44Da98b954EedeAC495271d0F
        ) {
            _path = new address[](2);
            _path[0] = address(want);
            _path[1] = asset;
        } else {
            _path = new address[](3);
            _path[0] = address(want);
            _path[1] = weth;
            _path[2] = asset;
        }
        ERC20(address(want)).safeApprove(_uniswapRouterV2, type(uint256).max);

        // initial burning profit ratio 50%
        burningProfitRatio = 5000;

        // initial target supply equal to constructor initial supply
        targetSupply = ERC20(asset).totalSupply();

        // max loss during withdrawal from underlying vault
        maxLossUnderlyingVault = 1;

        want.safeApprove(_underlyingVault, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return
            string(
                abi.encodePacked("StrategyUbi", ERC20(address(want)).symbol())
            );
    }

    /**
     * @notice
     *  The amount (priced in want) of the total assets managed by this strategy should not count
     *  towards Yearn's TVL calculations.
     * @dev
     *  You can override this field to set it to a non-zero value if some of the assets of this
     *  Strategy is somehow delegated inside another part of of Yearn's ecosystem e.g. another Vault.
     *  Note that this value must be strictly less than or equal to the amount provided by
     *  `estimatedTotalAssets()` below, as the TVL calc will be total assets minus delegated assets.
     *  Also note that this value is used to determine the total assets under management by this
     *  strategy, for the purposes of computing the management fee in `Vault`
     * @return
     *  The amount of assets this strategy manages that should not be included in Yearn's Total Value
     *  Locked (TVL) calculation across it's ecosystem.
     */
    function delegatedAssets() external view override returns (uint256) {
        StrategyParams memory params = vault.strategies(address(this));
        return Math.min(params.totalDebt, _balanceOnUnderlyingVault());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return _balanceOfWant().add(_balanceOnUnderlyingVault());
    }

    function _balanceOfWant() internal view returns (uint256) {
        return ERC20(address(want)).balanceOf(address(this));
    }

    function _balanceOnUnderlyingVault() internal view returns (uint256) {
        return
            underlyingVault
                .balanceOf(address(this))
                .mul(underlyingVault.pricePerShare())
                .div(10**underlyingVault.decimals());
    }

    function ethToWant(uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(want);
        uint256[] memory amounts =
            IUniswapRouter(uniswapRouterV2).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 currentValue = estimatedTotalAssets();
        uint256 wantBalance = _balanceOfWant();

        // Calculate total profit w/o farming
        if (debt < currentValue) {
            _profit = currentValue.sub(debt);
        } else {
            _loss = debt.sub(currentValue);
        }

        // To withdraw = profit from lending + _debtOutstanding
        uint256 toFree = _debtOutstanding.add(_profit);

        // In the case want is not enough, divest from idle
        if (toFree > wantBalance) {
            // Divest only the missing part = toFree-wantBalance
            toFree = toFree.sub(wantBalance);
            (uint256 _liquidatedAmount, ) = liquidatePosition(toFree);

            // loss in the case freedAmount less to be freed
            uint256 withdrawalLoss =
                _liquidatedAmount < toFree ? toFree.sub(_liquidatedAmount) : 0;

            // profit recalc
            if (withdrawalLoss < _profit) {
                _profit = _profit.sub(withdrawalLoss);
            } else {
                _loss = _loss.add(withdrawalLoss.sub(_profit));
                _profit = 0;
            }
        }

        if (_profit > 0) {
            ERC20Burnable assetToken = ERC20Burnable(asset);
            uint256 currentTotalSupply = assetToken.totalSupply();

            uint256 targetAssetToBurn =
                currentTotalSupply > targetSupply
                    ? currentTotalSupply.sub(targetSupply)
                    : 0; // supply <= targetSupply nothing to burn

            if (targetAssetToBurn > 0) {
                // Check we have sufficient liquidity
                IUniswapV2Factory factory = IUniswapV2Factory(uniswapFactory);
                address pair =
                    factory.getPair(
                        _path[_path.length - 2],
                        _path[_path.length - 1]
                    );

                require(pair != address(0), "Pair must exist to swap");

                // Buy at most to empty the pool
                uint256 pairAssetBalance = assetToken.balanceOf(pair);
                targetAssetToBurn = Math.min(
                    pairAssetBalance > 0
                        ? pairAssetBalance.mul(50).div(100)
                        : 0,
                    targetAssetToBurn
                );
            }

            if (targetAssetToBurn > 0) {
                uint256 profitToConvert =
                    _profit.mul(burningProfitRatio).div(MAX_BPS);

                IUniswapRouter router = IUniswapRouter(uniswapRouterV2);

                uint256 expectedProfitToUse =
                    (router.getAmountsIn(targetAssetToBurn, _path))[0];

                // In the case profitToConvert > expected to use for burning target asset use the latter
                // On the contrary use profitToConvert
                uint256 exchangedAmount =
                    (
                        router.swapExactTokensForTokens(
                            Math.min(profitToConvert, expectedProfitToUse),
                            1,
                            _path,
                            address(this),
                            now.add(1800)
                        )
                    )[0];

                // TOBE CHECKED leverage uniswap returns want amount
                _profit = _profit.sub(exchangedAmount);

                // burn
                assetToken.burn(assetToken.balanceOf(address(this)));
            }
        }

        // Recalculate profit
        wantBalance = want.balanceOf(address(this));

        if (wantBalance < _profit) {
            _profit = wantBalance;
            _debtPayment = 0;
        } else if (wantBalance < _debtOutstanding.add(_profit)) {
            _debtPayment = wantBalance.sub(_profit);
        } else {
            _debtPayment = _debtOutstanding;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        uint256 balanceOfWant = _balanceOfWant();
        if (balanceOfWant > _debtOutstanding) {
            underlyingVault.deposit(balanceOfWant.sub(_debtOutstanding));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`

        uint256 balanceOfWant = _balanceOfWant();

        if (balanceOfWant < _amountNeeded) {
            uint256 amountToRedeem = _amountNeeded.sub(balanceOfWant);

            uint256 valueToRedeemApprox =
                amountToRedeem.mul(10**underlyingVault.decimals()).div(
                    underlyingVault.pricePerShare()
                );
            uint256 valueToRedeem =
                Math.min(
                    valueToRedeemApprox,
                    underlyingVault.balanceOf(address(this))
                );

            underlyingVault.withdraw(
                valueToRedeem,
                address(this),
                maxLossUnderlyingVault
            );
        }

        // _liquidatedAmount min(_amountNeeded, balanceOfWant), otw vault accounting breaks
        balanceOfWant = _balanceOfWant();

        if (balanceOfWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = balanceOfWant;
            _loss = _amountNeeded.sub(balanceOfWant);
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function harvestTrigger(uint256 callCost)
        public
        view
        override
        returns (bool)
    {
        return super.harvestTrigger(ethToWant(callCost));
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one

        underlyingVault.withdraw(
            underlyingVault.balanceOf(address(this)),
            address(this),
            maxLossUnderlyingVault
        );

        ERC20 assetToken = ERC20(asset);
        assetToken.safeTransfer(
            _newStrategy,
            assetToken.balanceOf(address(this))
        );
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](1);

        protected[0] = asset;

        return protected;
    }

    function setBurningProfitRatio(uint256 _burningProfitRatio)
        external
        onlyGovernanceOrManagement
    {
        require(
            _burningProfitRatio <= MAX_BPS,
            "Burning profit ratio should be less than 10000"
        );

        burningProfitRatio = _burningProfitRatio;
    }

    function setTargetSupply(uint256 _targetSuplly)
        external
        onlyGovernanceOrManagement
    {
        targetSupply = _targetSuplly;
    }

    function setMaxLossUnderlyingVault(uint256 _maxLossUnderlyingVault)
        external
        onlyGovernanceOrManagement
    {
        maxLossUnderlyingVault = _maxLossUnderlyingVault;
    }

    function clone(
        address _vault,
        address _onBehalfOf,
        address _underlyingVault,
        address _asset,
        address _weth,
        address _uniswapRouterV2,
        address _uniswapFactory
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        AssetBurnStrategy(newStrategy).init(
            _vault,
            _onBehalfOf,
            _underlyingVault,
            _asset,
            _weth,
            _uniswapRouterV2,
            _uniswapFactory
        );

        emit Cloned(newStrategy);
    }
}
