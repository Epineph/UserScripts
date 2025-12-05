#!/usr/bin/env bash

gen_log yay -S --needed singular polymake planarity pari normaliz nauty \
  mpfi libxaw libmpc libsemigroups libmpc fplll cddlib c-xsc bliss fnm-bin \
  github-cli sof-firmware goreleaser-pro-bin python-watchgod black-hole-solver \
  lsd opam ocaml-bigarray-compat ocaml ocaml-pp ocaml-re ocaml-fmt ocaml-bos \
  ocaml-gen ocaml-num ocaml-seq ocaml-csexp ocaml-pcre2 ocaml-base ocamlbuild \
  zinit zsh-autosuggestions zsh-autocomplete zsh-syntax-highlighting powerline \
  nerd-fonts awesome-terminal-fonts bash-preexec oh-my-zsh-git \
	find-the-command antigen-git zplug  zsh-fast-syntax-highlighting zsh-eza-git \
	zsh-manydots-magic zsh-fzf-plugin-git zsh-plugin-wd-git  \
	zsh-extract-git zsh-systemd-git lsd oh-my-zsh-powerline-theme-git \
	bullet-train-oh-my-zsh-theme-git swi-prolog darcs powerline-fonts \
	vim-powerline python-netifaces python-trio python-outcome \
	python-uvloop python-pytest pari-elldata pari-galdata pari-seadata \
	pari-galpol pkgfile --sudoloop --batchinstall


Default_Extra_Pkg_Dir=$HOME/extra-packages

echo "Additional packages options:"
echo "1) Install now"
echo "2) Save script for later"
echo "3) Skip (default)"
echo "4) Don't save or install"
read -p "Choose (1-4): " -r choice

case "${choice,,}" in
  1)
    echo "Installing now..."
    # Installation code
    ;;
  2|"save"|"later")
    echo -e "\nSave location options:"
    echo "1) Current directory: $PWD"
    echo "2) Default directory: $Default_Extra_Pkg_Dir"
    echo "3) Custom directory"
    echo "4) Don't backup or install and exit script"
    read -p "Choose save location (1-3, default is 2): " -r location_choice

    case "$location_choice" in
      1)
        save_dir="$PWD"
        ;;
      3|"custom")
        read -p "Enter custom directory path: " -r custom_dir
        save_dir="$custom_dir"
        ;;
      4|"cancel")
        echo "Not backup up or installing extra script"
        exit 1
      *)
        save_dir="$Default_Extra_Pkg_Dir"
        ;;
    esac

    # Create directory if it doesn't exist
    if [[ ! -d "$save_dir" ]]; then
      echo -e "\nUser has chosen to save extra packages at: $save_dir"
      echo "Directory not found: Creating it..."
      mkdir -p "$save_dir"
    fi


    # Save the script
    script_path="$save_dir/install-additional.sh"
    echo -e "\nSaving installation script to: $script_path"

    cat > "$script_path" <<'EOF'
#!/usr/bin/env bash
# Generated installation script - run this later
# Add your package installation commands here
echo "This is where your package installation would go"

