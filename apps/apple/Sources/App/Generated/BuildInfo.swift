// Build-time stamp. The pre-build script in project.yml overwrites gitSHA
// with the current HEAD. The committed value stays "unknown".
enum BuildInfo {
    static let gitSHA = "unknown"
}
