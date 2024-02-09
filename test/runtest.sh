set -e
set -u

# Need to trim environment of anything that may taint our top-level port var
# fetching.
while read var; do
	case "${var}" in
	abs_top_builddir|\
	abs_top_srcdir|\
	srcdir|\
	bindir|\
	pkglibexecdir|\
	pkgdatadir|\
	VPATH|\
	am_check|am_installcheck|\
	CCACHE*|\
	PATH|\
	PWD|\
	TIMEOUT|\
	PARALLEL_JOBS|\
	TEST_NUMS|ASSERT_CONTINUE|TEST_CONTEXTS_PARALLEL|\
	URL_BASE|\
	VERBOSE|\
	SH_DISABLE_VFORK|TIMESTAMP|TRUSS|\
	HTML_JSON_UPDATE_INTERVAL|\
	TESTS_SKIP_BUILD|\
	TMPDIR|\
	SH) ;;
	*)
		unset "${var}"
		;;
	esac
done <<-EOF
$(env | cut -d= -f1)
EOF

TEST=$(realpath "$1")
: ${am_check:=0}
: ${am_installcheck:=0}

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin:${PATH}"

if [ "${am_check}" -eq 1 ] &&
	[ "${am_installcheck}" -eq 0 ]; then
	LIBEXECPREFIX="${abs_top_builddir}"
	export SCRIPTPREFIX="${abs_top_srcdir}/src/share/poudriere"
	export POUDRIEREPATH="poudriere"
	export PATH="${LIBEXECPREFIX}:${PATH}"
elif [ "${am_check}" -eq 1 ] &&
	[ "${am_installcheck}" -eq 1 ]; then
	LIBEXECPREFIX="${pkglibexecdir}"
	export SCRIPTPREFIX="${pkgdatadir}"
	#export POUDRIEREPATH="${bindir}/poudriere"
	export POUDRIEREPATH="poudriere"
	export PATH="${bindir}:${LIBEXECPREFIX}:${PATH}"
else
	if [ -z "${abs_top_srcdir-}" ]; then
		: ${VPATH:="$(realpath "${0%/*}")"}
		abs_top_srcdir="$(realpath "${VPATH}/..")"
		abs_top_builddir="${abs_top_srcdir}"
	fi
	LIBEXECPREFIX="${abs_top_builddir}"
	export SCRIPTPREFIX="${abs_top_srcdir}/src/share/poudriere"
	export POUDRIEREPATH="${abs_top_builddir}/poudriere"
	export PATH="${LIBEXECPREFIX}:${PATH}"
fi
if [ -z "${LIBEXECPREFIX-}" ]; then
	echo "ERROR: Could not determine POUDRIEREPATH" >&2
	exit 99
fi
: ${VPATH:=.}
: ${SH:=sh}
if [ "${SH}" = "sh" ]; then
	SH="${LIBEXECPREFIX}/sh"
fi

BUILD_DIR="${PWD}"
# source dir
THISDIR=${VPATH}
THISDIR="$(realpath "${THISDIR}")"
cd "${THISDIR}"

case "${1##*/}" in
prep.sh) : ${TIMEOUT:=1800} ;;
bulk*build*.sh|testport*build*.sh) : ${TIMEOUT:=1800} ;;
# Bump anything touching logclean
bulk*.sh|testport*.sh|distclean*.sh|options*.sh) : ${TIMEOUT:=500} ;;
locked_mkdir.sh) : ${TIMEOUT:=120} ;;
esac
case "${1##*/}" in
*build*)
	if [ -n "${TESTS_SKIP_BUILD-}" ]; then
		exit 77
	fi
	;;
esac
: ${TIMEOUT:=90}
: ${TIMESTAMP="${LIBEXECPREFIX}/timestamp" -t -1stdout: -2stderr:}

[ "${am_check}" -eq 0 ] && [ -t 0 ] && export FORCE_COLORS=1
exec < /dev/null

