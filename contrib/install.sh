#!/usr/bin/env sh
# shellcheck disable=3043
#
# Official installer for zoxide on UNIX systems.
#
# Parts of this script have been taken from Rustup.
# https://github.com/rust-lang/rustup/blob/5225e87a5d974ab5f1626bcb2a7b43f76ab883f0/rustup-init.sh

log() {
    echo "$1" >&2
}

err() {
    printf 'error: %s\n\nThe installer exited early. If you believe this was an error, please create an issue:\n\n    https://github.com/ajeetdsouza/zoxide/issues\n' "$1" >&2
    exit 1
}

check_cmd() {
    command -v "$1" >'/dev/null' 2>&1
}

need_cmd() {
    check_cmd "$1" || err "need '$1' (command not found)"
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    "$@" || err "command failed: $*"
}

get_bitness() {
    need_cmd 'head'
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.

    # Check for /proc by looking for the /proc/self/exe link
    # This is only run on Linux
    if ! test -L '/proc/self/exe'; then
        err 'unable to find /proc/self/exe. Is /proc mounted? Installation cannot proceed without /proc.'
    fi

    local _current_exe_head
    _current_exe_head="$(head -c 5 '/proc/self/exe')"

    case "${_current_exe_head}" in
    "$(printf '\177ELF\001')")
        echo '32'
        ;;
    "$(printf '\177ELF\002')")
        echo '64'
        ;;
    *)
        err 'unknown platform bitness'
        ;;
    esac
}

get_endianness() {
    local _cputype="$1"
    local _suffix_eb="$2"
    local _suffix_el="$3"

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd 'head'
    need_cmd 'tail'

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 /proc/self/exe | tail -c 1)"

    case "${_current_exe_endianness}" in
    "$(printf '\001')")
        echo "${_cputype}${_suffix_el}"
        ;;
    "$(printf '\002')")
        echo "${_cputype}${_suffix_eb}"
        ;;
    *)
        err 'unknown platform endianness'
        ;;
    esac
}

is_host_amd64_elf() {
    need_cmd 'head'
    need_cmd 'tail'
    # ELF e_machine detection without dependencies beyond coreutils.
    # Two-byte field at offset 0x12 indicates the CPU,
    # but we're interested in it being 0x3E to indicate amd64, or not that.
    local _current_exe_machine
    _current_exe_machine=$(head -c 19 '/proc/self/exe' | tail -c 1)
    [ "${_current_exe_machine}" = "$(printf '\076')" ]
}

