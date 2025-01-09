#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title PUSD manager
@license Apache 2.0
@author Volume.finance
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def approve(_spender: address, _value: uint256) -> bool: nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable

USDT: public(immutable(address))
pwUSDT: public(immutable(address))
compass_evm: public(address)
nonce: public(uint256)
paloma: public(bytes32)

event Deposit:
    sender: indexed(address)
    receiver: bytes32
    amount: uint256

event Withdraw:
    receiver: indexed(address)
    amount: uint256

event UpdateCompass:
    old_compass: address
    new_compass: address

event SetPaloma:
    paloma: bytes32

@deploy
def __init__(_compass_evm: address, _usdt: address, _pw_usdt: address):
    self.compass_evm = _compass_evm
    USDT = _usdt
    pwUSDT = _pw_usdt
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
def deposit(receiver: bytes32, amount: uint256):
    assert amount > 0, "Invalid amount"
    self._safe_transfer_from(USDT, msg.sender, self, amount)
    log Deposit(msg.sender, receiver, amount)

@external
def withdraw(receiver: address, amount: uint256, nonce: uint256):
    self._paloma_check()
    _last_nonce: uint256 = self.nonce
    assert nonce == _last_nonce, "Invalid nonce"
    assert receiver != self.compass_evm, "Invalid receiver"
    assert amount > 0, "Invalid amount"
    self._safe_transfer(USDT, receiver, amount)
    self.nonce = _last_nonce + 1
    log Withdraw(receiver, amount)

@external
def update_compass(new_compass: address):
    self._paloma_check()
    self.compass_evm = new_compass
    log UpdateCompass(msg.sender, new_compass)

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
