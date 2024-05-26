// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { LibCommon } from "./lib/LibCommon.sol";

/// @title A ERC20 implementation with extended reflection token functionalities
/// @notice Implements ERC20 standards with additional token holder reward feature
abstract contract ReflectiveERC20 is ERC20 {
  // Constants
  uint256 private constant BPS_DIVISOR = 10_000;

  mapping(address => uint256) private _rOwned;
  mapping(address => uint256) private _tOwned;

  uint256 private constant UINT_256_MAX = type(uint256).max;
  uint256 private _rTotal;
  uint256 private _tFeeTotal;

  uint256 public tFeeBPS;
  bool private immutable isReflective;

  // custom errors
  error TokenIsNotReflective();
  error TotalReflectionTooSmall();
  error ZeroTransferError();
  error MintingNotEnabled();
  error BurningNotEnabled();
  error ERC20InsufficientBalance(
    address recipient,
    uint256 fromBalance,
    uint256 balance
  );

  /// @notice Gets total supply of the erc20 token
  /// @return Token total supply
  function _tTotal() public view virtual returns (uint256) {
    return totalSupply();
  }

  /// @notice Constructor to initialize the ReflectionErc20 token
  /// @param name_ Name of the token
  /// @param symbol_ Symbol of the token
  /// @param tokenOwner Address of the token owner
  /// @param totalSupply_ Initial total supply
  /// @param decimalsToSet Token decimal number
  /// @param decimalsToSet Token reward (reflection fee BPS value
  constructor(
    string memory name_,
    string memory symbol_,
    address tokenOwner,
    uint256 totalSupply_,
    uint8 decimalsToSet,
    uint256 tFeeBPS_,
    bool isReflective_
  ) ERC20(name_, symbol_) {
    if (totalSupply_ != 0) {
      super._mint(tokenOwner, totalSupply_ * 10 ** decimalsToSet);
      _rTotal = (UINT_256_MAX - (UINT_256_MAX % totalSupply_));
    }

    _rOwned[tokenOwner] = _rTotal;
    tFeeBPS = tFeeBPS_;
    isReflective = isReflective_;
  }

  // public standard ERC20 functions

  /// @notice Gets balance the erc20 token for specific address
  /// @param account Account address
  /// @return Token balance
  function balanceOf(address account) public view override returns (uint256) {
    if (isReflective) {
      return tokenFromReflection(_rOwned[account]);
    } else {
      return super.balanceOf(account);
    }
  }

  /// @notice Transfers allowed tokens between accounts
  /// @param from From account
  /// @param to To account
  /// @param value Transferred value
  /// @return Success
  function transferFrom(
    address from,
    address to,
    uint256 value
  ) public virtual override returns (bool) {
    address spender = super._msgSender();
    _spendAllowance(from, spender, value);
    _transfer(from, to, value);
    return true;
  }

  /// @notice Transfers tokens from owner to an account
  /// @param to To account
  /// @param value Transferred value
  /// @return Success
  function transfer(
    address to,
    uint256 value
  ) public virtual override returns (bool) {
    address owner = super._msgSender();
    _transfer(owner, to, value);
    return true;
  }

  // override internal OZ standard ERC20 functions related to transfer

  /// @notice Transfers tokens from owner to an account
  /// @param to To account
  /// @param amount Transferred amount
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    if (isReflective) {
      LibCommon.validateAddress(from);
      LibCommon.validateAddress(to);
      if (amount == 0) {
        revert ZeroTransferError();
      }

      _transferReflected(from, to, amount);
    } else {
      super._transfer(from, to, amount);
    }
  }

  // override incompatible internal OZ standard ERC20 functions to disable them in case
  // reflection mechanism is used, ie. tFeeBPS is non zero

  /// @notice Creates specified amount of tokens, it either uses standard OZ ERC function
  ///         or in case of reflection logic, it is prohibited
  /// @param account Account new tokens will be transferred to
  /// @param value Created tokens value
  function _mint(address account, uint256 value) internal override {
    if (isReflective) {
      revert MintingNotEnabled();
    } else {
      super._mint(account, value);
    }
  }

  /// @notice Destroys specified amount of tokens, it either uses standard OZ ERC function
  ///         or in case of reflection logic, it is prohibited
  /// @param account Account in which tokens will be destroyed
  /// @param value Destroyed tokens value
  function _burn(address account, uint256 value) internal override {
    if (isReflective) {
      revert BurningNotEnabled();
    } else {
      super._burn(account, value);
    }
  }

  // public reflection custom functions

  /// @notice Sets a new reflection fee
  /// @dev Should only be called by the contract owner
  /// @param _tFeeBPS The reflection fee in basis points
  function _setReflectionFee(uint256 _tFeeBPS) internal {
    if (!isReflective) {
      revert TokenIsNotReflective();
    }

    tFeeBPS = _tFeeBPS;
  }

  /// @notice Calculates number of tokens from reflection amount
  /// @param rAmount Reflection token amount
  function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
    if (rAmount > _rTotal) {
      revert TotalReflectionTooSmall();
    }

    uint256 currentRate = _getRate();
    return rAmount / currentRate;
  }

  // private reflection custom functions

  /// @notice Transfers reflected amount of tokens
  /// @param sender Account to transfer tokens from
  /// @param recipient Account to transfer tokens to
  /// @param tAmount Total token amount
  function _transferReflected(
    address sender,
    address recipient,
    uint256 tAmount
  ) private {
    uint256 tFee = calculateFee(tAmount);
    uint256 tTransferAmount = tAmount - tFee;
    (uint256 rAmount, uint256 rFee, uint256 rTransferAmount) = _getRValues(
      tAmount,
      tFee,
      tTransferAmount
    );

    if (tAmount != 0) {
      _rUpdate(sender, recipient, rAmount, rTransferAmount);

      _reflectFee(rFee, tFee);
      emit Transfer(sender, recipient, tAmount);
    }
  }

  /// @notice Deducts reflection fee from reflection supply to 'distribute' token holder rewards
  /// @param rFee Reflection fee
  /// @param tFee Token fee
  function _reflectFee(uint256 rFee, uint256 tFee) private {
    _rTotal = _rTotal - rFee;
    _tFeeTotal = _tFeeTotal + tFee;
  }

  /// @notice Calculates the reflection fee from token amount
  /// @param _amount Amount of tokens to calculate fee from
  function calculateFee(uint256 _amount) private view returns (uint256) {
    return (_amount * tFeeBPS) / BPS_DIVISOR;
  }

  /// @notice Transfers Tax related tokens and do not apply reflection fees
  /// @param from Account to transfer tokens from
  /// @param to Account to transfer tokens to
  /// @param tAmount Total token amount
  function _transferNonReflectedTax(
    address from,
    address to,
    uint256 tAmount
  ) internal {
    if (isReflective) {
      if (tAmount != 0) {
        uint256 currentRate = _getRate();
        uint256 rAmount = tAmount * currentRate;

        _rUpdate(from, to, rAmount, rAmount);
        emit Transfer(from, to, tAmount);
      }
    } else {
      super._transfer(from, to, tAmount);
    }
  }

  /// @notice Get reflective values from token values
  /// @param tAmount Token amount
  /// @param tFee Token fee
  /// @param tTransferAmount Transfer amount
  function _getRValues(
    uint256 tAmount,
    uint256 tFee,
    uint256 tTransferAmount
  ) private view returns (uint256, uint256, uint256) {
    uint256 currentRate = _getRate();
    uint256 rAmount = tAmount * currentRate;
    uint256 rFee = tFee * currentRate;
    uint256 rTransferAmount = tTransferAmount * currentRate;

    return (rAmount, rFee, rTransferAmount);
  }

  /// @notice Get ratio rate between reflective and token supply
  /// @return Reflective rate
  function _getRate() private view returns (uint256) {
    (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
    return rSupply / tSupply;
  }

  /// @notice Get reflective and token supplies
  /// @return Reflective and token supplies
  function _getCurrentSupply() private view returns (uint256, uint256) {
    return (_rTotal, _tTotal());
  }

  /// @notice Update reflective balances to reflect amount transfer,
  ///         with or without a fee applied. If a fee is applied,
  ///         the amount deducted from the sender will differ
  ///         from amount added to the recipient
  /// @param sender Sender address
  /// @param recipient Recipient address
  /// @param rSubAmount Amount to be deducted from sender
  /// @param rTransferAmount Amount to be added to recipient
  function _rUpdate(
    address sender,
    address recipient,
    uint256 rSubAmount,
    uint256 rTransferAmount
  ) private {
    uint256 fromBalance = _rOwned[sender];
    if (fromBalance < rSubAmount) {
      revert ERC20InsufficientBalance(recipient, fromBalance, rSubAmount);
    }
    _rOwned[sender] = _rOwned[sender] - rSubAmount;
    _rOwned[recipient] = _rOwned[recipient] + rTransferAmount;
  }
}
