cask "unifai" do
  version "0.9.15"
  sha256 "76caf5a6f00236eda55a0b33180cfa42f7978d003dc4ba2d186e220f53998226"

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
