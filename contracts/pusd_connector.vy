#pragma version 0.4.0
#pragma optimize gas
#pragma evm-version cancun
"""
@title PUSD connector
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
    def total_supply() -> uint256: view
    def ASSET_DECIMALS_NUMERATOR() -> uint256: view

interface Weth:
    def deposit(): payable

interface Compass:
    def send_token_to_paloma(token: address, receiver: bytes32, amount: uint256): nonpayable
    def slc_switch() -> bool: view

DENOMINATOR: constant(uint256) = 10 ** 18
WETH9: public(immutable(address))

event Purchased:
    sender: indexed(address)
    from_token: address
    amount: uint256
    pusd_amount: uint256
    nonce: uint256
    paloma: bytes32

event Withdrawn:
    sender: indexed(address)
    from_token: address
    amount: uint256
    nonce: uint256
    paloma: bytes32

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

event UpdateWithdrawLimit:
    old_withdraw_limit: uint256
    new_withdraw_limit: uint256

event UpdatePusdManager:
    old_pusd_manager: address
    new_pusd_manager: address

event UpdatePusd:
    old_pusd: address
    new_pusd: address

compass: public(address)
pusd: public(address)
withdraw_limit: public(uint256)
pusd_manager: public(address)
refund_wallet: public(address)
gas_fee: public(uint256)
service_fee_collector: public(address)
service_fee: public(uint256)
nonce: public(uint256)
paloma: public(bytes32)

@deploy
def __init__(_compass: address, _pusd_manager: address, _pusd: address, _withdraw_limit: uint256, _weth9: address, _refund_wallet: address, _gas_fee: uint256, _service_fee_collector: address, _service_fee: uint256):
    self.compass = _compass
    self.pusd_manager = _pusd_manager
    self.pusd = _pusd
    self.refund_wallet = _refund_wallet
    self.gas_fee = _gas_fee
    self.service_fee_collector = _service_fee_collector
    self.service_fee = _service_fee
    self.withdraw_limit = _withdraw_limit
    WETH9 = _weth9
    log UpdateCompass(empty(address), _compass)
    log UpdateRefundWallet(empty(address), _refund_wallet)
    log UpdateGasFee(0, _gas_fee)
    log UpdateServiceFeeCollector(empty(address), _service_fee_collector)
    log UpdateServiceFee(0, _service_fee)
    log UpdateWithdrawLimit(0, _withdraw_limit)

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
def purchase(path: Bytes[204], amount: uint256, min_amount: uint256 = 0):
    _value: uint256 = msg.value
    _gas_fee: uint256 = self.gas_fee
    if _gas_fee > 0:
        _value -= _gas_fee
        send(self.refund_wallet, _gas_fee)
    _path: Bytes[204] = b""
    from_token: address = empty(address)
    _pusd_manager: address = self.pusd_manager
    if path == b"":
        from_token = staticcall PusdManager(_pusd_manager).ASSET()
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
    self._safe_approve(from_token, _pusd_manager, _amount)
    pusd_amount: uint256 = extcall PusdManager(_pusd_manager).deposit(_paloma, _amount, _path, min_amount)
    _nonce: uint256 = self.nonce
    _nonce += 1
    self.nonce = _nonce
    log Purchased(msg.sender, from_token, _amount, pusd_amount, _nonce, _paloma)

@external
@payable
@nonreentrant
def withdraw(amount: uint256):
    assert amount > self.withdraw_limit, "Insufficient withdraw limit"
    _pusd_manager: address = self.pusd_manager
    _total_supply: uint256 = staticcall PusdManager(_pusd_manager).total_supply()
    _total_supply = _total_supply * staticcall PusdManager(_pusd_manager).ASSET_DECIMALS_NUMERATOR() // DENOMINATOR
    assert amount <= _total_supply, "Asset is insufficient"
    _amount: uint256 = amount
    _service_fee: uint256 = self.service_fee
    _gas_fee: uint256 = self.gas_fee
    if _gas_fee > 0:
        assert msg.value >= _gas_fee, "Invalid gas fee"
        if msg.value > _gas_fee:
            raw_call(msg.sender, b"", value=msg.value - _gas_fee)
        send(self.refund_wallet, _gas_fee)
    from_token: address = self.pusd
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
    _nonce: uint256 = self.nonce
    _nonce += 1
    self.nonce = _nonce
    log Withdrawn(msg.sender, from_token, _amount, _nonce, _paloma)

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
def update_withdraw_limit(new_withdraw_limit: uint256):
    self._paloma_check()
    self.withdraw_limit = new_withdraw_limit
    log UpdateWithdrawLimit(self.withdraw_limit, new_withdraw_limit)

@external
def update_pusd_manager(new_pusd_manager: address):
    self._paloma_check()
    old_pusd_manager: address = self.pusd_manager
    self.pusd_manager = new_pusd_manager
    log UpdatePusdManager(old_pusd_manager, new_pusd_manager)

@external
def update_pusd(new_pusd: address):
    self._paloma_check()
    old_pusd: address = self.pusd
    self.pusd = new_pusd
    log UpdatePusd(old_pusd, new_pusd)

@external
@payable
def __default__():
    pass