gen_log yay -S --needed adwaita-cursors alsa-lib apparmor appstream aspell \
  assimp audispd-plugins audispd-plugins-zos avisynthplus base-devel \
	bash bash-completion bat biber blas-openblas bluez boost-libs btrfs-progs \
	bzip2 ca-certificates cairo ccid clang cppzmq curl dav1d dav1d-doc db db5.3 \
	dconf debuginfod dhcpcd diffutils dnsmasq dosfstools e2fsprogs ed edk2-ovmf \
	efibootmgr erofsfuse evince exo ffmpeg fftw fftw-openmpi firewalld flite \
	fluidsynth freeglut freetds freetype2 frei0r-plugins fuse3 gcc-fortran gcr \
	gd gdb gdbm gdk-pixbuf2 geoclue ghostscript git git-zsh-completion \
	python-notify2 python-psutil libnotify python-pyqt6 gvfs-wsdd gvfs-nfs \
	gvfs-mtp gvfs-gphoto2 gvfs-google gvfs-goa gvfs-dnssd gvfs-afc udftools \
	nilfs-utils less udisks2-docs udisks2-lvm2 udisks2-btrfs python-libblockdev \
	libblockdev-nvdimm libblockdev-mpath libblockdev-lvm libblockdev-dm \
	libblockdev-btrfs gtk4 opencv gavl devil openresolv python-cryptography \
	glusterfs python-dnspython nlohmann-json fast_float proj postgresql-libs \
	pdal paraview-catalyst opencascade netcdf liblas libharu gdal cgns alembic \
	adios2 viskores ospray openimagedenoise gl2ps python-mpi4py wofi wmenu \
	rofi-wayland fuzzel dmenu bemenu glib2-devel glibc glu gnupg gnutls \
	graphite-docs grep grub gst-libav gst-plugin-pipewire gst-plugins-bad \
	gst-plugins-good gst-plugins-ugly gtest gtk3 guile gvfs hspell hunspell \
	icu iio-sensor-proxy imagemagick inetutils iptables ipython iwd jasper-doc \
	java-environment java-rhino jsoncpp-doc kde-cli-tools kguiaddons kwallet5 \
	kwayland5 kwindowsystem ladspa lesspipe lib32-gcc-libs libarchive libbpf \
	libdecor libdvdcss libevent libfbclient libffado libfido2 libgit2-glib-docs \
	libheif libinput-tools libisoburn libjpeg-turbo libldap libmicrohttpd \
	libmysofa libopenraw libp11-kit libpng ntfs-3g mtools dosfstool libpwquality \
	libsecret libusb libwebp libwebp-utils libwmf libx11 libxau libxaw \
	libxkbcommon-x11 libxml2 linux-firmware-liquidio litehtml lldb llvm lua \
	lua51-lgi lvm2 lz4 lzop avahi gitg glib-networking glibc glslang \
	gnome-keyring graphite grub gst-libav gst-plugins-bad gst-plugins-good \
	gst-plugins-ugly hspell iio-sensor-proxy iptables iwd java-environment \
	kguiaddons kwallet5 kwayland5 kwindowsystem ladspa libarchive libasyncns \
	libbpf libdecor libevent libfbclient libffado libfido2 libisoburn libldap \
	libmysofa libnet libopenraw libp11-kit libpng libpwquality librsvg libsecret \
	libusb libwmf libxau libxaw libxml2 lm_sensors man mariadb-libs memcached \
	mercurial mesa-vdpau mkinitcpio-nfs-utils modemmanager nftables ninja nss \
	nss-mdns nuspell nvchecker openjpeg2 openmp openresolv openssh openssl \
	org.freedesktop.secrets os-prober pacrunner pam pango pcmanfm perl \
	perl-authen-sasl perl-cgi perl-datetime-format-builder perl-file-homedir \
	perl-file-mimeinfo perl-io-socket-ssl perl-libwww perl-locale-gettext \
	perl-net-dbus perl-term-readkey perl-tk perl-x11-protocol polkit \
	postgresql ppp psutils python python-beautifulsoup4 python-blosc \
	python-bottleneck python-brotli python-brotlicffi python-cffi \
	python-colorama python-dbus python-dotenv python-email-validator \
	python-fsspec python-gobject python-gpgme python-h2 python-html5lib \
	python-hypothesis python-idna python-jinja python-linkify-it-py python-lxml \
	python-matplotlib python-merge3 python-numexpr python-numpy python-openpyxl \
	python-paramiko python-pip python-pipx python-psutil python-pyarrow \
	python-pydantic-core python-pyelftools python-pygments python-pyinotify \
	python-pymysql python-pyopenssl python-pyqt5 python-pysocks python-pytables \
	python-pyudev python-pyyaml python-qtpy python-requests python-rich \
	python-scipy python-setuptools python-snappy python-sqlalchemy \
	python-tabulate python-tqdm python-twisted python-xarray python-xdg \
	python-xlrd python-xlsxwriter python-xlwt python-yaml python-zstandard \
	qemu-desktop qrencode qt5-base qt5-declarative qt5-wayland qt5-x11extras \
	qt6-5compat qt6-base qt6-declarative qt6-quick3d qt6-serialport quota-tools \
	rav1e realtime-privileges rtkit sdl sh smtp-forwarder sndio \
	speech-dispatcher sqlite subversion sudo svt-av1 systemd-sysvcompat tcl tk \
	tpm2-tss unixodbc util-linux valkey vulkan-driver vulkan-mesa-layers wayland \
	wireless-regdb wl-clipboard wpa_supplicant x11-ssh-askpass x264 xclip \
	xorg-xauth xsel xz zlib make man mariadb memcached mercurial mesa-vdpau \
	mkinitcpio-nfs-utils modemmanager mupdf-tools mypy netpbm nftables ninja \
	nss nss-mdns nuspell onetbb opencl-driver opengl-man-pages openjpeg2 \
	openmp openmpi openresolv openssh openssl org.freedesktop.secrets os-prober \
	ostra-cg pacrunner pam pango parallel-docs pcmanfm pcsclite perl \
	perl-archive-zip perl-authen-sasl perl-cgi perl-file-homedir \
	perl-file-mimeinfo perl-io-socket-ssl perl-libwww perl-locale-gettext \
	perl-lwp-protocol-https perl-net-dbus perl-term-readkey perl-tk \
	perl-x11-protocol python-babel python-beautifulsoup4 python-blosc \
	python-bottleneck python-brotli python-brotlicffi python-cairo python-cffi \
	python-chardet python-colorama python-dbus python-dotenv \
	python-email-validator python-fastimport python-fsspec python-gobject \
	python-gpgme python-h2 python-html5lib python-hypothesis python-idna \
	python-inflect python-jinja python-keyring python-libevdev \
	python-linkify-it-py python-lxml python-matplotlib python-mdit_py_plugins \
	python-merge3 python-numexpr python-numpy python-openpyxl \
	python-pandas-datareader python-paramiko python-pillow python-pip \
	python-pipx python-psutil python-pyarrow python-pyelftools python-pygments \
	python-pyinotify python-pymysql python-pynvim python-pyopenssl python-pyqt5 \
	python-pysocks python-pytables python-pyudev python-pyxdg python-pyyaml \
	python-qtpy python-requests python-rich python-scipy python-setuptools \
	python-snappy python-sqlalchemy python-systemd python-tabulate python-tqdm \
	python-twisted python-xarray python-xdg python-xlrd python-xlsxwriter \
	python-xlwt python-yaml python-zstandard qemu-desktop qrencode qt5-base \
	qt5-declarative qt5-graphicaleffects qt5-svg qt5-wayland qt5-x11extras \
	qt6-5compat qt6-base qt6-declarative qt6-quick3d qt6-serialport qt6-svg \
	quota-tools rav1e realtime-privileges rrdtool rsync ruby-docs ruby-stdlib \
	samba scx-scheds sdl sdl2 sh smtp-forwarder sndio speech-dispatcher sqlite \
	subversion sudo svt-av1 systemd-sysvcompat tcl tk tpm2-abrmd tpm2-tss \
	tree-sitter unixodbc util-linux valkey vulkan-driver vulkan-mesa-layers \
	wayland which wireless-regdb wl-clipboard words x11-ssh-askpass xcb-util-wm \
	xclip xorg-xauth xsel xz zlib comgr avahi gitg glib2-devel glibc glu \
	gnupg gnutls grep grub grub gst-libav gst-plugins-bad gst-plugins-good \
	gst-plugins-ugly gtest gtk3 guile gvfs hspell hunspell iio-sensor-proxy \
	imagemagick intel-media-sdk iptables iptables iwd java-environment \
	kguiaddons kwallet5 kwayland5 kwindowsystem ladspa less libarchive \
	libasyncns libbpf libdecor libevent libfbclient libffado libfido2 \
	libisoburn libldap libmysofa libopenraw libp11-kit libpng libpwquality \
	libsecret libusb libwmf libxau libxaw libxml2 litehtml lldb llvm lua lz4 \
	lzop man mariadb-libs memcached mercurial mesa-vdpau mkinitcpio-nfs-utils \
	modemmanager mtools mtools nftables ninja opencl-headers openjpeg2 openmp \
	openmpi openresolv openssh openssl openucc org.freedesktop.secrets \
	os-prober pacrunner pam pango pcmanfm perl perl-authen-sasl perl-cgi \
	perl-datetime-format-builder perl-file-homedir perl-file-mimeinfo \
	perl-io-socket-ssl perl-libwww perl-locale-gettext perl-net-dbus \
	perl-term-readkey perl-tk perl-x11-protocol polkit postgresql \
	postgresql-libs ppp prrte-docs psutils pyside6 python python-beautifulsoup4 \
	python-blosc python-bottleneck python-brotli python-brotlicffi python-cairo \
	python-cairocffi python-certifi python-cffi python-colorama \
	python-cryptography python-dbus python-defusedxml python-distributed \
	python-dotenv python-email-validator python-fs python-fsspec python-genshi \
	python-gobject python-gpgme python-h2 python-html5lib python-hypothesis \
	python-idna python-jinja python-libarchive-c python-linkify-it-py \
	python-lxml python-lz4 python-matplotlib python-merge3 python-numexpr \
	python-numpy python-olefile python-openpyxl python-paramiko python-pip \
	python-pipx python-psutil python-pyarrow python-pydantic-core python-pydot \
	python-pyelftools python-pygit2 python-pygments python-pygraphviz \
	python-pyinotify python-pyjwt python-pymysql python-pyopenssl python-pyqt5 \
	python-pyqt6 python-pysocks python-pytables python-pyu2f python-pyudev \
	python-pyyaml python-qtpy python-reportlab python-requests python-rich \
	python-scikit-learn python-scipy python-setuptools python-smbprotocol \
	python-snappy python-sqlalchemy python-symengine python-sympy \
	python-tabulate python-tornado python-tqdm python-twisted \
	python-unicodedata2 python-wxpython python-xarray python-xdg python-xlrd \
	python-xlsxwriter python-xlwt python-yaml python-zopfli python-zstandard \
	qemu-desktop qrencode qt5-base qt5-declarative qt5-wayland qt5-x11extras \
	qt6-5compat qt6-base qt6-declarative qt6-quick3d qt6-serialport quota-tools \
	r rav1e rdma-core realtime-privileges rtkit ruby ruby-bundled-gems \
	ruby-default-gems ruby-docs ruby-stdlib scx-scheds sdl sh smtp-forwarder \
	sndio speech-dispatcher spirv-tools sqlite subversion sudo svt-av1 \
	systemd-sysvcompat systemd-ukify tcl texlive-binextra \
	texlive-fontsrecommended texlive-latexrecommended tk tpm2-tss unixodbc \
	util-linux valkey vulkan-driver wayland wireless-regdb wl-clipboard \
	wpa_supplicant x11-ssh-askpass x264 xclip xorg-xauth xsel xterm xz \
	zlib --sudoloop --batchinstall --asdeps

    EOF
  done
esac
