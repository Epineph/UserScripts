#!/usr/bin/env bash
#===============================================================================
# install-main-and-extra-packages.sh
#
# - Installs a "main" set of packages immediately.
# - Optionally installs a large "extra" set now or creates a helper script
#   that can install them later by calling this script with --install-extra.
#===============================================================================

set -euo pipefail

#-----------------------------#
#  Package definitions        #
#-----------------------------#

# Main, core packages you want installed right away.
main_pkgs=(
	singular
	polymake
	planarity
	pari
	normaliz
	nauty
	mpfi
	libxaw
	libmpc
	libsemigroups
	fplll
	cddlib
	c-xsc
	bliss
	fnm-bin
	github-cli
	sof-firmware
	goreleaser-pro-bin
	python-watchgod
	black-hole-solver
	lsd
	opam
	ocaml-bigarray-compat
	ocaml
	ocaml-pp
	ocaml-re
	ocaml-fmt
	ocaml-bos
	ocaml-gen
	ocaml-num
	ocaml-seq
	ocaml-csexp
	ocaml-pcre2
	ocaml-base
	ocamlbuild
	zinit
	zsh-autosuggestions
	zsh-autocomplete
	zsh-syntax-highlighting
	powerline
	nerd-fonts
	awesome-terminal-fonts
	bash-preexec
	oh-my-zsh-git
	find-the-command
	antigen-git
	zplug
	zsh-fast-syntax-highlighting
	zsh-eza-git
	zsh-manydots-magic
	zsh-fzf-plugin-git
	zsh-plugin-wd-git
	zsh-extract-git
	zsh-systemd-git
)

# Extra, optional packages you may want to install later or separately.
# -----------------------------------------------------------------------------
# Paste your *full* long list here, one package per line. For illustration, the
# first few and last entry are shown; replace the "..." with the rest of your
# list from the previous script.
# -----------------------------------------------------------------------------
extra_pkgs=(
	adwaita-cursors
	alsa-lib
	apparmor
	appstream
	aspell
	assimp
	audispd-plugins
	audispd-plugins-zos
	avisynthplus
	base-devel
	bash
	bash-completion
	bat
	biber
	blas-openblas
	bluez
	boost-libs
	btrfs-progs
	bzip2
	ca-certificates
	cairo
	# ...
	# (Insert all the remaining packages from your giant list here.)
	# ...
	zlib
)

#-----------------------------#
#  Helper functions           #
#-----------------------------#

function install_main_pkgs() {
	echo "Installing main packages..."
	gen_log yay --sudoloop --batchinstall -S --needed "${main_pkgs[@]}"
}

function install_extra_pkgs() {
	if ((${#extra_pkgs[@]} == 0)); then
		echo "No extra packages configured in extra_pkgs array." >&2
		return 1
	fi

	echo "Installing extra packages..."
	gen_log yay --sudoloop --batchinstall -S --needed \
		"${extra_pkgs[@]}" --asdeps
}

#-----------------------------#
#  Argument-based mode        #
#-----------------------------#

# Special mode: only install extra packages and exit.
if [[ "${1-}" == "--install-extra" ]]; then
	install_extra_pkgs
	exit 0
fi

#-----------------------------#
#  Interactive main flow      #
#-----------------------------#

Default_Extra_Pkg_Dir="${HOME}/extra-packages"
this_script_path="$(realpath "$0")"

install_main_pkgs

echo
echo "Additional packages options:"
echo "  1) Install extra packages now"
echo "  2) Save a small helper script for later"
echo "  3) Skip extra packages (default)"
echo "  4) Don't save or install extra packages"
read -r -p "Choose (1-4): " choice
choice=${choice,,}

case "$choice" in
1 | install)
	echo
	install_extra_pkgs
	;;

2 | save | later)
	echo
	echo "Save location options:"
	echo "  1) Current directory: ${PWD}"
	echo "  2) Default directory: ${Default_Extra_Pkg_Dir}"
	echo "  3) Custom directory"
	echo "  4) Don't backup or install and exit script"
	read -r -p "Choose save location (1-4, default is 2): " location_choice

	case "$location_choice" in
	1)
		save_dir="$PWD"
		;;
	3 | custom)
		read -r -p "Enter custom directory path: " custom_dir
		save_dir="$custom_dir"
		;;
	4 | cancel)
		echo "Not backing up or installing extra script."
		exit 1
		;;
	* | "")
		save_dir="$Default_Extra_Pkg_Dir"
		;;
	esac

	if [[ ! -d "$save_dir" ]]; then
		echo
		echo "User chose to save extra-package helper at: ${save_dir}"
		echo "Directory not found; creating it..."
		mkdir -p "$save_dir"
	fi

	script_path="${save_dir}/install-additional.sh"
	echo
	echo "Saving helper installation script to: ${script_path}"

	# The helper script just calls this script in "--install-extra" mode.
	cat >"$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${this_script_path}" --install-extra
EOF

	chmod +x "$script_path"
	echo "Saved and marked ${script_path} as executable."
	;;

3 | skip | "")
	echo
	echo "Skipping extra packages."
	;;

4 | no | never)
	echo
	echo "Not saving or installing extra packages."
	;;

*)
	echo
	echo "Unrecognised choice '${choice}'; skipping extra packages." >&2
	;;
esac
