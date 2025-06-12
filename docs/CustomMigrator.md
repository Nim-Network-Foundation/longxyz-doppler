# Uniswap v3 & v2 Custom Migrator

`CustomUniswapV3Migrator.sol` and `CustomLPUniswapV2Migrator.sol` are contracts that are built on top of Doppler protocol as extensions to support additional features such as enabling real-time fee streaming and custom distribution on LP share after token migration.

Both of them have their own Locker contract(`CustomUniswapV3Locker.sol` & `CustomLPUniswapV2Locker.sol`) to escrow the LP for a fixed period of time based on respective configuration.

## Uniswap v3 Custom Migrator

### High-level Explanation

1. Users launch new token via Airlock's `create`, a Uniswap v4 pool with Doppler hook attached will be created via Initializer, and a Uniswap v3 pool for WETH <> token will be craeted via Custom v3 Migrator, and initialized with min/max tick
2. Token sale in v4 pool will start and end according to the time set in Doppler hook, other people will buy the token with ETH or sell the token to get ETH in return as usual
3. The trading continues, until either one of the conditions is fulfilled - `[block.timestamp >= ending time set in Doppler hook]` OR `[total proceeds >= maximum proceeds set in Doppler hook]`
4. Call Airlock's `migrate` as long as the minimum proceed is reached after sale ends
5. Custom v3 migrator calculates and migrates the most amount of liquidity it can send to the v3 pool for both ETH & token at the final price of the v4 pool, before sending the rest to the Timelock.
6. Once the liquidity is migrated i.e. the NFT position for the LP is minted, it will be sent to the Custom v3 Locker contract and locked for 1 year
7. LP fees can be claimed via `harvest` continuously as long as there is fee generated from trading via the v3 pool, then distributed in 95% to the integrator and 5% to doppler

### Current Fee Distribution

- 95% to integrator fee receiver
- 5% to Doppler fee receiver

### Encoding `LiquidityMigratorData`

From `initialize` in `CustomUniswapV3Migrator.sol` we can see that `liquidityMigratorData` is encoded with one param(`integratorFeeReceiver`) in order to initialize successfully:

```solidity
function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        // ...
        (address integratorFeeReceiver) = abi.decode(liquidityMigratorData, (address));
        // ...
```

So for example if `0xAA25790C239B0Aa94A6A223B13C0b81D1E68942b` will be the `integratorFeeReceiver`, we could do something like this in Foundry chisel:

```solidity
abi.encode(0xAA25790C239B0Aa94A6A223B13C0b81D1E68942b)
```

We will get `0x000000000000000000000000aa25790c239b0aa94a6a223b13c0b81d1e68942b` in return.

Finally you will pass this byte as `liquidityMigratorData` during `create` on Airlock to enable the `CustomUniswapV3Migrator` extension.

### Fee Claim

To claim the LP fee we just need to call `harvest` on the deployed `CustomUniswapV3Locker.sol`, or make the fee claim automatic via cron job.

```solidity
(uint256 collectedAmount0, uint256 collectedAmount1) = BASE_CUSTOM_V3_LOCKER_CONTRACT.harvest(TOKEN_ID);
```

### Unlock LP

Full LP will be sent to the Locker contract and will be unlocked after 1 year.

Calling `unlock` will result in the full LP being sent to the timelock specified during `register` on `CustomUniswapV3Locker.sol`.

```solidity
BASE_CUSTOM_V3_LOCKER_CONTRACT.unlock(TOKEN_ID);
```

## Uniswap v2 Custom Migrator

From `initialize` in `CustomLPUniswapV2Migrator.sol` we can see that `liquidityMigratorData` is encoded with three params(`customLPWad`, `customLPRecipient`, `lockUpPeriod`) in order to initialize successfully:

```solidity
function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address) {
        // ...
        if (liquidityMigratorData.length > 0) {
            (customLPWad_, customLPRecipient_, lockUpPeriod_) =
                abi.decode(liquidityMigratorData, (uint64, address, uint32));
            // ...
```

### Encoding `LiquidityMigratorData`

In order to enable the usage of module, we will pass in this `liquidityMigratorData` along with other params when we call `create` on Airlock contract:

```solidity
struct CreateParams {
    uint256 initialSupply;
    uint256 numTokensToSell;
    address numeraire;
    ITokenFactory tokenFactory;
    bytes tokenFactoryData;
    IGovernanceFactory governanceFactory;
    bytes governanceFactoryData;
    IPoolInitializer poolInitializer;
    bytes poolInitializerData;
    ILiquidityMigrator liquidityMigrator;
    bytes liquidityMigratorData;
    address integrator;
    bytes32 salt;
}
```

The three params mentioned above will need to be abi-encoded as `liquidityMigratorData` with the following order:

1. `customLPWad` - % of the share (cannot exceed 5%, 1% = 1e16 or 0.01 ether),
2. `customLPRecipient` - recipient address (has to be an EOA i.e. not smart contract, aware of EIP7702 but only check initial address passed)
3. `lockUpPeriod` - lockup period (duration of the lock, in seconds)

So for example we want to unlock **2% of LP for `0xAA25790C239B0Aa94A6A223B13C0b81D1E68942b` after 3 months i.e. 90days**, we could do something like this in Foundry chisel:

```solidity
abi.encode(2e16, 0xAA25790C239B0Aa94A6A223B13C0b81D1E68942b, 7776000)
```

The resulting liquidityMigratorData will be `0x00000000000000000000000000000000000000000000000000470de4df820000000000000000000000000000aa25790c239b0aa94a6a223b13c0b81d1e68942b000000000000000000000000000000000000000000000000000000000076a700`.

Finally you will pass this byte as `liquidityMigratorData` during `create` on Airlock to enable the `CustomLPUniswapV2Migrator` extension.

### Unlock LP

Certain %(specified from `customLPWad`) of LP will be sent to the Locker contract and will be unlocked after 30 days or longer depending on the `lockUpPeriod` passed.

Calling `claimFeesAndExit` will result in this locked LP being sent to the timelock specified during `receiveAndLock` on `CustomLPUniswapV2Locker.sol`, and all the LP fee being sent to the owner of Locker contract.

```solidity
BASE_CUSTOM_V2_LOCKER_CONTRACT.claimFeesAndExit(V2_POOL_ADDRESS);
```
