// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0;

import '../interfaces/IERC20Minimal.sol';

/// @title 代币转账辅助库
/// @notice 包含与 ERC20 代币交互的辅助方法，处理那些不一致返回 true/false 的代币
/// @dev 某些 ERC20 代币的 transfer 函数不返回布尔值（或返回空数据），本库通过检查返回数据来兼容这些代币
///
/// 设计动机：
/// - ERC20 标准要求 transfer 返回 bool，但部分代币（如 USDT）不遵循
/// - 使用 call 而非 transfer 函数，允许更灵活的返回值处理
/// - 兼容所有 ERC20 代币实现
///
/// 使用场景：
/// - UniswapV3Pool 中的 flash 函数（转出代币）
/// - UniswapV3Pool 中的 collect/collectProtocol 函数（提取代币）
library TransferHelper {
    /// @notice 从 msg.sender 转账代币到接收者
    /// @dev 调用代币合约的 transfer 函数，如果转账失败将 revert（错误代码 'TF'）
    ///
    /// 兼容性检查：
    /// - 如果 transfer 返回空数据：视为成功（兼容 USDT 等代币）
    /// - 如果 transfer 返回布尔值：检查是否为 true
    /// - 如果 call 本身失败：revert
    ///
    /// 工作流程：
    /// 1. 使用 abi.encodeWithSelector 编码 transfer 函数调用
    /// 2. 通过 call 执行转账（而非直接调用 transfer）
    /// 3. 检查 call 是否成功
    /// 4. 检查返回数据：空数据或 true 都视为成功
    ///
    /// 错误代码：
    /// - 'TF'：Transfer Failed（转账失败）
    ///
    /// @param token 代币合约地址
    /// @param to 转账接收者地址
    /// @param value 转账数量
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, value));
        // 成功条件：call 成功 且（返回数据为空 或 返回数据解码为 true）
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TF');
    }
}
