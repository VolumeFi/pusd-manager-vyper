#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title PUSD manager
@license Apache 2.0
@author Volume.finance
"""

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

USDT: public(immutable(address))
Pool: public(immutable(address))
GOV: public(immutable(address))
Aggregator: public(immutable(address))
Exponent: public(immutable(uint256))
compass_evm: public(address)
refund_wallet: public(address)
withdraw_nonces: public(HashMap[uint256, bool])
deposit_nonce: public(uint256)
paloma: public(bytes32)
total_supply: public(uint256)

event Deposited:
    sender: indexed(address)
    recipient: bytes32
    amount: uint256
    nonce: uint256

event Withdrawn:
    sender: bytes32
    recipient: indexed(address)
    amount: uint256
    nonce: uint256

event UpdateCompass:
    old_compass: address
    new_compass: address

event UpdateRefundWallet:
    old_refund_wallet: address
    new_refund_wallet: address

event SetPaloma:
    paloma: bytes32

@deploy
def __init__(_compass_evm: address, _usdt: address, _pool: address, _aggregator: address, _exponent: uint256, _governance: address, _refund_wallet: address):
    self.compass_evm = _compass_evm
    USDT = _usdt
    Pool = _pool
    GOV = _governance
    Aggregator = _aggregator
    Exponent = _exponent
    self.refund_wallet = _refund_wallet
    assert extcall ERC20(USDT).approve(Pool, max_value(uint256), default_return_value=True), "Failed approve"
    log UpdateCompass(empty(address), _compass_evm)

@internal
def _paloma_check():
    assert msg.sender == self.compass_evm, "Not compass"
    assert self.paloma == convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), bytes32), "Invalid paloma"

@internal
def _safe_transfer(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transfer(_to, _value, default_return_value=True), "Failed transfer"

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transferFrom(_from, _to, _value, default_return_value=True), "Failed transferFrom"

@external
def deposit(recipient: bytes32, amount: uint256):
    assert amount > 0, "Invalid amount"
    _last_nonce: uint256 = self.deposit_nonce
    self._safe_transfer_from(USDT, msg.sender, self, amount)
    extcall AAVEPoolV3(Pool).supply(USDT, amount, self, 0)
    self.total_supply += amount
    self.deposit_nonce = _last_nonce + 1
    log Deposited(msg.sender, recipient, amount, _last_nonce)

@external
def withdraw(sender: bytes32, recipient: address, amount: uint256, nonce: uint256):
    remaining_gas: uint256 = msg.gas
    self._paloma_check()
    assert not self.withdraw_nonces[nonce], "Invalid nonce"
    assert recipient != self.compass_evm, "Invalid recipient"
    assert amount > 0, "Invalid amount"
    _total_supply: uint256 = self.total_supply
    assert _total_supply >= amount, "Insufficient deposit"
    extcall AAVEPoolV3(Pool).withdraw(USDT, max_value(uint256), self)
    gas_price: uint256 = tx.gasprice
    round_id: uint80 = 0
    price: int256 = 0
    start_at: uint256 = 0
    update_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, price, start_at, update_at, answered_in_round = staticcall ChainlinkAggregator(Aggregator).latestRoundData()
    assert price > 0, "Invalid price"
    _amount: uint256 = remaining_gas * gas_price * convert(price, uint256) * 10 ** convert(staticcall ERC20(USDT).decimals(), uint256) // 10 ** Exponent
    assert amount >= _amount + _amount, "Amount can not cover gas fee"
    self._safe_transfer(USDT, GOV, _amount)
    self._safe_transfer(USDT, self.refund_wallet, _amount)
    self._safe_transfer(USDT, recipient, amount - _amount - _amount)
    _total_supply = _total_supply - amount
    extcall AAVEPoolV3(Pool).supply(USDT, _total_supply, self, 0)
    self._safe_transfer(USDT, GOV, staticcall ERC20(USDT).balanceOf(self))
    self.total_supply = _total_supply
    self.withdraw_nonces[nonce] = True
    log Withdrawn(sender, recipient, amount, nonce)

@external
def update_compass(new_compass: address):
    self._paloma_check()
    self.compass_evm = new_compass
    log UpdateCompass(msg.sender, new_compass)

@external
def update_refund_wallet(_new_refund_wallet: address):
    self._paloma_check()
    self.refund_wallet = _new_refund_wallet
    log UpdateRefundWallet(self.refund_wallet, _new_refund_wallet)

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