echo "Using SH=${SH}" >&2

rm -f "${TEST}.log.truss"

get_log_name() {
	echo "${TEST}${TEST_CONTEXT_NUM:+-${TEST_CONTEXT_NUM}}.log"
}

runtest() {
	export TEST_NUMS
	# With truss use --foreground to prevent process reaper and ptrace deadlocking.
	set -x
	${EXEC:+exec} \
	    /usr/bin/timeout ${TRUSS:+--foreground} ${TIMEOUT} \
	    ${TIMESTAMP} \
	    env \
	    ${SH_DISABLE_VFORK:+SH_DISABLE_VFORK=1} \
	    THISDIR="${THISDIR}" \
	    SH="${SH}" \
	    ${TRUSS:+truss -ae -f -s512 -o"$(get_log_name).truss"} \
	    "${SH}" "${TEST}"
}

_spawn_wrapper() {
	case $- in
	*m*)	# Job control
		# Don't stop processes if they try using TTY.
		trap '' SIGTTIN
		trap '' SIGTTOU
		;;
	*)	# No job control
		# Reset SIGINT to the default to undo POSIX's SIG_IGN in
		# 2.11 "Signals and Error Handling". This will ensure no
		# foreground process is left around on SIGINT.
		if [ ${SUPPRESS_INT:-0} -eq 0 ]; then
			trap - INT
		fi
		;;
	esac

	"$@"
}

spawn() {
	_spawn_wrapper "$@" &
}

spawn_job() {
	local -
	set -m
	spawn "$@"
}

if ! type setvar >/dev/null 2>&1; then
setvar() {
	[ $# -eq 2 ] || eargs setvar variable value
	local _setvar_var="$1"
	shift
	local _setvar_value="$*"

	read -r "${_setvar_var}" <<-EOF
	${_setvar_value}
	EOF
}
fi

getvar() {
	local _getvar_var="$1"
	local _getvar_var_return="$2"
	local ret _getvar_value

	eval "_getvar_value=\${${_getvar_var}-gv__null}"

	case "${_getvar_value}" in
	gv__null)
		_getvar_value=
		ret=1
		;;
	*)
		ret=0
		;;
	esac

	case "${_getvar_var_return}" in
	""|-)
		echo "${_getvar_value}"
		;;
	*)
		setvar "${_getvar_var_return}" "${_getvar_value}"
		;;
	esac

	return ${ret}
}

: ${TEST_CONTEXTS_PARALLEL:=4}

