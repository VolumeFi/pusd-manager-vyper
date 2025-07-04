# pUSD Manager Vyper

The pUSD Manager Vyper is a smart contract system implemented in Vyper for managing pUSD, a stablecoin in the VolumeFi ecosystem. This contract facilitates the minting, burning, and overall management of pUSD tokens, ensuring stability and security within the decentralized finance (DeFi) space.

## Overview

This repository contains the Vyper implementation of the pUSD Manager contract system, consisting of four main contracts:

1. **`pusd_manager.vy`** - Main pUSD manager contract for Ethereum mainnet
2. **`pusd_manager_xdai.vy`** - pUSD manager contract for xDai network
3. **`pusd_connector.vy`** - Connector contract for cross-chain operations
4. **`purchaser.vy`** - Bonding curve trader contract

## Contract Architecture

### Core Contracts

#### 1. pUSD Manager (`pusd_manager.vy`)

The main contract responsible for managing pUSD token operations on Ethereum mainnet.

**Key State Variables:**
- `ASSET`: The underlying asset address (e.g., WETH)
- `Pool`: AAVE Pool V3 address for yield generation
- `GOV`: Governance address for fee collection
- `compass_evm`: Cross-chain bridge contract address
- `redemption_fee`: Fee charged on withdrawals (in basis points)
- `total_supply`: Total amount of underlying asset deposited

**Functions:**

##### `__init__(_compass_evm: address, _initial_asset: address, _pool: address, _aggregator: address, _exponent: uint256, _governance: address, _refund_wallet: address, _router02: address, _redepmtion_fee: uint256)`
- **Purpose**: Constructor function that initializes the contract
- **Parameters**:
  - `_compass_evm`: Cross-chain bridge contract address
  - `_initial_asset`: Underlying asset token address
  - `_pool`: AAVE Pool V3 address
  - `_aggregator`: Chainlink price aggregator address
  - `_exponent`: Price exponent for gas calculations
  - `_governance`: Governance address for fee collection
  - `_refund_wallet`: Wallet to receive gas fee refunds
  - `_router02`: Uniswap V3 router address
  - `_redepmtion_fee`: Redemption fee in basis points
- **Security**: Validates redemption fee is less than 100% (DENOMINATOR)
- **Example Usage**:
```vyper
# Deploy with WETH as underlying asset
pusd_manager = PusdManager.deploy(
    compass_evm=0x...,
    _initial_asset=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,  # WETH
    _pool=0x...,
    _aggregator=0x...,
    _exponent=8,
    _governance=0x...,
    _refund_wallet=0x...,
    _router02=0x...,
    _redepmtion_fee=100  # 1% fee
)
```

##### `deposit(recipient: bytes32, amount: uint256, path: Bytes[204] = b"", min_amount: uint256 = 0) -> uint256`
- **Purpose**: Deposits underlying asset and mints pUSD tokens
- **Parameters**:
  - `recipient`: Cross-chain recipient address (bytes32)
  - `amount`: Amount of underlying asset to deposit
  - `path`: Uniswap V3 swap path (optional)
  - `min_amount`: Minimum output amount for swaps (optional)
- **Returns**: Amount of pUSD tokens minted
- **Security Features**:
  - Non-reentrant protection
  - Validates amount > 0
  - Handles both direct deposits and swaps
  - Supports ETH/WETH conversion
- **Example Usage**:
```vyper
# Direct WETH deposit
pusd_amount = pusd_manager.deposit(
    recipient=0x1234...,
    amount=1000000000000000000,  # 1 WETH
    value=1000000000000000000
)

# Swap USDC to WETH then deposit
pusd_amount = pusd_manager.deposit(
    recipient=0x1234...,
    amount=1000000,  # 1 USDC
    path=encode_path(USDC, WETH),
    min_amount=990000000000000000  # 0.99 WETH minimum
)
```

