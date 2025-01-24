#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title Bonding Curve Bot
@license Apache 2.0
@author Volume.finance
"""

struct ExactInputParams:
    path: Bytes[204]
    recipient: address
    amountIn: uint256
    amountOutMinimum: uint256

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def approve(_spender: address, _value: uint256) -> bool: nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable

interface PusdManager:
    def deposit(recipient: bytes32, amount: uint256): nonpayable

interface SwapRouter02:
    def WETH9() -> address: pure
    def exactInput(params: ExactInputParams) -> uint256: payable

interface Weth:
    def deposit(): payable

DENOMINATOR: constant(uint256) = 10 ** 18
PUSD_MANAGER: public(immutable(address))
ROUTER02: public(immutable(address))
WETH9: public(immutable(address))
USDT: public(immutable(address))
compass_evm: public(address)
paloma: public(bytes32)

event Exchange:
    sender: indexed(address)
    from_token: indexed(address)
    amount: uint256
    to_token: indexed(address)
    recipient: bytes32

event TokenSent:
    token: indexed(address)
    to: indexed(address)
    amount: uint256

event UpdateCompass:
    old_compass: address
    new_compass: address

event SetPaloma:
    paloma: bytes32

@deploy
def __init__(_compass_evm: address, _pusd_manager: address, _uniswap_v3_router_02: address, _usdt: address):
    self.compass_evm = _compass_evm
    PUSD_MANAGER = _pusd_manager
    ROUTER02 = _uniswap_v3_router_02
    WETH9 = staticcall SwapRouter02(_uniswap_v3_router_02).WETH9()
    USDT = _usdt
    log UpdateCompass(empty(address), _compass_evm)

@internal
def _paloma_check():
    assert msg.sender == self.compass_evm, "Not compass"
    assert self.paloma == convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), bytes32), "Invalid paloma"

@internal
def _safe_approve(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).approve(_to, _value, default_return_value=True), "Failed approve"

@internal
def _safe_transfer(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transfer(_to, _value, default_return_value=True), "Failed transfer"

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transferFrom(_from, _to, _value, default_return_value=True), "Failed transferFrom"

@external
@payable
@nonreentrant
def exchange(path: Bytes[204], amount: uint256, min_amount: uint256, to_token: address, _paloma_address: bytes32):
    assert amount > 0, "Invalid amount"
    from_token: address = convert(slice(path, 0, 20), address)
    _balance: uint256 = 0
    if from_token == USDT:
        self._safe_transfer_from(USDT, msg.sender, self, amount)
        _balance = amount
    else:
        assert len(path) >= 43, "Path error"
        if from_token == WETH9 and msg.value >= amount:
            if msg.value > amount:
                raw_call(msg.sender, b"", value=unsafe_sub(msg.value, amount))
            extcall Weth(WETH9).deposit(value=amount)
        else:
            self._safe_transfer_from(from_token, msg.sender, self, amount)
        self._safe_approve(from_token, ROUTER02, amount)
        _balance = staticcall ERC20(USDT).balanceOf(self)
        extcall SwapRouter02(ROUTER02).exactInput(ExactInputParams(
            path = path,
            recipient = self,
            amountIn = amount,
            amountOutMinimum = min_amount
        ))
        _balance = staticcall ERC20(USDT).balanceOf(self) - _balance
    assert _balance > 0, "Invalid swap to USDT"
    _paloma: bytes32 = _paloma_address
    if _paloma == empty(bytes32):
        _paloma = self.paloma
    extcall PusdManager(PUSD_MANAGER).deposit(_paloma, _balance)
    log Exchange(msg.sender, from_token, _balance, to_token, _paloma)

@external
def send_token(token: address, to: address, amount: uint256):
    self._paloma_check()
    self._safe_transfer(token, to, amount)
    log TokenSent(token, to, amount)

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