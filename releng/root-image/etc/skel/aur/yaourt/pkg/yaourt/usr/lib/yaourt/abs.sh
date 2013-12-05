#!/bin/bash
#
# abs.sh 
# This file is part of Yaourt (http://archlinux.fr/yaourt-en)

RSYNCCMD=$(type -p rsync 2> /dev/null)
RSYNCOPT="-mrtv --no-motd --no-p --no-o --no-g"
ABSCONF=0

load_lib alpm_query
load_lib pkgbuild

# source abs configuration
source_abs_conf() {
	((ABSCONF)) && return || ABSCONF=1
	local vars=()
	local abs_conf
	[[ ! $SYNCSERVER ]] && vars+=(SYNCSERVER)
	[[ ! $REPOS ]] && vars+=(REPOS)
	if [[ $vars ]]; then
		abs_conf=$(
			[[ -r "/etc/abs.conf" ]] &&
			    source  "/etc/abs.conf" > /dev/null
			[[ -r ~/.abs.conf ]] &&
			    source  ~/.abs.conf > /dev/null
			declare -p ${vars[*]} 2>/dev/null | tr '\n' ';'
		)
		[[ ! $abs_conf ]] && return
		# Change vars names because "declare" create a local var
		abs_conf=${abs_conf//SYNCSERVER/_SYNCSERVER}
		abs_conf=${abs_conf//REPOS/_REPOS}
		eval "$abs_conf"
		SYNCSERVER=${SYNCSERVER:-$_SYNCSERVER}
		[[ ! $REPOS ]] && REPOS=(${_REPOS[@]})
	fi
}

# Get sources in current dir
# Usage abs_get_pkgbuild ($repo/$pkg[,$arch,[$pkgbase]])
abs_get_pkgbuild() {
	source_abs_conf
	local repo=${1%/*} pkg=${1#*/} arch=$2 pkgbase=$3 pkgver=
	if [[ ! $arch || ! $pkgbase ]]; then
		read arch pkgver < <(pkgquery -1Sif '%a %v' "$repo/$pkg")
		pkgbase=$(get_pkgbase $pkg $repo $pkgver)
	fi
	if [[ $RSYNCCMD && $SYNCSERVER && " ${REPOS[*]} " =~ " $repo " ]]; then
		$RSYNCCMD $RSYNCOPT "$SYNCSERVER::abs/$arch/$repo/$pkgbase/" . && return 0
	fi
	# TODO: store abs archive somewhere else.
	local abs_tar="$YAOURTTMPDIR/$repo.abs.tar.gz"
	local abs_url 
	local repo_date=$(stat -c "%Z" "${P[dbpath]}/sync/$repo.db")
	local abs_repo_date=$(stat -c "%Z" "$abs_tar" 2> /dev/null)
	if [[ ! $abs_repo_date ]] || (( ${abs_repo_date%.*} < ${repo_date%.*} )); then
		abs_url=$(pkgquery -1Sif "%u" "$repo/$pkg")
		abs_url="${abs_url%/*}/$repo.abs.tar.gz"
		msg "$repo/$pkgbase: $(gettext 'Download abs archive')"
		curl_fetch -f -# "$abs_url" -o "$abs_tar" || return 1
	fi
	bsdtar --strip-components 2 -xvf "$abs_tar" "$repo/$pkgbase"
}
	
# Build from abs or aur
build_pkg() {
	[[ $1 ]] || return 1
	while [[ $1 ]]; do
		local repo pkg=${1#*/}
		[[ $1 != $pkg ]] && repo=${1%/*} || repo="$(sourcerepository "$pkg")"
		if [[ $repo = "aur" || $repo = "local" ]]; then
			install_from_aur "$pkg"
		else
			BUILD=1 install_from_abs "$repo/$pkg"
		fi
		shift;
	done
}

# Build packages from repos
install_from_abs() {
	local cwd build_deps
	declare -a pkginfo=($(pkgquery -1Sif "%r %n %v %a" "$1"))
	(( ! BUILD )) && ! custom_pkg "${pkginfo[1]}" &&
	  bin_pkgs+=("${pkginfo[0]}/${pkginfo[1]}") && continue
	(( BUILD > 1 )) && build_deps=1 || build_deps=0
	msg $(_gettext 'Building %s from sources.' "${pkginfo[1]}")
	title $(_gettext 'Install %s from sources' "${pkginfo[1]}")
	echo
	msg $(gettext 'Retrieving PKGBUILD and local sources...')
	cwd=$(pwd)
	init_build_dir "$YAOURTTMPDIR/abs-${pkginfo[1]}" || return 1
	abs_get_pkgbuild ${pkginfo[0]}/${pkginfo[1]} ${pkginfo[3]} ||
	  { cd "$cwd"; return 1; }

	# Build, install/export
	BUILD=$build_deps package_loop ${pkginfo[1]} 1 ||
	  manage_error ${pkginfo[1]} ||
	  { cd "$cwd"; return 1; }
	cd "$cwd"
	rm -rf "$YAOURTTMPDIR/abs-${pkginfo[1]}"
}

# Set vars:
# upgrade_details=(new release, new version then new pkgs)
# srcpkgs=(pkgs with a custom pkgbuild)
# pkgs=(others)
# usage: classify_pkg $pkg_nb < [one pkg / line ] 
# read from stdin: pkgname repo rversion lversion outofdate pkgdesc
classify_pkg() {
	declare -a newrelease newversion newpkgs
	unset srcpkgs pkgs
	longestpkg=(0 0) 
	local i=0 bar="|/-\\"
	local pkgname repo rversion lversion outofdate pkgdesc maintainer \
	      pkgver lrel rrel lver rver
	local prefix=''
	if ((DETAILUPGRADE<2)); then
		((REFRESH)) && printf -vprefix "\r " || printf -vprefix "\r"
	fi
	while read pkgname repo rversion lversion outofdate maintainer pkgdesc; do
		printf -v pkgdesc "%q" "$pkgdesc"
		if [[ "$repo" = "aur" && ${lversion#-} ]] || [[ "$repo" = "local" ]]; then
			((DETAILUPGRADE<2)) && echo -en "$prefix$(gettext 'Foreign packages: ')${bar:$((++i%4)):1} $i / $1"
			[[ "$repo" = "local" ]] && continue
			aur_update_exists "$pkgname" "$rversion" "$lversion" "$outofdate" "$maintainer" \
				|| continue
		fi
		custom_pkg "$pkgname" && srcpkgs+=("$repo/$pkgname") || pkgs+=("$repo/$pkgname")
		if [[ "$lversion" != "-" ]]; then
			pkgver=$lversion
			lrel=${lversion#*-}
			rrel=${rversion#*-}
			lver=${lversion%-*}
			rver=${rversion%-*}
			if [[ "$rver" = "$lver" ]]; then
				# new release not a new version
				newrelease+=("1 $repo $pkgname $pkgver $lrel $rrel $pkgdesc")
			else
		        # new version
				newversion+=("2 $repo $pkgname $pkgver $rversion - $pkgdesc")
			fi
		else
			# new package (not installed at this time)
			pkgver=$rversion
			local requiredbypkg=""
			local pkg_dep_on=( $(pkgquery -S --qdepends -f "%n" "$pkgname") )
			for pkg in ${pkg_dep_on[@]}; do
				[[ " ${packages[@]} " =~ " $pkg " ]] &&	requiredbypkg=$pkg && break
			done
			[[ ! $requiredbypkg ]] && requiredpkg=$(pkgquery -Sf'%R' "$pkgname")
			[[ ! ${requiredbypkg#-} ]] && requiredpkg=$(printf "%q" "$(gettext 'not found')")
			newpkgs+=("3 $repo $pkgname $pkgver $requiredbypkg - $pkgdesc")
		fi
		(( ${#repo} + ${#pkgname} > longestpkg[0] )) && longestpkg[0]=$(( ${#repo} + ${#pkgname}))
		(( ${#pkgver} > longestpkg[1] )) && longestpkg[1]=${#pkgver}
	done 
	((DETAILUPGRADE<2)) && echo
	(( longestpkg[1]+=longestpkg[0] ))
	upgrade_details=("${newrelease[@]}" "${newversion[@]}" "${newpkgs[@]}")
}

display_update() {
	# Show result
	show_upgrades lite
        
	# Show detail on upgrades
	while true; do
		echo
		msg "$(gettext 'Continue upgrade ?') $(yes_no 1)"
		prompt "$(gettext '[V]iew package detail   [M]anually select packages')"
		local answer=$(userinput "YNVM" "Y")
		case "$answer" in
			V) show_upgrades full;;
			M) show_upgrades manual
			   run_editor "$YAOURTTMPDIR/sysuplist" 0
			   SYSUPGRADE=2
			   SP_ARG="" sync_packages "$YAOURTTMPDIR/sysuplist"
			   return 2
			   ;;
			N) return 1;;
			*) break;;
		esac
	done
}

show_targets() {
	local t="$(gettext "$1") "; shift
	t+="($#): "
	echo
	echo_wrap_next_line "$CYELLOW$t$C0" ${#t} "$*" 
	echo
	prompt "$(gettext 'Proceed with upgrade? ') $(yes_no 1)"
	useragrees 
}	

# Searching for packages to update, buid from sources if necessary
sysupgrade() {
	local packages pkgs pkg
	declare -a aur_up pkg_up
	local pkg_foreign=0
	if ((AURUPGRADE)); then
		if [[ $ARGS ]]; then
			pkg_up=($(pkgquery -1Siif '%n' "${ARGS[@]}"))
			if (( ${#ARGS[@]} > ${#pkg_up[@]} )); then
				aur_up=($(pkgquery -1Aiif '%n' "${ARGS[@]}"))
			fi
		fi
	else
		pkg_up=("${ARGS[@]}")
	fi
	(( UP_NOCONFIRM )) && { EDITFILES=0 AURCOMMENT=0; BUILD_NOCONFRIM=1; }
	(( UPGRADES > 1 )) && local _arg="-uu" || local _arg="-u"
	if (( ! DETAILUPGRADE )); then
		(( REFRESH )) && _arg+="y"
		(( REFRESH>1 )) && _arg+="y"
		su_pacman -S "${PACMAN_S_ARG[@]}" $_arg "${pkg_up[@]}" || return $?
	else	
		pacman_parse -Sp --print-format "## %n" \
		             --noconfirm $_arg "${PACMAN_S_ARG[@]}" \
		             "${pkg_up[@]}" 1> "$YAOURTTMPDIR/sysupgrade" ||
			{ grep -v '^## ' "$YAOURTTMPDIR/sysupgrade"; return 1; }
		packages=($(sed -n 's/^## \(.*\)/\1/p' "$YAOURTTMPDIR/sysupgrade"))
		rm "$YAOURTTMPDIR/sysupgrade"
	fi
	#[[ ! "$packages" ]] && return 0	
	local cmd="echo -n"
	[[ $packages ]] && cmd+='; pkgquery -1Sif "%n %r %v %l - - %d" "${packages[@]}"'
	if ((AURUPGRADE)); then
		# TODO: %m return the maintainer for AUR package and packager for local packages.
		# AUR username does not contain spaces.
		# packager does, but for now, local packages are not parsed by classify_pkg()
		cmd+='; pkgquery -AQmf "%n %r %v %l %o %m %d"'
		[[ $aur_up ]] && cmd+='; pkgquery -Aif "%n %r %v - %o %m %d" "${aur_up[@]}"'
		((DETAILUPGRADE<2)) && pkg_foreign=$(pacman_parse -Qqm | wc -l)
	fi
	classify_pkg $pkg_foreign < <(eval $cmd)
	(( BUILD )) && srcpkgs+=("${pkgs[@]}") && unset pkgs
	if [[ $srcpkgs ]]; then 
		show_targets 'Source targets' "${srcpkgs[@]#*/}" || return 0
		build_pkg "${srcpkgs[@]}" 
		local ret=$?
		[[ $pkgs ]] || return $ret
	fi
	[[ $pkgs ]] || return 0
	if (( ! DETAILUPGRADE )); then
		show_targets 'AUR targets' "${pkgs[@]#aur/}" || return 0
	else
		display_update || return 0
		if [[ ${pkgs[*]##aur/*} ]]; then
			su_pacman -S "${PACMAN_S_ARG[@]}" $_arg "${pkg_up[@]}" || return $?
		fi
	fi
	for pkg in ${pkgs[@]}; do
		[[ ${pkg#aur/} = $pkg ]] && continue
		install_from_aur "$pkg" || error $(_gettext 'unable to update %s' "$pkgname")
	done
}

	
# Show package to upgrade
show_upgrades() {
	# $1=full or $1=lite or $1=manual
	if [[ "$1" = "manual" ]]; then
		> "$YAOURTTMPDIR/sysuplist"
		local separator=$(echo_fill "" "#" "")
	fi
	
	local exuptype=0 line _msg requiredbypkg
	for line in "${upgrade_details[@]}"; do
		eval line=($line)
		if (( exuptype != ${line[0]} )); then
			case "${line[0]}" in
				1) _msg="$(gettext 'Package upgrade only (new release):')";;
				2) _msg="$(gettext 'Software upgrade (new version) :')";;
				3) _msg="$(gettext 'New package :')";;
			esac
			exuptype=${line[0]}
			if [[ "$1" = "manual" ]]; then
				echo -e "\n$separator\n# $_msg\n$separator" >> "$YAOURTTMPDIR/sysuplist"
			else
				echo
				msg "$_msg"
			fi
		fi
		if [[ "$1" = "manual" ]]; then
			echo -n "${line[1]}/${line[2]} # " >> "$YAOURTTMPDIR/sysuplist"
			case "${line[0]}" in
				1) echo "${line[3]} ${line[4]} -> ${line[5]}";;
				2) echo "${line[3]} -> ${line[4]}";;
				3) requiredbypkg=${line[4]}
				   echo "${line[3]} $(_gettext '(required by %s)' "$requiredbypkg")";;
			esac >> "$YAOURTTMPDIR/sysuplist"
			echo "# ${line[6]}" >> "$YAOURTTMPDIR/sysuplist"
		else
			case "${line[0]}" in
				1) printf "%*s   $CBOLD%s$C0 -> $CRED%s$C0" ${longestpkg[1]} "" "${line[4]}" "${line[5]}";;
				2) printf "%*s   -> $CRED%s$C0" ${longestpkg[1]} "" "${line[4]}";;
				3) requiredbypkg=${line[4]}
				   printf "%*s   $CRED%s$C0" ${longestpkg[1]} "" "$(_gettext '(required by %s)' "$requiredbypkg")";;
			esac
			printf "\r%-*s  $CGREEN%s$C0" ${longestpkg[0]} "" "${line[3]}"
			echo -e "\r${C[${line[1]}]:-${C[other]}}${line[1]}/$C0${C[pkg]}${line[2]}$C0"
			if [[ "$1" = "full" ]]; then
				echo_wrap 4 "${line[6]}"
			fi
		fi
	done
}		

