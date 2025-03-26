#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title PUSD manager
@license Apache 2.0
@author Volume.finance
"""

struct ExactInputParams:
    path: Bytes[204]
    recipient: address
    amountIn: uint256
    amountOutMinimum: uint256

interface ERC20:
    def decimals() -> uint8: view
    def balanceOf(_owner: address) -> uint256: view
    def approve(_spender: address, _value: uint256) -> bool: nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable

interface AAVEPoolV3:
    def supply(asset: address, amount: uint256, onBehalfOf: address, referralCode: uint16): nonpayable
    def withdraw(asset: address, amount: uint256, to: address) -> uint256: nonpayable

interface ChainlinkAggregator:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

interface SwapRouter02:
    def WETH9() -> address: pure
    def exactInput(params: ExactInputParams) -> uint256: payable

interface Weth:
    def deposit(): payable
    def withdraw(amount: uint256): nonpayable

interface Compass:
    def slc_switch() -> bool: view

DENOMINATOR: public(constant(uint256)) = 10 ** 18
ASSET: public(immutable(address))
Pool: public(immutable(address))
GOV: public(immutable(address))
ASSET_DECIMALS_NUMERATOR: public(immutable(uint256))
Aggregator: public(immutable(address))
Exponent: public(immutable(uint256))
ROUTER02: public(immutable(address))
WETH9: public(immutable(address))
compass_evm: public(address)
refund_wallet: public(address)
withdraw_nonces: public(HashMap[uint256, bool])
deposit_nonce: public(uint256)
paloma: public(bytes32)
total_supply: public(uint256)
redemption_fee: public(uint256)

event Deposited:
    sender: indexed(address)
    recipient: bytes32
    amount: uint256
    nonce: uint256

event Withdrawn:
    sender: bytes32
    recipient: indexed(address)
    amount: uint256
    withdraw_amount: uint256
    nonce: uint256

event UpdateCompass:
    old_compass: address
    new_compass: address

event UpdateRefundWallet:
    old_wallet: address
    new_wallet: address

event UpdateRedemptionFee:
    old_redemption_fee: uint256
    new_redemption_fee: uint256

event SetPaloma:
    paloma: bytes32

@deploy
def __init__(_compass_evm: address, _initial_asset: address, _pool: address, _aggregator: address, _exponent: uint256, _governance: address, _refund_wallet: address, _router02: address, _redepmtion_fee: uint256):
    self.compass_evm = _compass_evm
    ASSET = _initial_asset
    Pool = _pool
    GOV = _governance
    Aggregator = _aggregator
    Exponent = _exponent
    ROUTER02 = _router02
    WETH9 = staticcall SwapRouter02(_router02).WETH9()
    self.refund_wallet = _refund_wallet
    assert extcall ERC20(ASSET).approve(Pool, max_value(uint256), default_return_value=True), "Failed approve"
    assert _redepmtion_fee < DENOMINATOR, "Invalid redemption fee"
    self.redemption_fee = _redepmtion_fee
    _decimals: uint8 = staticcall ERC20(ASSET).decimals()
    ASSET_DECIMALS_NUMERATOR = 10 ** 6 * DENOMINATOR // 10 ** convert(_decimals, uint256)
    log UpdateCompass(empty(address), _compass_evm)
    log UpdateRefundWallet(empty(address), _refund_wallet)
    log UpdateRedemptionFee(0, _redepmtion_fee)

@internal
def _paloma_check():
    assert msg.sender == self.compass_evm, "Not compass"
    assert self.paloma == convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), bytes32), "Invalid paloma"

@internal
def _safe_approve(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).approve(_to, _value, default_return_value=True), "Failed approve"

@internal
def _safe_transfer(_token: address, _to: address, _value: uint256):
    if _value > 0:
        assert extcall ERC20(_token).transfer(_to, _value, default_return_value=True), "Failed transfer"

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    if _value > 0:
        assert extcall ERC20(_token).transferFrom(_from, _to, _value, default_return_value=True), "Failed transferFrom"

@external
@payable
@nonreentrant
def deposit(recipient: bytes32, amount: uint256, path: Bytes[204] = b"", min_amount: uint256 = 0) -> uint256:
    assert amount > 0, "Invalid amount"
    _total_supply: uint256 = self.total_supply
    if _total_supply > 0:
        extcall AAVEPoolV3(Pool).withdraw(ASSET, max_value(uint256), self)
        _amount: uint256 = staticcall ERC20(ASSET).balanceOf(self) - _total_supply
        if _amount > 0:
            self._safe_transfer(ASSET, GOV, _amount)
    _last_nonce: uint256 = self.deposit_nonce
    _balance: uint256 = 0
    if path == b"":
        if ASSET == WETH9:
            if msg.value >= amount:
                if msg.value > amount:
                    raw_call(msg.sender, b"", value=msg.value - amount)
                extcall Weth(WETH9).deposit(value=amount)
            else:
                self._safe_transfer_from(ASSET, msg.sender, self, amount)
        else:
            if msg.value > 0:
                raw_call(msg.sender, b"", value=msg.value)
            self._safe_transfer_from(ASSET, msg.sender, self, amount)
        _balance = amount
    else:
        from_token: address = convert(slice(path, 0, 20), address)
        assert len(path) >= 43, "Path error"
        assert min_amount > 0, "Invalid min amount"
        if from_token == WETH9 and msg.value >= amount:
            if msg.value > amount:
                raw_call(msg.sender, b"", value=unsafe_sub(msg.value, amount))
            extcall Weth(WETH9).deposit(value=amount)
        else:
            self._safe_transfer_from(from_token, msg.sender, self, amount)
        self._safe_approve(from_token, ROUTER02, amount)
        _balance = staticcall ERC20(ASSET).balanceOf(self)
        extcall SwapRouter02(ROUTER02).exactInput(ExactInputParams(
            path = path,
            recipient = self,
            amountIn = amount,
            amountOutMinimum = min_amount
        ))
        _balance = staticcall ERC20(ASSET).balanceOf(self) - _balance
    if ASSET_DECIMALS_NUMERATOR != DENOMINATOR:
        _balance = _balance * ASSET_DECIMALS_NUMERATOR // DENOMINATOR
    assert _balance > 0, "ASSET amount is zero"
    extcall AAVEPoolV3(Pool).supply(ASSET, staticcall ERC20(ASSET).balanceOf(self), self, 0)
    self.total_supply = _total_supply + _balance
    self.deposit_nonce = _last_nonce + 1
    log Deposited(msg.sender, recipient, _balance, _last_nonce)
    return _balance

@external
@nonreentrant
def withdraw(sender: bytes32, recipient: address, amount: uint256, nonce: uint256):
    remaining_gas: uint256 = msg.gas
    self._paloma_check()
    assert not self.withdraw_nonces[nonce], "Invalid nonce"
    assert recipient != self.compass_evm, "Invalid recipient"
    _amount: uint256 = amount
    _redepmtion_fee: uint256 = self.redemption_fee
    _withdraw_balance: uint256 = amount
    if _redepmtion_fee > 0:
        _redepmtion_fee = _amount * _redepmtion_fee // DENOMINATOR
        _amount -= _redepmtion_fee
        _withdraw_balance = _amount
    if ASSET_DECIMALS_NUMERATOR != DENOMINATOR:
        _amount = _amount * DENOMINATOR // ASSET_DECIMALS_NUMERATOR
    assert _amount > 0, "Invalid amount"
    _total_supply: uint256 = self.total_supply
    extcall AAVEPoolV3(Pool).withdraw(ASSET, max_value(uint256), self)
    gas_price: uint256 = tx.gasprice
    round_id: uint80 = 0
    price: int256 = 0
    start_at: uint256 = 0
    update_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, price, start_at, update_at, answered_in_round = staticcall ChainlinkAggregator(Aggregator).latestRoundData()
    assert price > 0, "Invalid price"
    gas_amount: uint256 = remaining_gas * gas_price * convert(price, uint256) * 10 ** convert(staticcall ERC20(ASSET).decimals(), uint256) // 10 ** (Exponent + 18)
    assert _amount >= gas_amount + gas_amount, "Amount can not cover gas fee"
    self._safe_transfer(ASSET, GOV, gas_amount)
    self._safe_transfer(ASSET, self.refund_wallet, gas_amount)
    _withdraw_amount: uint256 = _amount - gas_amount - gas_amount
    assert _total_supply >= _withdraw_balance, "Insufficient deposit"
    _total_supply -= _withdraw_balance
    if ASSET == WETH9:
        extcall Weth(WETH9).withdraw(_withdraw_amount)
        raw_call(recipient, b"", value=_withdraw_amount)
    else:
        self._safe_transfer(ASSET, recipient, _withdraw_amount)
    if _total_supply > 0:
        extcall AAVEPoolV3(Pool).supply(ASSET, _total_supply, self, 0)
    self._safe_transfer(ASSET, GOV, staticcall ERC20(ASSET).balanceOf(self))
    self.total_supply = _total_supply
    self.withdraw_nonces[nonce] = True
    log Withdrawn(sender, recipient, _withdraw_balance, _withdraw_amount,  nonce)

@external
def update_compass(new_compass: address):
    _compass: address = self.compass_evm
    assert msg.sender == _compass, "Not compass"
    assert not staticcall Compass(_compass).slc_switch(), "SLC is unavailable"
    self.compass_evm = new_compass
    log UpdateCompass(msg.sender, new_compass)

@external
def update_refund_wallet(_new_refund_wallet: address):
    self._paloma_check()
    _old_refund_wallet: address = self.refund_wallet
    self.refund_wallet = _new_refund_wallet
    log UpdateRefundWallet(_old_refund_wallet, _new_refund_wallet)

@external
def update_redemption_fee(_new_redemption_fee: uint256):
    assert _new_redemption_fee < DENOMINATOR, "Invalid redemption fee"
    self._paloma_check()
    _old_redemption_fee: uint256 = self.redemption_fee
    self.redemption_fee = _new_redemption_fee
    log UpdateRedemptionFee(_old_redemption_fee, _new_redemption_fee)

@external
def set_paloma():
    assert msg.sender == self.compass_evm and self.paloma == empty(bytes32) and len(msg.data) == 36, "Unauthorized"
    _paloma: bytes32 = convert(slice(msg.data, 4, 32), bytes32)
    self.paloma = _paloma
    log SetPaloma(_paloma)

@external
@payable
def __default__():
    pass
