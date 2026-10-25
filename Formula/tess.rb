class Tess < Formula
  desc "Keyboard-first tiling window manager for macOS that never hides a window"
  homepage "https://github.com/jonaprieto/tess"
  url "https://github.com/jonaprieto/tess/releases/download/v0.1.0/tess-0.1.0-macos-arm64.tar.gz"
  sha256 "300a0911be75f01d950002fb0801fef639ceb35c7978ff1ec242f5aeb7046198"
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
