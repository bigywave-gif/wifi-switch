import Foundation
import CoreWLAN

/// Authentication rejection needs user intervention, not repeated submission of the same secret.
/// EAPOL can also indicate certificate or access-policy problems; do not claim the password is wrong.
public func connectionRequiresCredentialReview(_ error: Error) -> Bool {
    if let storeError = error as? StoreError {
        switch storeError {
        case .missingUsername, .missingPassword: return true
        default: return false
        }
    }
    let failure = error as NSError
    guard failure.domain == CWErrorDomain else { return false }
    return [CWErr.cweapolErr, .cwChallengeFailureErr, .cwInvalidPMKErr]
        .contains { $0.rawValue == failure.code }
}

/// EAPOL failure is broader than an incorrect password; never assert a specific cause without evidence.
public func connectionErrorMessage(_ error: Error) -> String {
    let failure = error as NSError
    if failure.domain == CWErrorDomain {
        switch failure.code {
        case 1: // kCWEAPOLErr
            return "802.1X 认证未完成。若系统再次索要密码，请核对这个账号保存的用户名、密码及网络权限；也可能需要处理系统证书提示。可取消系统弹窗后修改账号。"
        case -3912, -3924: // Challenge failure or rejected PMK
            return "Wi-Fi 认证被拒绝。请核对保存的用户名、密码及网络认证配置，修改后再连接。"
        case -3905, -3925:
            return "系统连接超时。请检查信号和系统认证窗口，再重新尝试。"
        case -3930:
            return "macOS 未允许此次连接操作。请检查系统授权及公司的网络管理限制。"
        case -3903, -3910:
            return "这个网络的认证方式不受当前连接方式支持。请检查 Wi-Fi 的认证配置。"
        default:
            return "系统 Wi-Fi 连接失败（错误码 \(failure.code)）。请检查网络信号、认证信息和系统提示。"
        }
    }
    return error.localizedDescription
}
