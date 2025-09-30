choco uninstall 4k-tokkit 7zip.commandline 7zip.install 7zip.portable actiona.install advanced-codecs ansifilter ant ant-commander-personal ant-commander-pro autohotkey autohotkey.install autohotkey.portable bat boost-msvc-14.3 cabal cascadia-code-nerd-font ChromeDriver2 ConEmu dejavufonts dismplusplus dotnet-6.0-runtime dotnetfx earthview-chrome exfat7z fd firacodenf firanf font-firge-nerd font-hackgen-nerd font-nerd-DejaVuSansMono fzf ghc git git.install glfw3 gnuwin32-coreutils.install gnuwin32-m4 GoogleChrome google-dictionary-chrome googleearthpro gprolog-msvc grep gsudo installedcodec invokebuild jq jreleaser KB2919355 KB2919442 KB2999226 KB3033929 KB3035131 KB3063858 KB3118401 kitty k-litecodecpackfull ldc less lilypond llvm lsd make mc mdcat miller mobaxterm nasm neovim nerdfont-hack nerd-fonts-0xProto nerd-fonts-3270 nerd-fonts-Agave nerd-fonts-AnonymousPro nerd-fonts-Arimo nerd-fonts-AurulentSansMono nerd-fonts-BigBlueTerminal nerd-fonts-BitstreamVeraSansMono nerd-fonts-CascadiaCode nerd-fonts-CascadiaMono nerd-fonts-CodeNewRoman nerd-fonts-ComicShannsMono nerd-fonts-CommitMono nerd-fonts-Cousine nerd-fonts-D2Coding nerd-fonts-DaddyTimeMono nerd-fonts-DejaVuSansMono nerd-fonts-DelugiaBook nerd-fonts-DelugiaComplete nerd-fonts-DelugiaMono-Complete nerd-fonts-DelugiaMono-Powerline nerd-fonts-DelugiaPowerline nerd-fonts-DroidSansMono nerd-fonts-EnvyCodeR nerd-fonts-FantasqueSansMono nerd-fonts-FiraCode nerd-fonts-FiraMono nerd-fonts-GeistMono nerd-fonts-Gohu nerd-fonts-Go-Mono nerd-fonts-Hack nerd-fonts-Hasklig nerd-fonts-HeavyData nerd-fonts-Hermit nerd-fonts-iA-Writer nerd-fonts-IBMPlexMono nerd-fonts-Inconsolata nerd-fonts-InconsolataGo nerd-fonts-InconsolataLGC nerd-fonts-IntelOneMono nerd-fonts-Iosevka nerd-fonts-IosevkaTerm nerd-fonts-IosevkaTermSlab nerd-fonts-JetBrainsMono nerd-fonts-Lekton nerd-fonts-LiberationMono nerd-fonts-Lilex nerd-fonts-MartianMono nerd-fonts-Meslo nerd-fonts-Monaspace nerd-fonts-Monofur nerd-fonts-Monoid nerd-fonts-Mononoki nerd-fonts-MPlus nerd-fonts-NerdFontsSymbolsOnly nerd-fonts-Noto nerd-fonts-OpenDyslexic nerd-fonts-Overpass nerd-fonts-ProFont nerd-fonts-ProggyClean nerd-fonts-Recursive nerd-fonts-RobotoMono nerd-fonts-ShareTechMono nerd-fonts-SourceCodePro nerd-fonts-SpaceMono nerd-fonts-Terminus nerd-fonts-Tinos nerd-fonts-Ubuntu nerd-fonts-UbuntuMono nerd-fonts-UbuntuSans nerd-fonts-VictorMono nerd-fonts-ZedMono ninja notepadplusplus notepadplusplus.install nvim-ui nvm nvm.install oh-my-posh opera-gx pelles-c poshgit PowerShell powershell-core powershellplus pswindowsupdate python python3 python313 qbittorrent-enhanced radiant rufus.install rustup.install selenium selenium.powershell selenium-all-drivers selenium-chrome-driver selenium-edge-driver selenium-gecko-driver SeleniumHub selenium-ie-driver selenium-opera-driver sphinx starship.install sublimetext3 SublimeText3.PowershellAlias telegram.install unzip vcredist140 vcredist2015 ventoy victormononf vidcutter vim visualstudio2022buildtools visualstudio2022-workload-vctools visualstudio-installer vlc-nightly vscode vscode.install vscode-markdown-all-in-one vscode-markdownlint vscode-prettier Wget winflexbison3 winget.powershell worldwide-telescope xpdf-utils zabbix-agent.install zip -y



$chocoRoot = "C:\ProgramData\chocolatey"

#$scoopGlobal = "C:\ProgramData\scoop"

#$scoopUser = "C:\users\heini\scoop"

#takeown /F $scoopUser   /R /D Y
#takeown /F $scoopGlobal /R /D Y
takeown /F $chocoRoot   /R /D Y

#icacls $scoopUser   /grant "$($env:USERNAME):F" /T /C
#icacls $scoopGlobal /grant "$($env:USERNAME):F" /T /C
icacls $chocoRoot   /grant "$($env:USERNAME):F" /T /C

#Remove-Item -Path $scoopUser   -Recurse -Force
#Remove-Item -Path $scoopGlobal -Recurse -Force
Remove-Item -Path $chocoRoot   -Recurse -Force