unset SP_ARG
# Sync packages
sync_packages() {
	# Install from a list of packages
	if [[ -f $1 ]] && file -b "$1" | grep -qi text ; then
		if (( ! SYSUPGRADE )); then 
			title $(gettext 'Installing from a package list')
			msg $(gettext 'Installing from a package list')
		fi
		AURVOTE=0
		set -- `grep -o '^[^#[:space:]]*' "$1"`
	fi
	[[ $1 ]] || return 0
	# Install from arguments
	declare -A pkgs_search pkgs_found
	declare -a repo_pkgs aur_pkgs bin_pkgs
	local _pkg _arg repo pkg target 
	for _pkg in "$@"; do pkgs_search[$_pkg]=1; done
	# Search for exact match, pkg which provides it, then in AUR
	while read repo pkg target; do
		((pkgs_search[$target])) || continue
		unset pkgs_search[$target]
		((pkgs_found[$pkg])) && continue
		pkgs_found[$pkg]=1
		[[ "${repo}" != "aur" ]] && repo_pkgs+=("${repo}/${pkg}") || aur_pkgs+=("$pkg")
	done < <(pkgquery -f "%r %n %t" -1SAii "${!pkgs_search[@]}")
	# In case there is a double version check, eg. pkg1>0.1 pkg2<0.3
	# package-query does only one check, so perform the remaining checks
	for pkg in "${!pkgs_search[@]}"; do
		_pkg=${pkg%%[<>=]*}
		if [[ " ${!pkgs_found[@]} " =~ " $_pkg " ]]; then
			pkgquery -q -1SAii "$pkg" && unset pkgs_search[$pkg]
		fi
	done
	bin_pkgs=("${!pkgs_search[@]}")
	for _pkg in "${repo_pkgs[@]}"; do
		[[ $SP_ARG ]] && pkgquery -Qq "$_pkg" && continue
		install_from_abs "$_pkg" || return 1
	done
	if [[ $bin_pkgs ]]; then
		if [[ $SP_ARG ]]; then
			su_pacman -S --asdeps --needed "${PACMAN_S_ARG[@]}" "${bin_pkgs[@]}" || return 1
		else
			su_pacman -S "${PACMAN_S_ARG[@]}" "${bin_pkgs[@]}" || return 1
		fi
	fi
	for _pkg in "${aur_pkgs[@]}"; do
		[[ $SP_ARG ]] && pkgquery -Qq "$_pkg" && continue
		install_from_aur "$_pkg" || return 1
	done
	return 0
}

# Search to upgrade devel package 
upgrade_devel_package() {
	declare -a devel_pkgs
	title $(gettext 'upgrading SVN/CVS/HG/GIT package')
	msg $(gettext 'upgrading SVN/CVS/HG/GIT package')
	local _arg="-Qq" pkg
	((AURDEVELONLY)) && _arg+="m"
	for pkg in $(pacman_parse $_arg | grep "\-\(svn\|cvs\|hg\|git\|bzr\|darcs\)$")
	do
		is_package_ignored "$pkg" && continue
		devel_pkgs+=($pkg)
	done
	[[ $devel_pkgs ]] || return 0
	show_targets 'Targets' "${devel_pkgs[@]}" && build_pkg "${devel_pkgs[@]}"
}


# vim: set ts=4 sw=4 noet: 
