cask "unifai" do
  version "0.9.14"
  sha256 "1950372c869cb0dc0a3b38f3c7502acbee33320a822ed5340ae24b6f542f831c"

  url "https://github.com/kennykankush/unifAI/releases/download/v#{version}/Unifai-#{version}.zip"
  name "Unifai"
  desc "Local hub for AI wallets, spend, renewals and releases, with a read-only MCP server"
  homepage "https://github.com/kennykankush/unifAI"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Unifai.app"
  binary "#{appdir}/Unifai.app/Contents/MacOS/unifai-mcp"

  uninstall quit: "dev.unifai.app"

  zap trash: [
    "~/Library/Application Support/Unifai",
    "~/Library/Preferences/dev.unifai.app.plist",
    "~/Library/Group Containers/483LU3J5WJ.dev.unifai",
  ]
end