##### `withdraw(sender: bytes32, recipient: address, amount: uint256, nonce: uint256)`
- **Purpose**: Withdraws underlying asset by burning pUSD tokens
- **Parameters**:
  - `sender`: Cross-chain sender address (bytes32)
  - `recipient`: Ethereum address to receive withdrawn assets
  - `amount`: Amount of pUSD tokens to burn
  - `nonce`: Unique withdrawal nonce to prevent replay attacks
- **Security Features**:
  - Paloma bridge authentication
  - Nonce replay protection
  - Redemption fee calculation
  - Gas fee deduction
  - Validates recipient != compass_evm
- **Example Usage**:
```vyper
# Called by compass bridge
pusd_manager.withdraw(
    sender=0x1234...,
    recipient=0xabcd...,
    amount=1000000000000000000,  # 1 pUSD
    nonce=12345
)
```

##### `update_compass(new_compass: address)`
- **Purpose**: Updates the compass bridge contract address
- **Parameters**:
  - `new_compass`: New compass contract address
- **Security**: Only callable by current compass contract when SLC is unavailable
- **Example Usage**:
```vyper
pusd_manager.update_compass(0xnew_compass_address)
```

##### `update_refund_wallet(_new_refund_wallet: address)`
- **Purpose**: Updates the refund wallet address
- **Parameters**:
  - `_new_refund_wallet`: New refund wallet address
- **Security**: Requires paloma bridge authentication
- **Example Usage**:
```vyper
pusd_manager.update_refund_wallet(0xnew_refund_wallet)
```

##### `update_redemption_fee(_new_redemption_fee: uint256)`
- **Purpose**: Updates the redemption fee percentage
- **Parameters**:
  - `_new_redemption_fee`: New redemption fee in basis points
- **Security**: 
  - Requires paloma bridge authentication
  - Validates fee < 100% (DENOMINATOR)
- **Example Usage**:
```vyper
pusd_manager.update_redemption_fee(200)  # 2% fee
```

##### `set_paloma()`
- **Purpose**: Sets the paloma identifier for cross-chain operations
- **Security**: 
  - Only callable by compass contract
  - Can only be set once (paloma must be empty)
  - Requires specific message data length
- **Example Usage**:
```vyper
pusd_manager.set_paloma()  # Called by compass with paloma data
```

#### 2. pUSD Manager xDai (`pusd_manager_xdai.vy`)

Similar to the main pUSD manager but optimized for xDai network without price oracle dependencies.

**Key Differences:**
- No Chainlink price aggregator integration
- Simplified gas fee calculation (no price conversion)
- Direct WXDAI handling

**Functions:** Same as main pUSD manager except for simplified gas calculations in `withdraw()`.

#### 3. pUSD Connector (`pusd_connector.vy`)

Connector contract that handles cross-chain pUSD operations and fee collection.

**Key State Variables:**
- `pusd_manager`: Address of the pUSD manager contract
- `pusd`: pUSD token address
- `withdraw_limit`: Minimum withdrawal amount
- `gas_fee`: Gas fee in ETH
- `service_fee`: Service fee percentage

**Functions:**

##### `__init__(_compass: address, _pusd_manager: address, _pusd: address, _withdraw_limit: uint256, _weth9: address, _refund_wallet: address, _gas_fee: uint256, _service_fee_collector: address, _service_fee: uint256)`
- **Purpose**: Constructor for connector contract
- **Parameters**:
  - `_compass`: Cross-chain bridge address
  - `_pusd_manager`: pUSD manager contract address
  - `_pusd`: pUSD token address
  - `_withdraw_limit`: Minimum withdrawal amount
  - `_weth9`: WETH token address
  - `_refund_wallet`: Gas fee refund wallet
  - `_gas_fee`: Gas fee amount
  - `_service_fee_collector`: Service fee collector address
  - `_service_fee`: Service fee percentage
