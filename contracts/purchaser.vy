#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title Bonding Curve Trader Vyper
@license Apache 2.0
@author Volume.finance
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def approve(_spender: address, _value: uint256) -> bool: nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable

interface PusdManager:
    def ASSET() -> address: view
    def deposit(recipient: bytes32, amount: uint256, path: Bytes[204] = b"", min_amount: uint256 = 0) -> uint256: nonpayable

interface Weth:
    def deposit(): payable

interface Compass:
    def send_token_to_paloma(token: address, receiver: bytes32, amount: uint256): nonpayable
    def slc_switch() -> bool: view

DENOMINATOR: constant(uint256) = 10 ** 18
WETH9: public(immutable(address))

event Purchase:
    sender: indexed(address)
    from_token: address
    amount: uint256
    pusd_amount: uint256
    to_token: address
    paloma: bytes32

event Sell:
    sender: indexed(address)
    from_token: address
    amount: uint256
    paloma: bytes32

event TokenSent:
    token: address
    to: address
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

event UpdateGasFee:
    old_gas_fee: uint256
    new_gas_fee: uint256

event UpdateServiceFeeCollector:
    old_service_fee_collector: address
    new_service_fee_collector: address

event UpdateServiceFee:
    old_service_fee: uint256
    new_service_fee: uint256

compass: public(address)
pusd_manager: public(immutable(address))
refund_wallet: public(address)
gas_fee: public(uint256)
service_fee_collector: public(address)
service_fee: public(uint256)
paloma: public(bytes32)
send_nonces: public(HashMap[uint256, bool])

@deploy
def __init__(_compass: address, _pusd_manager: address, _weth9: address, _refund_wallet: address, _gas_fee: uint256, _service_fee_collector: address, _service_fee: uint256):
    self.compass = _compass
    pusd_manager = _pusd_manager
    self.refund_wallet = _refund_wallet
    self.gas_fee = _gas_fee
    self.service_fee_collector = _service_fee_collector
    self.service_fee = _service_fee
    WETH9 = _weth9
    log UpdateCompass(empty(address), _compass)
    log UpdateRefundWallet(empty(address), _refund_wallet)
    log UpdateGasFee(0, _gas_fee)
    log UpdateServiceFeeCollector(empty(address), _service_fee_collector)
    log UpdateServiceFee(0, _service_fee)

@internal
def _safe_approve(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).approve(_to, _value, default_return_value=True), "Failed approve"

@internal
def _safe_transfer(_token: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transfer(_to, _value, default_return_value=True), "Failed transfer"

@internal
def _safe_transfer_from(_token: address, _from: address, _to: address, _value: uint256):
    assert extcall ERC20(_token).transferFrom(_from, _to, _value, default_return_value=True), "Failed transferFrom"

@internal
def _paloma_check():
    assert msg.sender == self.compass, "Not compass"
    assert self.paloma == convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), bytes32), "Invalid paloma"

@external
@payable
@nonreentrant
def purchase(to_token: address, path: Bytes[204], amount: uint256, min_amount: uint256 = 0):
    _value: uint256 = msg.value
    _gas_fee: uint256 = self.gas_fee
    if _gas_fee > 0:
        _value -= _gas_fee
        send(self.refund_wallet, _gas_fee)
    _path: Bytes[204] = b""
    from_token: address = empty(address)
    if path == b"":
        from_token = staticcall PusdManager(pusd_manager).ASSET()
    else:
        from_token = convert(slice(path, 0, 20), address)
        if len(path) > 20:
            _path = path
            assert min_amount > 0, "Invalid min amount"
    _amount: uint256 = amount
    if from_token == WETH9 and _value >= amount:
        if _value > amount:
            raw_call(msg.sender, b"", value=_value - amount)
        extcall Weth(WETH9).deposit(value=amount)
    else:
        _amount = staticcall ERC20(from_token).balanceOf(self)
        self._safe_transfer_from(from_token, msg.sender, self, amount)
        _amount = staticcall ERC20(from_token).balanceOf(self) - _amount
    _paloma: bytes32 = self.paloma
    _service_fee: uint256 = self.service_fee
    if _service_fee > 0:
        _service_fee_collector: address = self.service_fee_collector
        _service_fee_amount: uint256 = _amount * _service_fee // DENOMINATOR
        self._safe_transfer(from_token, _service_fee_collector, _service_fee_amount)
        _amount -= _service_fee_amount
    self._safe_approve(from_token, pusd_manager, _amount)
    pusd_amount: uint256 = extcall PusdManager(pusd_manager).deposit(_paloma, _amount, _path, min_amount)
    log Purchase(msg.sender, from_token, _amount, pusd_amount, to_token, _paloma)

