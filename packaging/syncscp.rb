# Homebrew cask template for syncSCP. It needs a public, notarized release:
# fill in version and sha256 (shasum -a 256 dist/syncSCP-<version>-macOS.zip) and the URL,
# then submit to a tap (for example oguzhankrcb/homebrew-tap). See docs/RELEASING.md.
cask "syncscp" do
  version "0.23.0"
  sha256 "c1c335b27e90fa55705a3d58be9c6eac48da5ab4c0f6761291c2e7faa35923fd"

  url "https://github.com/oguzhankrcb/syncSCP/releases/download/v#{version}/syncSCP-#{version}-macOS.zip"
  name "syncSCP"
  desc "Native file manager and SSH terminal for SFTP, SCP, FTP/FTPS, WebDAV and S3"
  homepage "https://github.com/oguzhankrcb/syncSCP"

  depends_on macos: ">= :ventura"

  app "syncSCP.app"
  binary "#{appdir}/syncSCP.app/Contents/MacOS/syncscp-cli", target: "syncscp"

  zap trash: [
    "~/Library/Application Support/SyncSCP",
    "~/Library/Preferences/io.github.oguzhankrcb.syncscp.plist",
  ]
end
