#!/usr/bin/env bash

cd ~/.config/hypr/UserConfigs || exit 1

cp -av WindowRules.conf "WindowRules.conf.bak.$(date +%F_%H%M%S)"

# cat >WindowRules.conf <<'EOF'
# windowrule = opacity 0.8 0.7, match:tag terminal*
# windowrule = opacity 0.9 0.7, match:tag browser*
# windowrule = workspace 1, match:tag email*
# windowrule = workspace 2, match:tag browser*
# windowrule = workspace 4 silent, match:tag screenshare*
# windowrule = workspace 5, match:tag gamestore*
# windowrule = workspace 6 silent, match:class ^(\.virt-manager-wrapped)$
# windowrule = workspace 6 silent, match:class ^(virt-manager)$
# windowrule = workspace 7, match:tag im*
# windowrule = workspace 8, match:tag games*
# windowrule = workspace 9 silent, match:tag multimedia*
# EOF

cat >WindowRules.conf <<'EOF'
# ------------------------------------------------------------
# Window rules (Hyprland new syntax; compatible with >= 0.52)
# ------------------------------------------------------------

# ------------------------------------------------------------
# Tagging (dynamic tags show with * in `hyprctl clients`)
# ------------------------------------------------------------

# Browser
windowrule = tag +browser, match:class ^([Ff]irefox|org\.mozilla\.firefox|[Ff]irefox-esr|[Ff]irefox-bin)$
windowrule = tag +browser, match:class ^([Gg]oogle-chrome(-beta|-dev|-unstable)?)$
windowrule = tag +browser, match:class ^(chrome-.+-Default)$
windowrule = tag +browser, match:class ^([Cc]hromium)$
windowrule = tag +browser, match:class ^([Mm]icrosoft-edge(-stable|-beta|-dev|-unstable)?)$
windowrule = tag +browser, match:class ^(Brave-browser(-beta|-dev|-unstable)?)$
windowrule = tag +browser, match:class ^([Tt]horium-browser|[Cc]achy-browser)$
windowrule = tag +browser, match:class ^(zen-alpha|zen)$

# Notifications
windowrule = tag +notif, match:class ^(swaync-control-center|swaync-notification-window|swaync-client)$

# JaKooLit helper windows
windowrule = tag +KooL_Cheat,    match:title ^(KooL Quick Cheat Sheet)$
windowrule = tag +KooL_Settings, match:title ^(KooL Hyprland Settings)$
windowrule = tag +KooL-Settings, match:class ^(nwg-displays|nwg-look)$

# Terminal / email / projects / screenshare
windowrule = tag +terminal,    match:class ^(Alacritty|kitty|kitty-dropterm)$
windowrule = tag +email,       match:class ^([Tt]hunderbird|org\.gnome\.Evolution)$
windowrule = tag +email,       match:class ^(eu\.betterbird\.Betterbird)$
windowrule = tag +projects,    match:class ^(codium|codium-url-handler|VSCodium)$
windowrule = tag +projects,    match:class ^(VSCode|code-url-handler)$
windowrule = tag +projects,    match:class ^(jetbrains-.+)$
windowrule = tag +screenshare, match:class ^(com\.obsproject\.Studio)$

# IM
windowrule = tag +im, match:class ^([Dd]iscord|[Ww]ebCord|[Vv]esktop)$
windowrule = tag +im, match:class ^([Ff]erdium)$
windowrule = tag +im, match:class ^([Ww]hatsapp-for-linux)$
windowrule = tag +im, match:class ^(ZapZap|com\.rtosta\.zapzap)$
windowrule = tag +im, match:class ^(org\.telegram\.desktop|io\.github\.tdesktop_x64\.TDesktop)$
windowrule = tag +im, match:class ^(teams-for-linux)$
windowrule = tag +im, match:class ^(im\.riot\.Riot|Element)$

# Games / stores
windowrule = tag +games,     match:class ^(gamescope)$
windowrule = tag +games,     match:class ^(steam_app_\d+)$
windowrule = tag +gamestore, match:class ^([Ss]team)$
windowrule = tag +gamestore, match:title ^([Ll]utris)$
windowrule = tag +gamestore, match:class ^(com\.heroicgameslauncher\.hgl)$

# File manager / wallpaper / media
windowrule = tag +file-manager, match:class ^([Tt]hunar|org\.gnome\.Nautilus|[Pp]cmanfm-qt)$
windowrule = tag +file-manager, match:class ^(app\.drey\.Warp)$
windowrule = tag +wallpaper,    match:class ^([Ww]aytrogen)$
windowrule = tag +multimedia,   match:class ^([Aa]udacious)$
windowrule = tag +multimedia_video, match:class ^([Mm]pv|vlc)$

# Settings / viewers
windowrule = tag +settings, match:title ^(ROG Control)$
windowrule = tag +settings, match:class ^(wihotspot(-gui)?|org\.gnome\.[Bb]aobab|[Bb]aobab|gnome-disks|file-roller|org\.gnome\.FileRoller|nm-applet|nm-connection-editor|blueman-manager|pavucontrol|org\.pulseaudio\.pavucontrol|com\.saivert\.pwvucontrol|qt5ct|qt6ct|[Yy]ad|xdg-desktop-portal-gtk|org\.kde\.polkit-kde-authentication-agent-1|[Rr]ofi)$
windowrule = tag +viewer,   match:class ^(gnome-system-monitor|org\.gnome\.SystemMonitor|io\.missioncenter\.MissionCenter|evince|eog|org\.gnome\.Loupe)$

