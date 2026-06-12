// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

/// @title 防止委托调用（delegatecall）的基础合约
/// @notice 提供一个修饰器，用于防止子合约中的方法被委托调用
/// @dev 这是一个抽象合约，被 UniswapV3Pool 和 UniswapV3Factory 继承
///
/// 委托调用（delegatecall）的风险：
/// - 当合约 A 通过 delegatecall 调用合约 B 时，B 的代码在 A 的上下文中执行
/// - 这意味着 B 可以访问和修改 A 的存储、余额等
/// - 对于 Uniswap V3 的核心合约，这可能导致状态被恶意操纵
///
/// 本合约通过以下机制防止委托调用：
/// 1. 在构造函数中将当前合约地址存储为 immutable 变量（original）
/// 2. immutable 变量在部署时被内联到字节码中，无法在运行时修改
/// 3. 每次调用被修饰的函数时，检查 address(this) == original
/// 4. 如果是 delegatecall，address(this) 将是调用者的地址，而非原始部署地址，检查失败
contract NoDelegateCall {
    /// @notice 本合约的原始部署地址
    /// @dev 使用 private immutable 修饰符：
    /// - private：防止外部直接访问
    /// - immutable：值在构造函数中确定后不可更改，且会被内联到字节码中
    /// 这个地址用于检测当前调用是否为委托调用
    address private immutable original;

    /// @notice 构造函数，记录合约的原始部署地址
    /// @dev Immutable 变量在合约的初始化代码（init code）中计算，
    /// 然后被内联到部署后的字节码中。
    /// 换句话说，这个变量在运行时不会被改变，而是直接作为常量嵌入字节码。
    /// 这使得每次检查时的 gas 成本更低（不需要 SLOAD 操作）。
    constructor() {
        // 将当前合约地址（即部署时的地址）存储为 immutable
        original = address(this);
    }

    /// @notice 检查当前调用是否为委托调用
    /// @dev 使用 private 方法而非内联到修饰器中的原因：
    /// - 修饰器会被复制到每个使用它的函数中
    /// - 使用 immutable 意味着地址字节会被复制到每个使用修饰器的地方
    /// - 将检查逻辑提取到 private 方法中可以减少代码重复，降低合约大小
    ///
    /// 工作原理：
    /// - 在正常调用中，address(this) 返回当前合约的地址（与 original 相同）
    /// - 在 delegatecall 中，address(this) 返回调用者的地址（与 original 不同）
    /// - 因此，如果 address(this) != original，说明是 delegatecall
    function checkNotDelegateCall() private view {
        require(address(this) == original);
    }

    /// @notice 防止委托调用进入被修饰的方法
    /// @dev 这是一个修饰器（modifier），用于保护函数不被通过 delegatecall 方式执行
    /// 使用方法：在函数声明后添加 `noDelegateCall` 关键字
    /// 例如：function swap(...) external noDelegateCall { ... }
    ///
    /// 应用场景：
    /// - UniswapV3Pool 中的大多数状态变更函数（mint, burn, swap, flash 等）
    /// - UniswapV3Factory 中的 createPool 函数
    /// - 防止恶意合约通过 delegatecall 操纵池状态
    modifier noDelegateCall() {
        // 调用检查函数，如果是 delegatecall 将 revert
        checkNotDelegateCall();
        // 继续执行被修饰的函数体
        _;
    }
}