if [ "${TEST_CONTEXTS_PARALLEL}" -gt 1 ] &&
    grep -q get_test_context "${TEST}"; then
	{
		TEST_SUITE_START="$(clock -monotonic)"
		echo "Test suite started: $(date)"
		# hide set -x
	} >&2 2>/dev/null
	cleanup() {
		trap '' TERM INT HUP PIPE
		local jobs

		exec >/dev/null 2>&1
		jobs="$(jobs -p)"
		case "${jobs:+set}" in
		set)
			for pgid in ${jobs}; do
				kill -STOP -"${pgid}" || :
				kill -TERM -"${pgid}" || :
				kill -CONT -"${pgid}" || :
			done
			;;
		esac
		exit
	}
	trap exit TERM INT HUP PIPE
	trap cleanup EXIT
	TEST_CONTEXTS_TOTAL="$(env \
	    TEST_CONTEXTS_NUM_CHECK=yes \
	    THISDIR="${THISDIR}" \
	    SH="${SH}" \
	    "${SH}" "${TEST}" 2>/dev/null)"
	case "${TEST_CONTEXTS_TOTAL}" in
	[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;;
	*)
		echo "TEST_CONTEXTS_TOTAL is bogus value '${TEST_CONTEXTS_TOTAL}'" >&2
		exit 99
		;;
	esac
	TEST_CONTEXT_NUM=1
	until [ "${TEST_CONTEXT_NUM}" -gt "${TEST_CONTEXTS_TOTAL}" ]; do
		logname="$(get_log_name)"
		rm -f "${logname}"
		TEST_CONTEXT_NUM=$((TEST_CONTEXT_NUM + 1))
	done
	TEST_CONTEXT_NUM=1
	JOBS=0
	ret=0
	case "${TEST_CONTEXTS_TOTAL}" in
	[0-9]) num_width="01" ;;
	[0-9][0-9]) num_width="02" ;;
	[0-9][0-9][0-9]) num_width="03" ;;
	[0-9][0-9][0-9][0-9]) num_width="04" ;;
	*) num_width="05" ;;
	esac
	until [ "${TEST_CONTEXT_NUM}" -gt "${TEST_CONTEXTS_TOTAL}" ]; do
		until [ "${TEST_CONTEXT_NUM}" -gt "${TEST_CONTEXTS_TOTAL}" ] ||
		    [ "${JOBS}" -gt "${TEST_CONTEXTS_PARALLEL}" ]; do
			case " ${TEST_NUMS-null} " in
			" null ") ;;
			*" ${TEST_CONTEXT_NUM} "*) ;;
			*)
				TEST_CONTEXT_NUM="$((TEST_CONTEXT_NUM + 1))"
				continue
				;;
			esac
			logname="$(get_log_name)"
			printf "Logging %s with TEST_CONTEXT_NUM=%${num_width}d/%${num_width}d to %s\n" \
			    "${TEST}" \
			    "${TEST_CONTEXT_NUM}" \
			    "${TEST_CONTEXTS_TOTAL}" \
			    "${logname}" >&2
			job_test_nums="${TEST_CONTEXT_NUM}"
			TEST_NUMS="${job_test_nums}" \
			    spawn_job runtest > "${logname}" 2>&1
			pids="${pids:+${pids} }$!"
			JOBS="$((JOBS + 1))"
			setvar "pid_num_$!" "${TEST_CONTEXT_NUM}"
			TEST_CONTEXT_NUM="$((TEST_CONTEXT_NUM + 1))"
		done
		case "${pids:+set}" in
		set) ;;
		*) continue ;;
		esac
		echo "Waiting on pids: ${pids}" >&2
		until [ -z "${pids}" ]; do
			pwait -o -t 5 ${pids} >/dev/null 2>&1 || :
			pids_copy="${pids}"
			pids=
			for pid in ${pids_copy}; do
				if kill -0 "${pid}" 2>/dev/null; then
					pids="${pids:+${pids} }${pid}"
					continue
				fi
				getvar "pid_num_${pid}" pid_test_context_num
				pret=0
				wait "${pid}" || pret="$?"
				ret="$((ret + pret))"
				case "${pret}" in
				0)
					result="OK"
					;;
				*)
					result="FAIL"
					;;
				esac
				exit_type=
				case "${pret}" in
				0) exit_type="PASS" ;;
				*) exit_type="FAIL" ;;
				esac
				printf \
				    "%s TEST_CONTEXT_NUM=%d pid=%-5d exited %-3d - %s: %s\n" \
				    "${exit_type}" \
				    "${pid_test_context_num}" \
				    "${pid}" \
				    "${pret}" \
				    "$(TEST_CONTEXT_NUM="${pid_test_context_num}" get_log_name)" \
				    "${result}"
				JOBS="$((JOBS - 1))"
				case "${VERBOSE:+set}.${exit_type}" in
				set.FAIL)
					cat "$(TEST_CONTEXT_NUM="${pid_test_context_num}" get_log_name)"
					;;
				esac
			done
		done
	done
	{
		TEST_SUITE_END="$(clock -monotonic)"
		echo "Test suite ended: $(date) -- duration: $((TEST_SUITE_END - TEST_SUITE_START))s"
		# hide set -x
	} >&2 2>/dev/null
	exit "${ret}"
fi

EXEC=1 runtest