# ------------------------------------------------------------
# Special overrides
# ------------------------------------------------------------

windowrule = no_blur on, match:tag multimedia_video
windowrule = opacity 1.0 override 1.0 override, match:tag multimedia_video

# ------------------------------------------------------------
# Position / move
# ------------------------------------------------------------

windowrule = center on, match:tag KooL_Cheat
windowrule = center on, match:tag KooL-Settings
windowrule = center on, match:title ^(ROG Control)$
windowrule = center on, match:title ^(Keybindings)$
windowrule = center on, match:class ^(pavucontrol|org\.pulseaudio\.pavucontrol|com\.saivert\.pwvucontrol)$
windowrule = center on, match:class ^([Ww]hatsapp-for-linux|ZapZap|com\.rtosta\.zapzap)$
windowrule = center on, match:class ^([Ff]erdium)$
windowrule = center on, match:class ([Tt]hunar), match:title negative:(.*[Tt]hunar.*)

windowrule = move 72% 7%, match:title ^(Picture-in-Picture)$

# ------------------------------------------------------------
# Idle inhibit (fullscreen)
# ------------------------------------------------------------

windowrule = idle_inhibit fullscreen, match:fullscreen 1

# ------------------------------------------------------------
# Float / dialogs
# ------------------------------------------------------------

windowrule = float on, match:tag KooL_Cheat
windowrule = float on, match:tag wallpaper
windowrule = float on, match:tag settings
windowrule = float on, match:tag viewer
windowrule = float on, match:tag KooL-Settings
windowrule = float on, match:class ([Zz]oom|onedriver|onedriver-launcher)$
windowrule = float on, match:class (org\.gnome\.Calculator), match:title (Calculator)
windowrule = float on, match:class ^(mpv|com\.github\.rafostar\.Clapper)$
windowrule = float on, match:class ^([Qq]alculate-gtk)$
windowrule = float on, match:title ^(Picture-in-Picture)$

windowrule = float on,  match:title ^(Authentication Required)$
windowrule = center on, match:title ^(Authentication Required)$

windowrule = float on,   match:title ^(Add Folder to Workspace)$
windowrule = size 70% 60%, match:title ^(Add Folder to Workspace)$
windowrule = center on,  match:title ^(Add Folder to Workspace)$

windowrule = float on,   match:title ^(Save As)$
windowrule = size 70% 60%, match:title ^(Save As)$
windowrule = center on,  match:title ^(Save As)$

windowrule = float on,      match:initial_title (Open Files)
windowrule = size 70% 60%,  match:initial_title (Open Files)

windowrule = float on,      match:title ^(SDDM Background)$
windowrule = center on,     match:title ^(SDDM Background)$
windowrule = size 16% 12%,  match:title ^(SDDM Background)$

# ------------------------------------------------------------
# Opacity (use override to avoid multiplicative “black” surprises)
# ------------------------------------------------------------

windowrule = opacity 0.99 override 0.80 override, match:tag browser
windowrule = opacity 0.90 override 0.80 override, match:tag projects
windowrule = opacity 0.94 override 0.86 override, match:tag im
windowrule = opacity 0.94 override 0.86 override, match:tag multimedia
windowrule = opacity 0.90 override 0.80 override, match:tag file-manager
windowrule = opacity 0.90 override 0.70 override, match:tag terminal
windowrule = opacity 0.80 override 0.70 override, match:tag settings
windowrule = opacity 0.82 override 0.75 override, match:tag viewer
windowrule = opacity 0.90 override 0.70 override, match:tag wallpaper

windowrule = opacity 0.80 override 0.70 override, match:class ^(gedit|org\.gnome\.TextEditor|mousepad)$
windowrule = opacity 0.90 override 0.80 override, match:class ^(deluge)$
windowrule = opacity 0.90 override 0.80 override, match:class ^(seahorse)$
windowrule = opacity 0.95 override 0.75 override, match:title ^(Picture-in-Picture)$

# ------------------------------------------------------------
# Size
# ------------------------------------------------------------

windowrule = size 65% 90%, match:tag KooL_Cheat
windowrule = size 70% 70%, match:tag wallpaper
windowrule = size 70% 70%, match:tag settings
windowrule = size 60% 70%, match:class ^([Ww]hatsapp-for-linux|ZapZap|com\.rtosta\.zapzap)$
windowrule = size 60% 70%, match:class ^([Ff]erdium)$

# ------------------------------------------------------------
# Pinning / aspect ratio
# ------------------------------------------------------------

windowrule = pin on,               match:title ^(Picture-in-Picture)$
windowrule = keep_aspect_ratio on, match:title ^(Picture-in-Picture)$

# ------------------------------------------------------------
# Blur / fullscreen prefs
# ------------------------------------------------------------

windowrule = no_blur on,    match:tag games
windowrule = fullscreen on, match:tag games

# ------------------------------------------------------------
# Layer rules (Wayland layers)
# ------------------------------------------------------------

layerrule = blur on,        match:namespace rofi
layerrule = ignore_alpha 0, match:namespace rofi
layerrule = blur on,        match:namespace notifications
layerrule = ignore_alpha 0, match:namespace notifications
EOF

hyprctl reload
hyprctl configerrors