get_architecture() {
    need_cmd 'uname'

    local _ostype
    local _cputype
    local _bitness
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"

    if [ "${_ostype}" = 'Linux' ]; then
        if [ "$(uname -o)" = 'Android' ]; then
            _ostype='Android'
        fi
    fi

    if [ "${_ostype}" = 'Darwin' ] && [ "${_cputype}" = 'i386' ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype='x86_64'
        fi
    fi

    if [ "${_ostype}" = 'SunOS' ]; then
        # Both Solaris and illumos presently announce as "SunOS" in "uname -s"
        # so use "uname -o" to disambiguate.  We use the full path to the
        # system uname in case the user has coreutils uname first in PATH,
        # which has historically sometimes printed the wrong value here.
        if [ "$(/usr/bin/uname -o)" = 'illumos' ]; then
            _ostype='illumos'
        fi

        # illumos systems have multi-arch userlands, and "uname -m" reports the
        # machine hardware name; e.g., "i86pc" on both 32- and 64-bit x86
        # systems.  Check for the native (widest) instruction set on the
        # running kernel:
        if [ "${_cputype}" = 'i86pc' ]; then
            _cputype="$(isainfo -n)"
        fi
    fi

    case "${_ostype}" in
    'Android')
        _ostype='linux-android'
        ;;
    'Linux')
        _ostype='unknown-linux-musl'
        _bitness="$(get_bitness)"
        ;;
    'FreeBSD')
        _ostype='unknown-freebsd'
        ;;
    'NetBSD')
        _ostype='unknown-netbsd'
        ;;
    'DragonFly')
        _ostype='unknown-dragonfly'
        ;;
    'Darwin')
        _ostype='apple-darwin'
        ;;
    'illumos')
        _ostype='unknown-illumos'
        ;;
    'MINGW'* | 'MSYS'* | 'CYGWIN'*)
        _ostype='pc-windows-msvc'
        ;;
    *)
        err "unrecognized OS type: ${_ostype}"
        ;;
    esac

    case "${_cputype}" in
    'i386' | 'i486' | 'i686' | 'i786' | 'x86')
        _cputype='i686'
        ;;
    'xscale' | 'arm')
        _cputype='arm'
        if [ "${_ostype}" = 'linux-android' ]; then
            _ostype='linux-androideabi'
        fi
        ;;
    'armv6l')
        _cputype='arm'
        if [ "${_ostype}" = 'linux-android' ]; then
            _ostype='linux-androideabi'
        else
            _ostype="${_ostype}eabihf"
        fi
        ;;
    'armv7l' | 'armv8l')
        _cputype='armv7'
        if [ "${_ostype}" = 'linux-android' ]; then
            _ostype='linux-androideabi'
        else
            _ostype="${_ostype}eabihf"
        fi
        ;;
    'aarch64' | 'arm64')
        _cputype='aarch64'
        ;;
    'x86_64' | 'x86-64' | 'x64' | 'amd64')
        _cputype='x86_64'
        ;;
    'mips')
        _cputype="$(get_endianness 'mips' '' 'el')"
        ;;
    'mips64')
        if [ "${_bitness}" -eq '64' ]; then
            # only n64 ABI is supported for now
            _ostype="${_ostype}abi64"
            _cputype="$(get_endianness 'mips64' '' 'el')"
        fi
        ;;
    'ppc')
        _cputype='powerpc'
        ;;
    'ppc64')
        _cputype='powerpc64'
        ;;
    'ppc64le')
        _cputype='powerpc64le'
        ;;
    's390x')
        _cputype='s390x'
        ;;
    'riscv64')
        _cputype='riscv64gc'
        ;;
    *)
        err "unknown CPU type: ${_cputype}"
        ;;
    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = 'unknown-linux-musl' ] && [ "${_bitness}" -eq '32' ]; then
        case "${_cputype}" in
        'x86_64')
            if [ -n "${CPUTYPE:-}" ]; then
                _cputype="${CPUTYPE}"
            else {
                # 32-bit executable for amd64 = x32
                if is_host_amd64_elf; then
                    err 'This host is running an x32 userland, which is currently unsupported. You will have to install multiarch compatibility with i686 and/or amd64, then select one by re-running this script with the CPUTYPE environment variable set to i686 or x86_64, respectively.'
                else
                    _cputype='i686'
                fi
            }; fi
            ;;
        'mips64')
            _cputype="$(get_endianness 'mips' '' 'el')"
            ;;
        'powerpc64')
            _cputype='powerpc'
            ;;
        'aarch64')
            _cputype='armv7'
            if [ "${_ostype}" = 'linux-android' ]; then
                _ostype='linux-androideabi'
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;
        'riscv64gc')
            err 'riscv64 with 32-bit userland unsupported'
            ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "${_ostype}" = 'unknown-linux-musleabihf' ] && [ "${_cputype}" = 'armv7' ]; then
        if ensure grep '^Features' '/proc/cpuinfo' | grep -q -v 'neon'; then
            # At least one processor does not have NEON.
            _cputype='arm'
        fi
    fi

    echo "${_cputype}-${_ostype}"
}

main() {
    if [ "${KSH_VERSION:-}" = 'Version JM 93t+ 2010-03-05' ]; then
        # The version of ksh93 that ships with many illumos systems does not
        # support the "local" extension.  Print a message rather than fail in
        # subtle ways later on:
        err 'this installer does not work with this ksh93 version; please try bash!'
    fi

    local arch
    arch="$(get_architecture)"

    log "Detected target triple: ${arch}"
}

# This is enclosed in braces so that nothing is executed until the entire script
# has downloaded.
{
    set -u
    main "$@"
}