- **Example Usage**:
```vyper
connector = PusdConnector.deploy(
    _compass=0x...,
    _pusd_manager=pusd_manager.address,
    _pusd=pusd_token.address,
    _withdraw_limit=1000000000000000000,  # 1 pUSD
    _weth9=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
    _refund_wallet=0x...,
    _gas_fee=10000000000000000,  # 0.01 ETH
    _service_fee_collector=0x...,
    _service_fee=50000000000000000  # 5%
)
```

##### `purchase(path: Bytes[204], amount: uint256, min_amount: uint256 = 0)`
- **Purpose**: Purchases pUSD tokens with any supported asset
- **Parameters**:
  - `path`: Uniswap V3 swap path
  - `amount`: Amount of input token
  - `min_amount`: Minimum output amount for swaps
- **Security Features**:
  - Non-reentrant protection
  - Gas fee deduction
  - Service fee collection
  - Supports ETH/WETH conversion
- **Example Usage**:
```vyper
# Purchase pUSD with USDC
connector.purchase(
    path=encode_path(USDC, WETH),
    amount=1000000,  # 1 USDC
    min_amount=990000000000000000,  # 0.99 WETH minimum
    value=10000000000000000  # 0.01 ETH gas fee
)
```

##### `withdraw(amount: uint256)`
- **Purpose**: Initiates cross-chain withdrawal of pUSD tokens
- **Parameters**:
  - `amount`: Amount of pUSD to withdraw
- **Security Features**:
  - Validates withdrawal limit
  - Checks total supply availability
  - Gas and service fee handling
- **Example Usage**:
```vyper
connector.withdraw(
    amount=1000000000000000000,  # 1 pUSD
    value=10000000000000000  # 0.01 ETH gas fee
)
```

#### 4. Purchaser (`purchaser.vy`)

Bonding curve trader contract for pUSD token trading.

**Functions:**

##### `purchase(to_token: address, path: Bytes[204], amount: uint256, min_amount: uint256 = 0)`
- **Purpose**: Purchases pUSD and sends to specified token on another chain
- **Parameters**:
  - `to_token`: Token address on destination chain
  - `path`: Swap path for input token
  - `amount`: Amount of input token
  - `min_amount`: Minimum output amount
- **Example Usage**:
```vyper
purchaser.purchase(
    to_token=0x...,
    path=encode_path(USDC, WETH),
    amount=1000000,
    min_amount=990000000000000000,
    value=10000000000000000
)
```

##### `sell(from_token: address, amount: uint256)`
- **Purpose**: Sells tokens and sends pUSD to another chain
- **Parameters**:
  - `from_token`: Token to sell
  - `amount`: Amount to sell
- **Example Usage**:
```vyper
purchaser.sell(
    from_token=0x...,
    amount=1000000000000000000,
    value=10000000000000000
)
```

##### `purchase_by_pusd(to_token: address, pusd: address, amount: uint256)`
- **Purpose**: Purchases tokens using existing pUSD balance
- **Parameters**:
  - `to_token`: Token address on destination chain
  - `pusd`: pUSD token address
  - `amount`: Amount of pUSD to use
- **Example Usage**:
```vyper
purchaser.purchase_by_pusd(
    to_token=0x...,
    pusd=pusd_token.address,
    amount=1000000000000000000,
    value=10000000000000000
)
```

## Security Considerations

### Access Control
- **Governance**: Only governance address can receive fees
- **Compass Bridge**: Cross-chain operations require compass authentication
- **Paloma Verification**: All cross-chain calls verify paloma identifier

### Reentrancy Protection
- All external functions use `@nonreentrant` decorator
- State changes occur before external calls where possible

### Input Validation
- Amount validation (must be > 0)
- Address validation (recipient != compass_evm)
- Fee validation (redemption_fee < 100%)
- Nonce replay protection

### Gas Optimization
- Efficient storage usage with immutable variables
- Minimal external calls
- Optimized math operations

## Testing

### Prerequisites

To run tests, ensure you have the following installed:

