// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Factory.sol';

import './UniswapV3PoolDeployer.sol';
import './NoDelegateCall.sol';

import './UniswapV3Pool.sol';

/// @title Uniswap V3 工厂合约（规范版本）
/// @notice 部署 Uniswap V3 交易池，并管理所有权和交易池协议费用的控制
/// @dev 继承自 IUniswapV3Factory 接口、UniswapV3PoolDeployer（负责池部署逻辑）和 NoDelegateCall（防止委托调用）
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall {
    /// @inheritdoc IUniswapV3Factory
    /// @notice 工厂合约的所有者地址，负责管理权限操作（如设置协议费用、启用新的费率档位）
    address public override owner;

    /// @inheritdoc IUniswapV3Factory
    /// @notice 费率档位到 tick 间距的映射
    /// @dev 键为费率（以基点的百分之一为单位，即 1e-6），值为对应的 tick 间距
    /// 例如：fee=3000（0.3%）对应 tickSpacing=60
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IUniswapV3Factory
    /// @notice 根据两个代币地址和费率获取对应的池地址
    /// @dev 三层映射：token0 => token1 => fee => pool 地址
    /// 注意：token0 和 token1 按地址大小排序，确保唯一性
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    /// @notice 构造函数，初始化工厂所有者和默认费率档位
    /// @dev 在构造函数中：
    /// 1. 将部署者设为初始所有者
    /// 2. 启用三个默认费率档位及其对应的 tick 间距：
    ///    - 500 (0.05%) => tick 间距 10（适合稳定币对）
    ///    - 3000 (0.3%) => tick 间距 60（适合大多数交易对）
    ///    - 10000 (1%) => tick 间距 200（适合波动性较大的交易对）
    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 创建一个新的 Uniswap V3 交易池
    /// @dev 使用 CREATE2 操作码部署池，确保池地址的确定性
    /// @param tokenA 交易对的第一个代币地址（无需排序）
    /// @param tokenB 交易对的第二个代币地址（无需排序）
    /// @param fee 交易费率（以基点的百分之一为单位，即 1e-6）
    /// @return pool 新创建的池合约地址
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        // 确保两个代币地址不同
        require(tokenA != tokenB);
        // 按地址大小排序，确保 token0 < token1（这是 Uniswap V3 的标准约定）
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 确保排序后的第一个代币不是零地址
        require(token0 != address(0));
        // 根据费率获取对应的 tick 间距
        int24 tickSpacing = feeAmountTickSpacing[fee];
        // 确保该费率档位已启用（tick 间距不为 0）
        require(tickSpacing != 0);
        // 确保该交易对 + 费率的池尚未存在
        require(getPool[token0][token1][fee] == address(0));
        // 调用部署器 mixin 中的 deploy 函数创建新池
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        // 将新池地址注册到映射中
        getPool[token0][token1][fee] = pool;
        // 同时在反方向注册映射，避免后续查询时需要比较地址大小
        getPool[token1][token0][fee] = pool;
        // 发出池创建事件，包含所有关键参数
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 转移工厂所有权
    /// @dev 只有当前所有者可以调用此函数
    /// @param _owner 新的所有者地址
    function setOwner(address _owner) external override {
        // 确保只有当前所有者可以转移所有权
        require(msg.sender == owner);
        // 发出所有权变更事件
        emit OwnerChanged(owner, _owner);
        // 更新所有者
        owner = _owner;
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 启用新的费率档位及其对应的 tick 间距
    /// @dev 只有所有者可以调用，允许添加自定义费率档位
    /// @param fee 费率（以基点的百分之一为单位，即 1e-6），必须小于 1,000,000（即小于 100%）
    /// @param tickSpacing 对应的 tick 间距，必须在 1 到 16383 之间
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        // 确保只有所有者可以调用
        require(msg.sender == owner);
        // 费率必须小于 1,000,000（即小于 100%）
        require(fee < 1000000);
        // tick 间距上限为 16384 的原因：
        // 防止 tickSpacing 过大导致 TickBitmap#nextInitializedTickWithinOneWord
        // 从有效 tick 溢出 int24 范围
        // 16384 个 tick 表示约 5 倍的价格变化（假设每个 tick 为 1 基点）
        require(tickSpacing > 0 && tickSpacing < 16384);
        // 确保该费率档位尚未启用（防止覆盖）
        require(feeAmountTickSpacing[fee] == 0);

        // 设置费率档位与 tick 间距的映射
        feeAmountTickSpacing[fee] = tickSpacing;
        // 发出费率启用事件
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
