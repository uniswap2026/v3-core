// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

/// @title Uniswap V3 核心交易池合约
/// @notice 实现集中流动性 AMM 的核心功能，包括流动性管理、交易、闪电贷和预言机
/// @dev 继承自 IUniswapV3Pool 接口和 NoDelegateCall（防止委托调用）
///
/// 核心概念：
/// - 集中流动性：流动性提供者可以在特定价格范围内提供流动性，提高资本效率
/// - Tick 系统：将连续价格离散化为 tick，每个 tick 代表一个特定的价格点
/// - 虚拟流动性：通过 tick 上的流动性净额（liquidityNet）追踪流动性变化
///
/// 主要功能：
/// - mint: 创建流动性头寸
/// - burn: 销毁流动性头寸
/// - swap: 在两个代币之间进行交易
/// - flash: 闪电贷功能
/// - observe: 读取预言机数据（TWAP）
contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    // 使用库扩展类型功能
    using LowGasSafeMath for uint256;      // 低 gas 安全算术（uint256）
    using LowGasSafeMath for int256;       // 低 gas 安全算术（int256）
    using SafeCast for uint256;            // 安全的类型转换（uint256）
    using SafeCast for int256;             // 安全的类型转换（int256）
    using Tick for mapping(int24 => Tick.Info);           // tick 状态管理
    using TickBitmap for mapping(int16 => uint256);       // tick 位图导航
    using Position for mapping(bytes32 => Position.Info); // 头寸管理
    using Position for Position.Info;                     // 头寸操作
    using Oracle for Oracle.Observation[65535];           // 预言机操作

    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 创建此池的工厂合约地址
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 交易对中地址较小的代币（按地址大小排序）
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 交易对中地址较大的代币（按地址大小排序）
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 交易费率（以基点的百分之一为单位，即 1e-6）
    /// @dev 例如：3000 = 0.3%，500 = 0.05%
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice tick 间距，决定流动性提供者可使用的 tick 间隔
    /// @dev 由工厂合约根据费率档位确定
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 每个 tick 允许的最大流动性
    /// @dev 用于防止单个 tick 的流动性溢出
    uint128 public immutable override maxLiquidityPerTick;

    /// @notice Slot0 结构体：存储池的核心状态变量
    /// @dev 这些变量被打包到一个存储槽中，以优化 gas 成本
    struct Slot0 {
        /// @notice 当前价格的平方根（Q64.96 定点数格式）
        /// @dev sqrtPriceX96 = sqrt(price) * 2^96，其中 price = token1/token0
        uint160 sqrtPriceX96;
        /// @notice 当前 tick，对应当前价格的离散化表示
        /// @dev tick = log(sqrt(price)) / log(sqrt(1.0001))
        int24 tick;
        /// @notice 观察数组中最近一次更新的索引
        /// @dev 用于预言机（TWAP）的环形缓冲区管理
        uint16 observationIndex;
        /// @notice 当前存储的观察点数量
        /// @dev 环形缓冲区的当前容量
        uint16 observationCardinality;
        /// @notice 下一次观察点数量的目标值
        /// @dev 在 observations.write 中触发扩容
        uint16 observationCardinalityNext;
        /// @notice 当前协议费用（作为交易费的一定比例）
        /// @dev 低 4 位表示 token0 的协议费用分母，高 4 位表示 token1 的协议费用分母
        /// 值为 0 表示无协议费用，非零值 n 表示费用比例为 1/n
        uint8 feeProtocol;
        /// @notice 池是否处于解锁状态（用于重入保护）
        /// @dev true = 可以调用状态变更函数，false = 函数被锁定
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 池的核心状态槽
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice token0 的全局手续费增长累加器（Q128 定点数）
    /// @dev 用于计算流动性提供者的应得手续费
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    /// @notice token1 的全局手续费增长累加器（Q128 定点数）
    uint256 public override feeGrowthGlobal1X128;

    /// @notice 协议费用累加器结构体
    /// @dev 记录池累积的协议费用（以 token0 和 token1 为单位）
    struct ProtocolFees {
        /// @notice 以 token0 计价的累积协议费用
        uint128 token0;
        /// @notice 以 token1 计价的累积协议费用
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 池累积的协议费用
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice 当前价格范围内的可用流动性
    /// @dev 仅在 swap 和 mint/burn 影响当前 tick 范围时更新
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice tick 信息映射
    /// @dev 键为 tick 索引（int24），值为 Tick.Info 结构体（包含流动性净额、手续费累加器等）
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    /// @notice tick 位图，用于高效查找已初始化的 tick
    /// @dev 键为 int16（word 索引），值为 uint256（位图，每一位代表一个 tick 间距倍数）
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 流动性头寸映射
    /// @dev 键为 keccak256(owner, tickLower, tickUpper)，值为 Position.Info 结构体
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 预言机观察数组（环形缓冲区）
    /// @dev 最多存储 65535 个观察点，每个观察点包含时间戳、tick 累加值和 secondsPerLiquidity 累加值
    Oracle.Observation[65535] public override observations;

    /// @notice 互斥重入保护修饰器
    /// @dev 防止在函数执行期间重新进入池的任何方法
    /// 此修饰器还防止在池初始化之前调用函数
    ///
    /// 为什么需要重入保护：
    /// - mint、swap、flash 等操作通过余额比较来验证支付
    /// - 如果允许重入，攻击者可能在支付验证前操纵余额
    ///
    /// 工作原理：
    /// 1. 检查 slot0.unlocked 是否为 true
    /// 2. 将 unlocked 设为 false，锁定池
    /// 3. 执行函数体
    /// 4. 将 unlocked 恢复为 true，解锁池
    modifier lock() {
        require(slot0.unlocked, 'LOK');  // 确保池当前未被锁定
        slot0.unlocked = false;           // 锁定池
        _;                                // 执行被修饰的函数
        slot0.unlocked = true;            // 解锁池
    }

    /// @notice 仅限工厂所有者调用的修饰器
    /// @dev 确保只有工厂合约的所有者可以调用被修饰的函数
    /// 用于保护需要管理员权限的操作（如设置协议费用、提取协议费用）
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    /// @notice 构造函数，从部署器读取池参数并初始化
    /// @dev 使用 UniswapV3PoolDeployer 的临时参数模式：
    /// - 工厂合约调用 deploy() 时，先将参数写入 parameters 存储槽
    /// - 然后使用 CREATE2 部署本合约
    /// - 本构造函数通过 IUniswapV3PoolDeployer(msg.sender).parameters() 读取参数
    /// - 部署完成后，工厂清除临时参数
    ///
    /// 这种设计使得池合约没有构造函数参数，字节码完全确定
    constructor() {
        int24 _tickSpacing;
        // 从部署器读取参数（factory, token0, token1, fee, tickSpacing）
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        // 根据 tick 间距计算每个 tick 允许的最大流动性
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @notice 验证 tick 输入参数的通用检查
    /// @dev 确保 tickLower < tickUpper 且都在有效范围内
    /// @param tickLower 下界 tick 索引
    /// @param tickUpper 上界 tick 索引
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');           // 下界必须小于上界
        require(tickLower >= TickMath.MIN_TICK, 'TLM');  // 下界不能低于最小 tick
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');  // 上界不能超过最大 tick
    }

    /// @notice 获取当前区块时间戳（截断为 32 位）
    /// @dev 返回 block.timestamp mod 2^32，截断是有意为之
    /// 此方法在测试中被重写（MockTimeUniswapV3Pool），以支持时间推进
    /// @return 截断后的 32 位时间戳
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // 截断是必需的
    }

    /// @notice 获取池中 token0 的余额
    /// @dev 使用 staticcall 而非普通调用，避免状态修改
    /// 此函数经过 gas 优化，避免了冗余的 extcodesize 检查
    /// @return token0 的余额
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @notice 获取池中 token1 的余额
    /// @dev 与 balance0 类似的 gas 优化实现
    /// @return token1 的余额
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 获取指定 tick 范围内的 tick 累加值和 secondsPerLiquidity 累加值
    /// @dev 用于计算特定价格范围内的 TWAP（时间加权平均价格）
    /// @param tickLower 范围下界 tick
    /// @param tickUpper 范围上界 tick
    /// @return tickCumulativeInside 范围内的 tick 累加值
    /// @return secondsPerLiquidityInsideX128 范围内的 secondsPerLiquidity 累加值（Q128）
    /// @return secondsInside 范围内经过的秒数
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        // 验证 tick 范围的有效性
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        // 从存储中读取下界和上界 tick 的累加器数据
        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);  // 确保下界 tick 已初始化

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);  // 确保上界 tick 已初始化
        }

        Slot0 memory _slot0 = slot0;

        // 根据当前 tick 的位置，计算范围内的累加值
        // 有三种情况：当前 tick 在范围下方、范围内、范围上方
        if (_slot0.tick < tickLower) {
            // 当前 tick 在范围下方：范围内的累加值 = 下界 outside - 上界 outside
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            // 当前 tick 在范围内：需要从预言机获取当前累加值
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            // 范围内的累加值 = 当前累加值 - 下界 outside - 上界 outside
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            // 当前 tick 在范围上方：范围内的累加值 = 上界 outside - 下界 outside
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 查询历史预言机数据（时间加权平均值）
    /// @dev 返回指定时间前的 tick 累加值和 secondsPerLiquidity 累加值
    /// 用于计算 TWAP（时间加权平均价格）和流动性加权时间
    /// @param secondsAgos 查询的时间点数组（每个元素表示距今多少秒）
    /// @return tickCumulatives 对应时间点的 tick 累加值数组
    /// @return secondsPerLiquidityCumulativeX128s 对应时间点的 secondsPerLiquidity 累加值数组
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 增加预言机观察数组的容量
    /// @dev 任何人都可以调用此函数来扩容预言机，以便存储更多的历史数据
    /// 扩容操作需要 gas 成本，但可以增加预言机的精度
    /// @param observationCardinalityNext 新的目标容量（必须大于当前值）
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // 用于事件
        // 调用 Oracle 库的 grow 函数进行扩容
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        // 更新 slot0 中的目标容量
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        // 如果容量确实增加了，发出事件
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 初始化池的起始价格和预言机
    /// @dev 此函数不需要 lock 修饰器，因为它在初始化时将 unlocked 设为 true
    /// 只能在池创建后调用一次（通过检查 sqrtPriceX96 == 0 确保）
    /// @param sqrtPriceX96 初始价格的平方根（Q64.96 格式）
    function initialize(uint160 sqrtPriceX96) external override {
        // 确保池尚未初始化
        require(slot0.sqrtPriceX96 == 0, 'AI');

        // 根据初始价格计算对应的 tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // 初始化预言机观察数组（设置初始时间戳）
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        // 设置 slot0 的初始状态
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,      // 初始价格
            tick: tick,                      // 初始 tick
            observationIndex: 0,             // 观察索引从 0 开始
            observationCardinality: cardinality,      // 当前观察容量
            observationCardinalityNext: cardinalityNext, // 目标观察容量
            feeProtocol: 0,                 // 初始无协议费用
            unlocked: true                   // 解锁池，允许后续操作
        });

        // 发出初始化事件
        emit Initialize(sqrtPriceX96, tick);
    }

    /// @notice 修改头寸的参数结构体
    /// @dev 用于 _modifyPosition 函数的内部参数传递
    struct ModifyPositionParams {
        /// @notice 头寸的所有者地址
        address owner;
        /// @notice 头寸的下界 tick
        int24 tickLower;
        /// @notice 头寸的上界 tick
        int24 tickUpper;
        /// @notice 流动性变化量（正数表示增加，负数表示减少）
        int128 liquidityDelta;
    }

    /// @notice 修改流动性头寸的内部函数
    /// @dev 核心逻辑：
    /// 1. 验证 tick 范围
    /// 2. 更新 tick 状态（流动性净额、位图等）
    /// 3. 根据当前价格与头寸范围的关系，计算需要支付的代币数量
    /// 4. 如果当前价格在范围内，更新预言机
    ///
    /// @param params 头寸修改参数
    /// @return position 头寸的存储指针
    /// @return amount0 需要支付给池的 token0 数量（负数表示池支付给接收者）
    /// @return amount1 需要支付给池的 token1 数量（负数表示池支付给接收者）
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        // 验证 tick 范围的有效性
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD 优化：将 slot0 加载到内存

        // 更新头寸状态（tick 状态、位图、手续费累加器）
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        // 如果流动性有变化，计算需要支付的代币数量
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // 情况 1：当前 tick 低于头寸范围
                // 流动性只能通过价格从左向右移动（token0 变得更贵）进入范围
                // 因此用户必须提供 token0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // 情况 2：当前 tick 在头寸范围内
                // 需要同时提供 token0 和 token1
                uint128 liquidityBefore = liquidity; // SLOAD 优化

                // 写入预言机观察点
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算 token0 需要量（从当前价格到上界）
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // 计算 token1 需要量（从下界到当前价格）
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新当前可用流动性
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // 情况 3：当前 tick 高于头寸范围
                // 流动性只能通过价格从右向左移动（token1 变得更贵）进入范围
                // 因此用户必须提供 token1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @notice 更新头寸状态（tick 状态、位图、手续费累加器）
    /// @dev 内部函数，被 _modifyPosition 调用
    /// @param owner 头寸所有者地址
    /// @param tickLower 下界 tick
    /// @param tickUpper 上界 tick
    /// @param liquidityDelta 流动性变化量
    /// @param tick 当前 tick（传入以避免重复 SLOAD）
    /// @return position 头寸的存储指针
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取头寸存储指针
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD 优化
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD 优化

        // 如果流动性有变化，更新 tick 状态
        bool flippedLower;  // 下界 tick 是否翻转（从非初始化变为初始化，或反之）
        bool flippedUpper;  // 上界 tick 是否翻转
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            // 获取最新的预言机累加值
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新下界 tick 状态
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,  // false 表示这是下界
                maxLiquidityPerTick
            );
            // 更新上界 tick 状态
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,   // true 表示这是上界
                maxLiquidityPerTick
            );

            // 如果 tick 状态发生翻转，更新位图
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算头寸范围内已累积的手续费
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 更新头寸的流动性和应得手续费
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 如果流动性减少且 tick 被翻转（不再需要），清除 tick 数据
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 创建新的流动性头寸
    /// @dev noDelegateCall 通过 _modifyPosition 间接应用
    ///
    /// 工作流程：
    /// 1. 调用 _modifyPosition 更新头寸状态并计算需要支付的代币数量
    /// 2. 记录当前余额
    /// 3. 调用回调函数，让调用者支付代币
    /// 4. 验证支付是否完成（余额比较）
    ///
    /// @param recipient 头寸的接收者地址
    /// @param tickLower 头寸的下界 tick
    /// @param tickUpper 头寸的上界 tick
    /// @param amount 要添加的流动性数量（必须大于 0）
    /// @param data 传递给回调函数的任意数据
    /// @return amount0 实际支付的 token0 数量
    /// @return amount1 实际支付的 token1 数量
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        // 调用内部函数修改头寸状态
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()  // 流动性增加为正数
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 记录支付前的余额
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // 调用回调函数，让调用者支付代币
        // 调用者必须实现 IUniswapV3MintCallback 接口
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        // 验证支付是否完成（余额必须增加至少所需的数量）
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        // 发出 mint 事件
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 提取头寸累积的手续费
    /// @dev 任何人都可以调用此函数来提取特定头寸的应得手续费
    /// 实际提取的金额不能超过头寸累积的手续费
    /// @param recipient 手续费接收者地址
    /// @param tickLower 头寸的下界 tick
    /// @param tickUpper 头寸的上界 tick
    /// @param amount0Requested 请求提取的 token0 数量
    /// @param amount1Requested 请求提取的 token1 数量
    /// @return amount0 实际提取的 token0 数量
    /// @return amount1 实际提取的 token1 数量
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // 不需要 checkTicks，因为无效头寸的 tokensOwed{0,1} 永远为 0
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 实际提取金额不能超过应得金额
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // 提取 token0
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        // 提取 token1
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        // 发出 collect 事件
        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 销毁流动性头寸，回收底层代币
    /// @dev noDelegateCall 通过 _modifyPosition 间接应用
    ///
    /// 工作流程：
    /// 1. 调用 _modifyPosition 减少流动性并计算可回收的代币数量
    /// 2. 更新头寸的应得代币数量
    /// 3. 调用 collect 函数实际提取代币
    ///
    /// @param tickLower 头寸的下界 tick
    /// @param tickUpper 头寸的上界 tick
    /// @param amount 要销毁的流动性数量
    /// @return amount0 可回收的 token0 数量
    /// @return amount1 可回收的 token1 数量
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 调用内部函数减少流动性
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()  // 流动性减少为负数
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // 如果有可回收的代币，增加头寸的应得代币数量
        // 实际提取需要通过 collect 函数完成
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        // 发出 burn 事件
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Swap 缓存结构体
    /// @dev 用于 swap 函数中的临时变量存储，避免重复读取存储
    struct SwapCache {
        /// @notice 输入代币的协议费用（以 1/n 形式表示）
        /// @dev 从 slot0.feeProtocol 中提取，低 4 位或高 4 位取决于方向
        uint8 feeProtocol;
        /// @notice swap 开始时的流动性
        /// @dev 在整个 swap 过程中保持不变，用于计算手续费分配
        uint128 liquidityStart;
        /// @notice 当前区块的时间戳
        uint32 blockTimestamp;
        /// @notice tick 累加器的当前值
        /// @dev 仅在跨越初始化 tick 时计算并缓存
        int56 tickCumulative;
        /// @notice secondsPerLiquidity 累加器的当前值
        /// @dev 仅在跨越初始化 tick 时计算并缓存
        uint160 secondsPerLiquidityCumulativeX128;
        /// @notice 是否已计算并缓存上述两个累加器
        /// @dev 用于避免重复计算
        bool computedLatestObservation;
    }

    /// @notice Swap 状态结构体
    /// @dev 记录 swap 过程中的顶层状态，最终写回存储
    struct SwapState {
        /// @notice 剩余需要交换的输入/输出数量
        /// @dev 正数表示精确输入模式，负数表示精确输出模式
        int256 amountSpecifiedRemaining;
        /// @notice 已计算出的输出/输入数量
        int256 amountCalculated;
        /// @notice 当前的 sqrt(price)
        uint160 sqrtPriceX96;
        /// @notice 当前价格对应的 tick
        int24 tick;
        /// @notice 输入代币的全局手续费增长累加器
        uint256 feeGrowthGlobalX128;
        /// @notice 已支付的协议手续费（输入代币计价）
        uint128 protocolFee;
        /// @notice 当前价格范围内的流动性
        uint128 liquidity;
    }

    /// @notice 单步计算结构体
    /// @dev 用于 swap 循环中每一步的临时计算
    struct StepComputations {
        /// @notice 步骤开始时的价格
        uint160 sqrtPriceStartX96;
        /// @notice 当前 tick 方向上的下一个初始化 tick
        int24 tickNext;
        /// @notice tickNext 是否已初始化（有流动性提供者设置过头寸边界）
        bool initialized;
        /// @notice 下一个 tick 对应的价格
        uint160 sqrtPriceNextX96;
        /// @notice 本步骤中输入的代币数量
        uint256 amountIn;
        /// @notice 本步骤中输出的代币数量
        uint256 amountOut;
        /// @notice 本步骤中支付的手续费
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 在两个代币之间执行交换操作
    /// @dev 这是 Uniswap V3 的核心交易函数，实现了集中流动性 AMM 的交易逻辑
    ///
    /// 算法概述：
    /// 1. 初始化 swap 状态和缓存
    /// 2. 进入 while 循环，直到输入耗尽或达到价格限制：
    ///    a. 使用位图找到下一个初始化 tick
    ///    b. 计算本步骤的价格变动和数量
    ///    c. 更新 swap 状态（剩余数量、已计算数量、手续费等）
    ///    d. 如果到达下一个 tick，执行 tick 转换（更新流动性、手续费累加器）
    /// 3. 更新 slot0（价格、tick、预言机）
    /// 4. 更新流动性（如果跨越了 tick）
    /// 5. 更新全局手续费和协议费用
    /// 6. 调用回调函数，让调用者支付代币
    /// 7. 验证支付是否完成（余额比较）
    ///
    /// 关键特性：
    /// - 支持精确输入和精确输出两种模式（由 amountSpecified 的正负决定）
    /// - 价格限制保护（sqrtPriceLimitX96）
    /// - 手续费分配给当前价格范围内的流动性提供者
    /// - 协议费用（如果启用）
    ///
    /// @param recipient 输出代币的接收者地址
    /// @param zeroForOne 交易方向：true = token0 -> token1，false = token1 -> token0
    /// @param amountSpecified 指定的交易数量：正数 = 精确输入，负数 = 精确输出
    /// @param sqrtPriceLimitX96 价格限制（Q64.96 格式）：交易不会超过此价格
    /// @param data 传递给回调函数的任意数据
    /// @return amount0 token0 的变化量（正数表示输入，负数表示输出）
    /// @return amount1 token1 的变化量（正数表示输入，负数表示输出）
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        // 交易数量不能为零
        require(amountSpecified != 0, 'AS');

        // 读取当前 slot0 状态到内存
        Slot0 memory slot0Start = slot0;

        // 确保池未被锁定（防止重入）
        require(slot0Start.unlocked, 'LOK');
        // 验证价格限制的方向和范围
        // zeroForOne: 价格下降，所以限制价格必须低于当前价格且高于最小可能价格
        // oneForZero: 价格上升，所以限制价格必须高于当前价格且低于最大可能价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        // 锁定池，防止重入
        slot0.unlocked = false;

        // 初始化 swap 缓存
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity,           // 记录初始流动性
                blockTimestamp: _blockTimestamp(),   // 当前时间戳
                // 根据方向提取对应的协议费用（低 4 位或高 4 位）
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        // 判断交易模式：正数 = 精确输入，负数 = 精确输出
        bool exactInput = amountSpecified > 0;

        // 初始化 swap 状态
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,  // 剩余需要处理的数量
                amountCalculated: 0,                        // 已计算出的数量
                sqrtPriceX96: slot0Start.sqrtPriceX96,      // 当前价格
                tick: slot0Start.tick,                      // 当前 tick
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128, // 对应代币的全局手续费
                protocolFee: 0,                             // 累积的协议费用
                liquidity: cache.liquidityStart             // 当前流动性
            });

        // 主 swap 循环：继续交换直到输入/输出耗尽或达到价格限制
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            // 记录本步骤的起始价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // 使用位图找到当前 tick 方向上的下一个初始化 tick
            // zeroForOne: 向左（tick 减小），oneForZero: 向右（tick 增加）
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // 确保不超出 tick 的最小/最大范围
            // 位图本身不知道这些边界，需要手动限制
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取下一个 tick 对应的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算本步骤的交易结果
            // 目标价格 = min(下一个 tick 的价格, 价格限制)
            // 返回：新的价格、输入数量、输出数量、手续费
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            // 根据交易模式更新 swap 状态
            if (exactInput) {
                // 精确输入模式：减少剩余输入，累加输出
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 精确输出模式：增加已获得的输出，累加所需输入
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // 如果启用了协议费用，计算协议应得的部分
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;              // 手续费中扣除协议费用
                state.protocolFee += uint128(delta);  // 累加到协议费用
            }

            // 更新全局手续费追踪器
            // 只有当前流动性大于 0 时才更新（避免除以 0）
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // 如果到达了下一个 tick 的价格，执行 tick 转换
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 如果该 tick 已初始化，执行 tick 转换逻辑
                if (step.initialized) {
                    // 检查占位值：第一次跨越初始化 tick 时用实际值替换
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // 调用 Tick.cross 执行 tick 转换
                    // 返回流动性净额（liquidityNet），用于更新当前流动性
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // 如果向左移动（zeroForOne），将 liquidityNet 取反
                    // 安全原因：liquidityNet 不可能是 type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // 更新当前流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // 更新 tick（如果是向左移动，tick 减 1；向右移动则使用 tickNext）
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 如果价格发生变化但未到达下一个 tick，重新计算 tick
                // 例外：如果在 tick 下界（已经转换过 tick）且价格未变，则不需要重新计算
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 如果 tick 发生变化，更新 tick 并写入预言机
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // 否则只更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果流动性发生变化，更新流动性状态
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // 更新全局手续费增长和协议费用（如果需要）
        // 注意：溢出是可接受的，协议必须在达到 type(uint128).max 之前提取费用
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 计算最终的 amount0 和 amount1
        // 根据交易方向和模式确定输入/输出数量
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // 执行转账并收集支付
        if (zeroForOne) {
            // token0 -> token1：先转出 token1，再让调用者支付 token0
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            // 调用回调函数，让调用者支付 token0
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 验证 token0 支付是否完成
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            // token1 -> token0：先转出 token0，再让调用者支付 token1
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            // 调用回调函数，让调用者支付 token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 验证 token1 支付是否完成
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        // 发出 swap 事件
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        // 解锁池
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 执行闪电贷，借出代币并在同一交易中归还
    /// @dev 任何人都可以调用此函数来借出代币，只要在同一交易中归还本金 + 手续费
    ///
    /// 工作流程：
    /// 1. 验证池有足够的流动性
    /// 2. 计算手续费
    /// 3. 记录当前余额
    /// 4. 转出代币给接收者
    /// 5. 调用回调函数，让调用者执行操作
    /// 6. 验证余额是否增加至少手续费的数量
    /// 7. 计算实际支付的金额
    /// 8. 分配协议费用（如果启用）和流动性提供者手续费
    ///
    /// @param recipient 借出代币的接收者地址
    /// @param amount0 借出的 token0 数量
    /// @param amount1 借出的 token1 数量
    /// @param data 传递给回调函数的任意数据
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        // 池必须有流动性才能执行闪电贷
        require(_liquidity > 0, 'L');

        // 计算手续费（向上取整，保护流动性提供者）
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        // 记录借出前的余额
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // 转出代币给接收者（如果数量大于 0）
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // 调用回调函数，让调用者执行操作
        // 调用者必须实现 IUniswapV3FlashCallback 接口，并在回调中归还本金 + 手续费
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        // 验证余额是否足够（至少增加了手续费的数量）
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // 计算实际支付的金额（减去是安全的，因为已知余额增加至少为手续费）
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        // 分配 token0 的手续费
        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;  // token0 的协议费用分母
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;  // 协议应得部分
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);  // 累加到协议费用
            // 剩余部分分配给流动性提供者（通过全局手续费增长）
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        // 分配 token1 的手续费
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;  // token1 的协议费用分母
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;  // 协议应得部分
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);  // 累加到协议费用
            // 剩余部分分配给流动性提供者
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        // 发出 flash 事件
        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    /// @notice 设置池的协议费用
    /// @dev 只有工厂所有者可以调用此函数
    /// 协议费用是交易费的一定比例，分配给协议（而非流动性提供者）
    ///
    /// @param feeProtocol0 token0 的协议费用分母（0 表示无费用，4-10 表示 1/4 到 1/10）
    /// @param feeProtocol1 token1 的协议费用分母（0 表示无费用，4-10 表示 1/4 到 1/10）
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        // 验证费用参数的有效性
        // 值为 0 表示禁用协议费用，或必须在 4-10 范围内
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        // 将两个 4 位值打包到一个 uint8 中
        // 低 4 位：token0 的协议费用，高 4 位：token1 的协议费用
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        // 发出事件，包含旧值和新值
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    /// @notice 提取累积的协议费用
    /// @dev 只有工厂所有者可以调用此函数
    /// 实际提取的金额不能超过累积的协议费用
    ///
    /// @param recipient 费用接收者地址
    /// @param amount0Requested 请求提取的 token0 数量
    /// @param amount1Requested 请求提取的 token1 数量
    /// @return amount0 实际提取的 token0 数量
    /// @return amount1 实际提取的 token1 数量
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        // 实际提取金额不能超过累积金额
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        // 提取 token0
        if (amount0 > 0) {
            // 如果提取全部，减 1 以避免清零存储槽（节省 gas）
            if (amount0 == protocolFees.token0) amount0--;
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        // 提取 token1
        if (amount1 > 0) {
            // 如果提取全部，减 1 以避免清零存储槽（节省 gas）
            if (amount1 == protocolFees.token1) amount1--;
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        // 发出 collectProtocol 事件
        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
