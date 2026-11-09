class Tess < Formula
  desc "Keyboard-first tiling window manager for macOS that never hides a window"
  homepage "https://github.com/jonaprieto/tess"
  url "https://github.com/jonaprieto/tess/releases/download/v0.13.0/tess-0.13.0-macos-arm64.tar.gz"
  sha256 "88dc28223c6ea1ff88c3af46347eba15b51cb8d7ea17edf9803a193b72f635d7"
  license "MIT"

  depends_on arch: :arm64
  depends_on "fd"
  depends_on "jonaprieto/tap/folio"
  depends_on :macos

  def install
    bin.install "tess"
    prefix.install "tess.app"
  end

  def caveats
    <<~EOS
      Start it now and at login (it needs macOS 27):
        brew services start tess
      macOS asks once for Accessibility access. Browser history in the picker
      also needs Full Disk Access for #{opt_bin}/tess.
      Check setup and open the newcomer walkthrough:
        tess doctor
        tess tutorial
      To open it from Finder or Spotlight (Settings, or tess again after Quit):
        cp -R #{opt_prefix}/tess.app /Applications/
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
