#!/usr/bin/env bash

gen_log sudo pacstrap -P -K /mnt base base-devel power-profiles-daemon archlinux-keyring archiso arch-install-scripts archinstall vulkan-radeon mesa libdrm radeontool rustup \
	lsof strace rsync reflector linux linux-headers linux-firmware alsa-utils \
	efibootmgr networkmanager cpupower thermald sudo nano neovim mtools \
	dosfstools pacrunner java-runtime java-environment java-rhino amd-ucode xdg-user-dirs xdg-utils \
	python-scipy python-pandas lldb gdb cmake \
	ninja zip unzip lzop lz4 exfatprogs ntfs-3g xorg-xauth \
	git github-cli devtools wget curl coreutils iptables inetutils \
	openssh lvm2 torchvision qt5 qt6 qt5-base qt6-base vulkan-headers \
	vulkan-extra-layers volk vkmark vkd3d spirv-tools vulkan-mesa-layers vulkan-tools vulkan-utility-libraries \
	mesa-demos archiso arch-install-scripts archinstall uutils-coreutils progress grub \
	glib2-devel glibc-locales gcc-fortran gcc libcap-ng libcurl-compat libcurl-gnutls libgccjit \
	fuse3 freetype2 libisoburn os-prober minizip lzo libxcrypt-compat libxcrypt \
	xca tpm2-tss-engine tpm2-openssl ruby python-pyopenssl pkcs11-provider \
	perl-crypt-openssl-rsa extra-cmake-modules corrosion git-bug git-cinnabar \
	git-cliff git-crypt git-delta git-evtag git-filter-repo git-grab git-lfs gitea \
	gitg tk perl-libwww perl-term-readkey perl-io-socket-ssl perl-authen-sasl perl-mediawiki-api perl-datetime-format-iso8601 \
	perl-lwp-protocol-https perl-cgi subversion xf86-video-amdgpu amd-ucode xdg-user-dirs xdg-utils hipify-clang tensorflow-opt icu \
	egl-gbm egl-wayland egl-x11 openipmi openpgl openvkl throttled \
	tipp10 vpl-gpu-rt singular polymake planarity pari normaliz nauty \
	mpfi libxaw libmpc libsemigroups fplll cddlib c-xsc bliss \
	sof-firmware goreleaser black-hole-solver lsd opam ocaml-bigarray-compat ocaml \
	ocaml-pp ocaml-re ocaml-fmt ocaml-bos ocaml-gen ocaml-num ocaml-seq ocaml-csexp \
	ocaml-pcre2 ocaml-base ocamlbuild swi-prolog darcs powerline-fonts nerd-fonts awesome-terminal-fonts \
	vim-powerline python-trio python-uvloop pari-elldata pari-galpol \
	pkgfile bash bash-completion bat blas-openblas bluez boost-libs btrfs-progs \
	bzip2 ca-certificates cairo ccid clang cppzmq dav1d dav1d-doc \
	db db5.3 dconf debuginfod dhcpcd diffutils dnsmasq e2fsprogs \
	ed edk2-ovmf erofsfuse evince exo ffmpeg fftw fftw-openmpi \
	firewalld flite fluidsynth freeglut freetds frei0r-plugins gcr gd \
	gdbm gdk-pixbuf2 geoclue ghostscript git-zsh-completion python-psutil libnotify \
	gvfs-wsdd gvfs-nfs gvfs-mtp gvfs-gphoto2 gvfs-goa gvfs-dnssd \
	gvfs-afc udftools nilfs-utils less udisks2-docs udisks2-lvm2 udisks2-btrfs \
	libblockdev-nvdimm libblockdev-mpath libblockdev-lvm libblockdev-dm libblockdev-btrfs gtk4 opencv gavl \
	devil openresolv glusterfs nlohmann-json fast_float proj \
	postgresql-libs pdal paraview-catalyst opencascade netcdf liblas libharu gdal \
	cgns alembic adios2 viskores ospray openimagedenoise gl2ps \
	wofi wmenu dmenu bemenu glibc glu gnupg gnutls \
	graphite-docs grep gst-libav gst-plugin-pipewire gst-plugins-bad gst-plugins-good gst-plugins-ugly gtest \
	gtk3 guile gvfs hspell hunspell iio-sensor-proxy imagemagick \
	iwd jasper-doc jsoncpp-doc kde-cli-tools kguiaddons kwallet5 kwayland5 kwindowsystem \
	ladspa lesspipe lib32-gcc-libs libarchive libbpf libdecor libdvdcss libevent \
	libfbclient libffado libfido2 libgit2-glib-docs libheif libinput-tools libjpeg-turbo libldap \
	libmicrohttpd libmysofa libopenraw libp11-kit libpng libpwquality libsecret \
	libusb libwebp libwebp-utils libwmf libx11 libxau libxkbcommon-x11 libxml2 \
	linux-firmware-liquidio litehtml llvm lua lua51-lgi avahi glib-networking glslang \
	gnome-keyring graphite libasyncns libnet librsvg lm_sensors man mariadb-libs \
	memcached mercurial modemmanager nftables nss nss-mdns nuspell nvchecker \
	openjpeg2 openmp openssl org.freedesktop.secrets pam pango pcmanfm perl \
	perl-datetime-format-builder perl-file-homedir perl-file-mimeinfo perl-locale-gettext perl-net-dbus perl-tk perl-x11-protocol polkit \
	postgresql ppp psutils python-beautifulsoup4 \
	qemu-desktop qrencode qt5-declarative qt5-wayland qt5-x11extras qt6-5compat qt6-declarative \
	qt6-quick3d qt6-serialport quota-tools rav1e realtime-privileges rtkit sdl sh \
	smtp-forwarder sndio speech-dispatcher sqlite svt-av1 systemd-sysvcompat tcl tpm2-tss \
	unixodbc util-linux valkey vulkan-driver wayland xsel xz zlib \
	make mariadb mupdf-tools mypy netpbm onetbb opencl-driver opengl-man-pages \
	openmpi ostra-cg parallel-docs pcsclite perl-archive-zip python-cairo \
	python-inflect python-libevdev python-pandas-datareader python-pynvim \
	python-systemd qt5-graphicaleffects qt5-svg qt6-svg rrdtool ruby-docs ruby-stdlib \
	samba scx-scheds sdl2 tpm2-abrmd tree-sitter which wireless-regdb wl-clipboard \
	words x11-ssh-askpass xcb-util-wm xclip comgr intel-media-sdk mkinitcpio-nfs-utils opencl-headers \
	openucc prrte-docs pyside6 python-certifi python-distributed \
	r rdma-core ruby-bundled-gems ruby-default-gems systemd-ukify wpa_supplicant \
	x264 xterm tectonic texlive-basic texlive-bibtexextra texlive-bin texlive-binextra \
  texlive-fontsextra texlive-fontsrecommended texlive-fontutils texlive-formatsextra \
  texlive-humanities texlive-langenglish texlive-langeuropean texlive-langgreek \
  texlive-langother texlive-latex texlive-latexextra texlive-latexrecommended \
  texlive-luatex texlive-mathscience texlive-metapost texlive-pictures \
  texlive-plaingeneric texlive-pstricks texlive-publishers texlive-xetex
