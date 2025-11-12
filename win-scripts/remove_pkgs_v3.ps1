scoop uninstall 7zip
scoop uninstall goreleaser
scoop uninstall jq
scoop uninstall latex
scoop uninstall miktex
scoop uninstall msys2
scoop uninstall nvm
scoop uninstall ruby
scoop uninstall uutils-coreutils
scoop uninstall vlc
scoop uninstall vscode
scoop uninstall zed

sudo scoop uninstall archwsl --global
sudo scoop uninstall cmake --global
sudo scoop uninstall dark --global
sudo scoop uninstall Delugia-Mono-Nerd-Font --global
sudo scoop uninstall Delugia-Nerd-Font --global
sudo scoop uninstall Delugia-Nerd-Font-Book --global
sudo scoop uninstall Font-Awesome --global
sudo scoop uninstall fontreg --global
sudo scoop uninstall forkgram --global
sudo scoop uninstall go-jsonnet --global
sudo scoop uninstall gopass --global
sudo scoop uninstall gopass-jsonapi --global
sudo scoop uninstall goreleaser --global
sudo scoop uninstall gow --global
sudo scoop uninstall hack-font --global
sudo scoop uninstall imagemagick --global
sudo scoop uninstall jq --global
sudo scoop uninstall kitty --global
sudo scoop uninstall make --global
sudo scoop uninstall Monocraft-Nerd-Font --global
sudo scoop uninstall mpv-git --global
sudo scoop uninstall NerdFontsSymbolsOnly --global
sudo scoop uninstall nodejs --global
sudo scoop uninstall openjdk --global
sudo scoop uninstall openssh --global
sudo scoop uninstall openssl --global
sudo scoop uninstall premake --global
sudo scoop uninstall ProFont-NF --global
sudo scoop uninstall ProFont-NF-Mono --global
sudo scoop uninstall ProFont-NF-Propo --global
sudo scoop uninstall rubberband --global
sudo scoop uninstall Setofont --global
sudo scoop uninstall sphinxtrain --global
sudo scoop uninstall twemoji-color-font --global
sudo scoop uninstall unxutils --global
sudo scoop uninstall uutils-coreutils --global
sudo scoop uninstall vcredist2022 --global
sudo scoop uninstall xmake --global
sudo scoop uninstall yt-dlp --global
sudo scoop uninstall zed --global

$scoopGlobal = "C:\ProgramData\scoop"

$scoopUser = "C:\users\heini\scoop"

sudo takeown /F $scoopUser   /R /D Y
sudo takeown /F $scoopGlobal /R /D Y

sudo icacls $scoopUser   /grant "$($env:USERNAME):F" /T /C
sudo icacls $scoopGlobal /grant "$($env:USERNAME):F" /T /C

sudo Remove-Item -Path $scoopUser   -Recurse -Force
sudo Remove-Item -Path $scoopGlobal -Recurse -Force