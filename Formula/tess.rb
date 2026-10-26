class Tess < Formula
  desc "Keyboard-first tiling window manager for macOS that never hides a window"
  homepage "https://github.com/jonaprieto/tess"
  url "https://github.com/jonaprieto/tess/releases/download/v0.3.0/tess-0.3.0-macos-arm64.tar.gz"
  sha256 "48bbecaf5e6ecf520f092d3627afbaa8d93ffa15e0bc7313368d2d438fd61ed7"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos

  def install
    bin.install "tess"
  end

  def caveats
    <<~EOS
      Start it now and at login (it needs macOS 27):
        brew services start tess
      macOS asks once for Accessibility access. Browser history in the picker
      also needs Full Disk Access for #{opt_bin}/tess.
    EOS
  end

  service do
    run [opt_bin/"tess", "serve"]
    keep_alive successful_exit: false
    process_type :interactive
    error_log_path var/"log/tess.log"
  end

  test do
    assert_equal "tess #{version}", shell_output("#{bin}/tess --version").strip
  end
end
