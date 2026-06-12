// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

/// @title Uniswap V3 池部署器
/// @notice 负责使用 CREATE2 操作码部署 Uniswap V3 交易池合约
/// @dev 这是一个 mixin 合约，被 UniswapV3Factory 继承，提供池部署的核心逻辑
/// 关键特性：使用临时存储槽传递参数，实现无构造函数的池部署，确保池地址的确定性
contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    /// @notice 池部署参数的结构体
    /// @dev 在部署池时，这些参数被临时写入存储槽，池构造函数读取后清除
    /// 这种模式避免了构造函数参数的使用，使得池字节码完全确定
    struct Parameters {
        /// @notice 工厂合约地址
        address factory;
        /// @notice 交易对的第一个代币地址（按地址大小排序后较小的）
        address token0;
        /// @notice 交易对的第二个代币地址（按地址大小排序后较大的）
        address token1;
        /// @notice 交易费率（以基点的百分之一为单位，即 1e-6）
        uint24 fee;
        /// @notice tick 间距（决定流动性提供者可使用的 tick 间隔）
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    /// @notice 临时存储池部署参数的结构体
    /// @dev 在部署过程中被写入，部署完成后立即清除（delete parameters）
    /// 这是一个存储槽，而非 immutable 变量，因为每次部署都需要不同的值
    Parameters public override parameters;

    /// @notice 部署一个新的 Uniswap V3 交易池
    /// @dev 核心部署逻辑：
    /// 1. 将参数写入临时存储槽（parameters）
    /// 2. 使用 CREATE2 操作码部署新池（salt 由 token0, token1, fee 的哈希确定）
    /// 3. 池的构造函数通过 IUniswapV3PoolDeployer(msg.sender).parameters() 读取参数
    /// 4. 部署完成后清除临时参数
    ///
    /// CREATE2 的优势：
    /// - 池地址完全确定性：仅取决于部署者地址、salt 和池字节码
    /// - 可以在池部署前预计算其地址
    /// - 对于相同的 (token0, token1, fee) 组合，总是产生相同的地址
    ///
    /// @param factory Uniswap V3 工厂合约地址
    /// @param token0 交易对的第一个代币地址（按地址排序后较小的）
    /// @param token1 交易对的第二个代币地址（按地址排序后较大的）
    /// @param fee 交易费率（以基点的百分之一为单位，即 1e-6）
    /// @param tickSpacing 可用的 tick 之间的间距
    /// @return pool 新部署的池合约地址
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 第一步：将部署参数写入临时存储槽
        // 这些参数将被池的构造函数读取
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});

        // 第二步：使用 CREATE2 操作码部署新的 UniswapV3Pool 合约
        // salt = keccak256(abi.encode(token0, token1, fee))
        // 这确保了对于相同的 (token0, token1, fee) 组合，总是产生相同的池地址
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());

        // 第三步：清除临时参数，释放存储槽
        // 这是必要的安全措施，防止参数残留
        delete parameters;
    }
}