- [Python 3.8+](https://www.python.org/downloads/)
- [Ape Framework](https://docs.apeworx.io/ape/stable/userguides/quickstart.html)
- [Vyper Compiler](https://vyper.readthedocs.io/en/stable/installing-vyper.html)

### Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/VolumeFi/pusd-manager-vyper.git
   cd pusd-manager-vyper
   ```

2. **Set Up Virtual Environment**:
   ```bash
   python3 -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Install Ape Framework**:
   ```bash
   pip install eth-ape
   ```

### Running Tests

1. **Compile Contracts**:
   ```bash
   ape compile
   ```

2. **Run All Tests**:
   ```bash
   ape test
   ```

3. **Run Tests with Verbose Output**:
   ```bash
   ape test -v
   ```

4. **Run Specific Test File**:
   ```bash
   ape test tests/test_pusd_manager.py
   ```

5. **Run Tests with Coverage**:
   ```bash
   ape test --coverage
   ```

6. **Run Tests on Specific Network**:
   ```bash
   ape test --network ethereum:mainnet:alchemy
   ```

### Test Structure

Create a `tests/` directory with the following structure:

```
tests/
├── conftest.py          # Test fixtures and setup
├── test_pusd_manager.py # Main pUSD manager tests
├── test_connector.py    # Connector contract tests
└── test_purchaser.py    # Purchaser contract tests
```

### Example Test File

```python
# tests/test_pusd_manager.py
import pytest
from ape import accounts, Contract

@pytest.fixture
def owner(accounts):
    return accounts[0]

@pytest.fixture
def user(accounts):
    return accounts[1]

@pytest.fixture
def pusd_manager(owner, project):
    return owner.deploy(project.PusdManager, 
                       _compass_evm="0x...",
                       _initial_asset="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
                       _pool="0x...",
                       _aggregator="0x...",
                       _exponent=8,
                       _governance=owner.address,
                       _refund_wallet="0x...",
                       _router02="0x...",
                       _redepmtion_fee=100)

def test_deposit(pusd_manager, user):
    """Test pUSD deposit functionality"""
    amount = 1000000000000000000  # 1 WETH
    
    # User deposits WETH
    tx = pusd_manager.deposit(
        recipient=b"0x1234",
        amount=amount,
        sender=user,
        value=amount
    )
    
    # Verify deposit event
    assert tx.events[0].sender == user.address
    assert tx.events[0].amount == amount

def test_withdraw(pusd_manager, owner):
    """Test pUSD withdrawal functionality"""
    # Mock compass call
    pusd_manager.withdraw(
        sender=b"0x1234",
        recipient=owner.address,
        amount=1000000000000000000,
        nonce=1,
        sender=owner
    )
```

## Deployment

### Mainnet Deployment

1. **Configure Environment**:
   ```bash
   export PRIVATE_KEY="your_private_key"
   export ALCHEMY_API_KEY="your_alchemy_key"
   ```

2. **Deploy Contracts**:
   ```bash
   ape run scripts/deploy.py --network ethereum:mainnet:alchemy
   ```

### Testnet Deployment

```bash
ape run scripts/deploy.py --network ethereum:goerli:alchemy
```

## Contributing

We welcome contributions to enhance the pUSD Manager Vyper contract. To contribute:

1. **Fork the Repository**: Click on the 'Fork' button at the top right corner of this page.
2. **Create a New Branch**: Use a descriptive name for your branch.
3. **Make Your Changes**: Implement your feature or fix.
4. **Add Tests**: Ensure all new functionality has corresponding tests.
5. **Submit a Pull Request**: Provide a clear description of your changes and the problem they solve.

Please ensure that your contributions adhere to our coding standards and include appropriate tests.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgements

We extend our gratitude to the VolumeFi community and all contributors who have supported the development of the pUSD Manager Vyper contract.

---

This README provides comprehensive documentation for security auditors, including detailed function descriptions, security considerations, usage examples, and testing instructions. For more detailed information about specific implementations, please refer to the contract source code. 