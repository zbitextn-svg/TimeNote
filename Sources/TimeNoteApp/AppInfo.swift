import Foundation

/// 应用版本号。打包脚本 scripts/package_app.sh 的 APP_VERSION 默认值需与这里保持一致。
enum AppInfo {
    static let version = "1.1.23"
    static let displayVersion = "V\(version)"
}