@external
@payable
@nonreentrant
def sell(from_token: address, amount: uint256):
    _amount: uint256 = amount
    _service_fee: uint256 = self.service_fee
    _gas_fee: uint256 = self.gas_fee
    if _gas_fee > 0:
        assert msg.value >= _gas_fee, "Invalid gas fee"
        if msg.value > _gas_fee:
            raw_call(msg.sender, b"", value=msg.value - _gas_fee)
        send(self.refund_wallet, _gas_fee)
    self._safe_transfer_from(from_token, msg.sender, self, _amount)
    if _service_fee > 0:
        _service_fee_collector: address = self.service_fee_collector
        _service_fee_amount: uint256 = amount * _service_fee // DENOMINATOR
        self._safe_transfer(from_token, _service_fee_collector, _service_fee_amount)
        _amount -= _service_fee_amount
    _compass: address = self.compass
    _paloma: bytes32 = self.paloma
    self._safe_approve(from_token, _compass, _amount)
    extcall Compass(_compass).send_token_to_paloma(from_token, _paloma, _amount)
    log Sell(msg.sender, from_token, _amount, _paloma)

@external
@payable
@nonreentrant
def purchase_by_pusd(to_token: address, pusd: address, amount: uint256):
    _gas_fee: uint256 = self.gas_fee
    if _gas_fee > 0:
        assert msg.value >= _gas_fee, "Invalid gas fee"
        if msg.value > _gas_fee:
            raw_call(msg.sender, b"", value=msg.value - _gas_fee)
        send(self.refund_wallet, _gas_fee)
    _compass: address = self.compass
    _service_fee: uint256 = self.service_fee
    _amount: uint256 = amount
    self._safe_transfer_from(pusd, msg.sender, self, _amount)
    if _service_fee > 0:
        _service_fee_collector: address = self.service_fee_collector
        _service_fee_amount: uint256 = amount * _service_fee // DENOMINATOR
        self._safe_transfer(pusd, _service_fee_collector, _service_fee_amount)
        _amount -= _service_fee_amount
    self._safe_approve(pusd, _compass, _amount)
    _paloma: bytes32 = self.paloma
    extcall Compass(_compass).send_token_to_paloma(pusd, _paloma, _amount)
    log Purchase(msg.sender, pusd, _amount, _amount, to_token, _paloma)

@external
def send_token(token: address, to: address, amount: uint256, nonce: uint256):
    self._paloma_check()
    assert not self.send_nonces[nonce], "Invalid nonce"
    if token == empty(address):
        send(to, amount)
    else:
        self._safe_transfer(token, to, amount)
    self.send_nonces[nonce] = True
    log TokenSent(token, to, amount, nonce)

@external
def update_compass(new_compass: address):
    _compass: address = self.compass
    assert msg.sender == _compass, "Not compass"
    assert not staticcall Compass(_compass).slc_switch(), "SLC is unavailable"
    self.compass = new_compass
    log UpdateCompass(msg.sender, new_compass)

@external
def set_paloma():
    assert msg.sender == self.compass and self.paloma == empty(bytes32) and len(msg.data) == 36, "Invalid"
    _paloma: bytes32 = convert(slice(msg.data, 4, 32), bytes32)
    self.paloma = _paloma
    log SetPaloma(_paloma)

@external
def update_refund_wallet(new_refund_wallet: address):
    self._paloma_check()
    old_refund_wallet: address = self.refund_wallet
    self.refund_wallet = new_refund_wallet
    log UpdateRefundWallet(old_refund_wallet, new_refund_wallet)

@external
def update_gas_fee(new_gas_fee: uint256):
    self._paloma_check()
    old_gas_fee: uint256 = self.gas_fee
    self.gas_fee = new_gas_fee
    log UpdateGasFee(old_gas_fee, new_gas_fee)

@external
def update_service_fee_collector(new_service_fee_collector: address):
    self._paloma_check()
    old_service_fee_collector: address = self.service_fee_collector
    self.service_fee_collector = new_service_fee_collector
    log UpdateServiceFeeCollector(old_service_fee_collector, new_service_fee_collector)

@external
def update_service_fee(new_service_fee: uint256):
    self._paloma_check()
    assert new_service_fee < DENOMINATOR, "Invalid service fee"
    old_service_fee: uint256 = self.service_fee
    self.service_fee = new_service_fee
    log UpdateServiceFee(old_service_fee, new_service_fee)

@external
@payable
def __default__():
    pass