import Foundation
import CoreWLAN
import Testing
@testable import WiFiSwitchCore

struct ConnectionErrorTests {
    @Test(arguments: [1, -3912, -3924])
    func authenticationRejectionRequiresReviewWithoutExposingRawDetails(code: Int) {
        let error = NSError(domain: CWErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "synthetic-secret"])
        #expect(connectionRequiresCredentialReview(error))
        #expect(!connectionErrorMessage(error).contains("synthetic-secret"))
        #expect(!connectionErrorMessage(error).contains("密码错误"))
        #expect(!connectionRequiresCredentialReview(NSError(domain: "Other", code: code)))
    }

    @Test func timeoutsRemainRetryableAndMissingCredentialsNeedEditing() {
        for code in [-3905, -3925] {
            #expect(!connectionRequiresCredentialReview(NSError(domain: CWErrorDomain, code: code)))
        }
        #expect(!connectionRequiresCredentialReview(WiFiError.verificationTimeout))
        #expect(!connectionRequiresCredentialReview(WiFiError.networkNotFound))
        #expect(connectionRequiresCredentialReview(StoreError.missingUsername))
        #expect(connectionRequiresCredentialReview(StoreError.missingPassword))
    }

    @Test func eapFailureExplainsAuthenticationWithoutAssertingPasswordIsWrong() {
        let message = connectionErrorMessage(NSError(domain: CWErrorDomain, code: 1))
        #expect(message.contains("802.1X 认证未完成"))
        #expect(message.contains("密码及网络权限"))
        #expect(!message.contains("密码错误"))
        #expect(!message.contains("kCWEAPOLErr"))
    }

    @Test func frameworkErrorCannotExposeRawCredentialContext() {
        let error = NSError(domain: CWErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-value"])
        #expect(!connectionErrorMessage(error).contains("secret-value"))
    }

    @Test func ownActionableErrorIsPreserved() {
        #expect(connectionErrorMessage(WiFiError.poweredOff) == WiFiError.poweredOff.localizedDescription)
    }
}
