# Check if we have been included already
[[ -n "${SNMPD_CONNECTOR_LIB_LOADED+x}" ]] && return || SNMPD_CONNECTOR_LIB_LOADED="true"

# We rely on some functions from hacking-bash.sh
[[ ! -r "${HACKING_BASH_LIB_PATH:=/usr/lib/hacking-bash.sh}" ]] && \
    echo "Unable to find ${HACKING_BASH_LIB_PATH}" && exit 1
# shellcheck disable=SC1090
source "${HACKING_BASH_LIB_PATH}"

# Functions to handle request types
function handle_ping
{
	echo "PONG"
}

# Function to handle an unknown query
#
#	@in_param	$1 - The query type.
#
function handle_unknown_query
{
	error_echo "ERROR [Unknown Query]"
	[[ -n ${DEBUG} ]] && logger -p local1.warn "Unknown query: ${1}"
}

# Function to handle a query for an unknown OID
#
#	@in_param	$1 - The OID this query was for.
#
function handle_unknown_oid
{
	send_none
	debug_echo "GET request for unknown OID: ${1}"
}

# Function to handle a SET request.
#
function handle_set
{
	local OID VALUE
	
	read -r OID
	read -r VALUE
	echo "not-writable"
	debug_echo "Attempt to SET ${OID} to ${VALUE}"
}

# Function to split the requested OID into component parts
#
#	@in_param	$1 - The base OID which this should be a request for
#	@in_param	$2 - The OID to split
#	@out_param	$3 - An array containing the request elements 
#
function split_request_oid
{	
	local ROID RFA BWD 

	# If the requested OID doesn't start with our base OID then we're done already.
	if [[ "${2}" != ${1}* ]]; then
		send_none
		debug_echo "unknown base OID: ${2}"
		return 1
	fi
		
	# Split off our BASE_OID to get a R[elative]OID and then remove the leading "." of that ROID.
	BWD="${1}" 
	ROID=${2#${BWD}}
	ROID=${ROID#.}

	# If we got no R[elative]OID then we're done already.
	[[ -z "${ROID}" ]] && return 2

	# Split the ROID around the dots to get the fields for this request to get a R[equest]F[ield]A[rray].
	IFS="." read -r -a RFA <<< "${ROID}"

	# If we got some array elements then place them in $3 and indicate success
	if (( ${#RFA[@]} > 0  )); then
		eval "$3=(${RFA[*]})"
		return
	fi
	
	# Indicate failure.
	return 3 
}

# Function to get and split the request OID
#
#	@in_param	$1 - The base OID to split off first
#	@out_param	$2 - The complete OID
#	@out_param	$3 - An array containing the request elements
#
function get_and_split_request_oid
{
	local TOID RAY=""
	
	# Read the OID this request is for
	read -r TOID
	
	# If we were passed an empty string then we're done already.
	[[ -z "${TOID}" ]] && return 1
	
	eval "$2=\"${TOID}\""
	split_request_oid "$1" "${TOID}" RAY
	[[ $? ]] && eval "$3=(${RAY[*]})" || return 2
}

# Helper function to send NONE
#
#	@in_param	$1 - The (optional) OID to send before the data
#
function send_none
{
	if (( $# > 0 )); then
		echo "${1}"
		echo "NONE"
		echo "N/A"
		debug_echo "Sent [${1}] NONE N/A"
	else
		echo "NONE"
		debug_echo "Sent NONE"
	fi
}

# Helper function to send an integer - called: send_integer OID value
#
#	@in_param	$1 - The OID to send before the data
#	@in_param	$2 - The VALUE to send
#
function send_integer
{
	debug_echo "Sent ${1} INTEGER ${2}"
	echo "${1}"
	echo "integer"
	echo "${2}"
}

# Helper function to send an integer - called: send_boolean OID value
#
#	@in_param	$1 - The OID to send before the data
#	@in_param	$2 - The VALUE to send (T for true, F for false)
#
function send_boolean
{
	debug_echo "Sent ${1} TruthValue ${2}"
	echo "${1}"
	echo "integer"
	[[ "${2}" == "T" ]] && echo 1 || echo 2
}

# Helper function to send a string - called: send_string OID value
#
#	@in_param	$1 - The OID to send before the data
#	@in_param	$2 - The VALUE to send
#
function send_string
{
	debug_echo "Sent ${1} STRING ${2}"
	echo "${1}"
	echo "string"
	echo "${2}"
}

# Helper function to send a gauge - called: send_gauge OID value
#
#	@in_param	$1 - The OID to send before the data
#	@in_param	$2 - The VALUE to send
#
function send_gauge
{
	debug_echo "Sent ${1} GAUGE ${2}"
	echo "${1}"
	echo "gauge"
	echo "${2}"
}

# Function to handle GETNEXT requests
#
#	@in_param	$1 - The name of an array, prefixed with a #, from which to retrieve
#					 either the command to execute or the name of another array.
#	@in_param	$2 - The OID to send along with this request
#	@in_param	$3 - The base OID this is a request for
#	@in_param	$+ - An array containing the request elements
#
function handle_getnext
{
	local TABLE SOID BOID RA NEXTOID

	# Extract parameters
	TABLE="${1}";	shift
	SOID="${1}";	shift
	BOID="${1}";	shift
	RA="${*}"
	
	# If we were not passed the name of a table in $1 then we're done so log an
	# error, send NONE and return.
	if [[ "${TABLE}" != \#* ]]; then
		error_echo "handle_getnext: parameter 1 is not a table!"
		send_none
		return 1
	fi  

	# Get the next OID - we want ${RA} to split.
	# shellcheck disable=SC2086
	NEXTOID=$(get_next_oid "${TABLE}" "${BOID}" ${RA})
	[[ -n "${NEXTOID}" ]] && debug_echo "got NEXTOID = ${NEXTOID}"

	# If we didn't get a next OID then log a warning and send NONE instead and
	# return.
	if [[ -z "${NEXTOID}" ]]; then
		debug_echo "got no NEXTOID, using NONE instead"
		send_none
		return 1
	fi
			
	# Handle the new request.
	local RARRAY
	split_request_oid "${BOID}" "${NEXTOID}" RARRAY
	handle_get "${TABLE}" "${NEXTOID}" "${BOID}" "${RARRAY[@]}" 
}

# Function to get the next OID
#
#	@in_param	$1 - The name of an array, prefixed with a #, from which to retrieve
#					 either the command to execute or the name of another array.
#	@in_param	$2 - The base OID this is a request for.
#	@in_param	$+ - An array containing the request elements, if any.
#
function get_next_oid
{
	local TABLE BOID INDEX DTABLE NEWOID NINDEX

	# Extract parameters, ${@} will now contain the request elements (if any).
	TABLE="${1}";	shift
	TABLE="${TABLE#\#}"
	BOID="${1}";	shift
	
	# If we have no request elements then this is a speculative query to find the first OID
	if (( $# == 0 )); then
		debug_echo "got speculative request"
		
		# Find the first index in the table
		INDEX=$(get_next_array_index "$TABLE")
		debug_echo "found first index [${INDEX}]"
		DTABLE="${TABLE}[${INDEX}]"
		debug_echo "calculated table variable: ${DTABLE}"

		# If the deferenced value of DTABLE starts with a # then it is a redirect to
		# another table.
		if [[ "${!DTABLE}" == \#* ]]; then
			debug_echo "found a redirect to a table: ${!DTABLE}"
			NEWOID=$(get_next_oid "${!DTABLE}" "${BOID}.${INDEX}")
			debug_echo "got new OID: ${NEWOID}"
			echo "${NEWOID}"
			return
		fi
		
		# If we got this far then we have found a command in the table, not a redirect to
		# another table.  To see if it is an indexed command (a table) we will look for an
		# index function.
		local INDEX_FUNCTION_VARIABLE
		debug_echo "found a command"
		INDEX_FUNCTION_VARIABLE="${TABLE}_INDEX"
		if is_defined_and_set "${INDEX_FUNCTION_VARIABLE}"; then
			debug_echo "found an index function: ${!INDEX_FUNCTION_VARIABLE}"
			NINDEX=$(${!INDEX_FUNCTION_VARIABLE})
			debug_echo "got next table index: ${NINDEX}"
			NEWOID="${BOID}.${INDEX}.${NINDEX}"
			debug_echo "calculated OID: ${NEWOID}"
			echo "${NEWOID}"
			return
		fi
		
		# If we got this far then we have found a command in the table, not a redirect to
		# another table AND it is NOT an indexed command (a table).  We can return the
		# BASE OID + the index we calculated earlier.
		debug_echo "no index function found"
		NEWOID="${BOID}.${INDEX}"
		debug_echo "calculated OID: ${NEWOID}"
		echo "${NEWOID}"
		return
	fi
	
	# If we got this far then we have some request elements in ${@}.
	debug_echo "got addressed request"
	INDEX="${1}"
	shift
	debug_echo "passed index [${INDEX}]"
	
	# If the index value is zero then use the first available index.
	(( INDEX == 0 )) && INDEX=$(get_next_array_index "$TABLE")
	
	# Calculate table variable
	DTABLE="${TABLE}[${INDEX}]"
	debug_echo "calculated table variable: ${DTABLE}"

	# If the deferenced value of DTABLE starts with a # then it is a redirect to
	# another table.
	if [[ "${!DTABLE}" == \#* ]]; then
		# Try to get the next OID from this table
		debug_echo "found a redirect to a table: ${!DTABLE}"
		NEWOID=$(get_next_oid "${!DTABLE}" "${BOID}.${INDEX}" "${@}")
		
		# If we got a new OID then...
		if [[ -n "${NEWOID}" ]]; then
			debug_echo "got new OID: ${NEWOID}"
			echo "${NEWOID}"
			return
		fi
		
		# We didn't get a new OID so try to find the next OID from the next entry 
		# in the current table.
		debug_echo "no new OID"
		NINDEX=$(get_next_array_index "$TABLE" "$INDEX")
		if [[ -n "${NINDEX}" ]]; then
			DTABLE="${TABLE}[${NINDEX}]"
			debug_echo "using next table entry: ${DTABLE}"
			
			# If the deferenced value of DTABLE starts with a # then it is a redirect to
			# another table.
			if [[ "${!DTABLE}" == \#* ]]; then
				debug_echo "found a redirect to a table: ${!DTABLE}"
				NEWOID=$(get_next_oid "${!DTABLE}" "${BOID}.${NINDEX}")
				debug_echo "got new OID: ${NEWOID}"
			else
				NEWOID="${BOID}.${NINDEX}"
				debug_echo "calculated new OID: ${NEWOID}"
			fi
			
			echo "${NEWOID}"
			return
		fi

		debug_echo "no next table entry after: ${TABLE}[${INDEX}]"
		return
	fi
	
	# If we got this far then we have found a command in the table, not a redirect to
	# another table.  To see if it is an indexed command (a table) we will look for an
	# index function.
	local INDEX_FUNCTION_VARIABLE
	debug_echo "found a command"
	INDEX_FUNCTION_VARIABLE="${TABLE}_INDEX"
	if is_defined_and_set "${INDEX_FUNCTION_VARIABLE}"; then
		debug_echo "found an index function: ${!INDEX_FUNCTION_VARIABLE}"

		# If we have a starting index use it, otherwise get the first index
		(( $# > 0 )) && NINDEX=$(${!INDEX_FUNCTION_VARIABLE} "${1}") || NINDEX=$(${!INDEX_FUNCTION_VARIABLE})
		
		# If we got a next index from the index function then return it.
		if [[ -n "${NINDEX}" ]]; then
			debug_echo "got next table index: ${NINDEX}"
			NEWOID="${BOID}.${INDEX}.${NINDEX}"
			debug_echo "calculated OID: ${NEWOID}"
			echo "${NEWOID}"
			return
		fi
			
		# If we got this far then the index would be out of range so we need to move on
		# to the next table entry.
		debug_echo "next index would be out of range"
		NINDEX=$(get_next_array_index "$TABLE" "$INDEX")
		if [[ -n "${NINDEX}" ]]; then
			DTABLE="${TABLE}[${NINDEX}]"
			debug_echo "using next table entry: ${DTABLE}"
			NTINDEX=$(${!INDEX_FUNCTION_VARIABLE})
			NEWOID="${BOID}.${NINDEX}.${NTINDEX}"
			debug_echo "calculated OID: ${NEWOID}"
			echo "${NEWOID}"
		fi												
		return
	fi
	
	# If we got this far then we have found a command in the table, not a redirect to
	# another table AND it is NOT an indexed command (a table).
	debug_echo "no index function found"
	
	# Calculate the new index
	NINDEX=$(get_next_array_index "$TABLE" "$INDEX")
	
	# If we got a new index then create a new OID and return it.
	if [[ -n "${NINDEX}" ]]; then
		NEWOID="${BOID}.${NINDEX}"
		debug_echo "calculated OID: ${NEWOID}"
		echo "${NEWOID}"
		return
	fi
	
	# If we got this far then we have no next index so return nothing.
	debug_echo "no next index found after: ${TABLE}[${INDEX}]"
}


# Function to handle GET requests
#
#	@in_param	$1 - The name of an array, prefixed with a #, from which to retrieve
#					 either the command to execute or the name of another array.
#	@in_param	$2 - The OID to send along with this request
#	@in_param	$3 - The base OID this is a request for
#	@in_param	$+ - An array containing the request elements
#
function handle_get
{
	local BOID SOID TABLE RA COMMAND

	# Extract parameters
	TABLE="${1}";	shift
	SOID="${1}";	shift
	BOID="${1}";	shift
	RA=("${@}")

	# If we were not passed the name of a table in $1 then we're done so log an
	# error, send NONE and return.
	if [[ "${TABLE}" != \#* ]]; then
		error_echo "handle_get: parameter 1 is not a table!"
		send_none "${SOID}"
		return 1
	fi  
	
	# If the R[equest]A[array] does not contain any elements then we're done so
	# log an error, send NONE and return.
	if (( ${#RA[@]} == 0 )); then
		debug_echo "R[equest]A[array] is empty already!"
		send_none "${SOID}"
		return 1
	fi
	
	# If the next R[equest]A[array] element is 0 then it is an index request so
	# send the OID and NONE.
	if (( RA[0] == 0 )); then
		debug_echo "RA[0] is zero, index request"
		send_none "${SOID}"
		return
	fi

	# We were passed the name of a table so strip the leading #, make the variable
	# name.
	TABLE="${TABLE#\#}"
	TABLE="${TABLE}[${RA[0]}]"
	debug_echo "calculated table variable: ${TABLE}"

	# Check that something is defined for this entry.  If it isn't log an error,
	# send NONE and return.
	if [[ -z ${!TABLE+defined} ]]; then
		debug_echo "table entry is empty!"
		send_none "${SOID}"
		return 1
	fi	

	# If the deferenced value of TABLE starts with a # then it is a redirect to
	# another table, if not it is a command.
	if [[ "${!TABLE}" == \#* ]]; then
		# We have another table.  Simply call handle_get with the new table name,
		# BOID and RA.
		handle_get "${!TABLE}" "${SOID}" "${BOID}.${RA[0]}" "${RA[@]:1}"	
	else
		# We have a command.  Get it from the table, add the SOID, new BOID and
		# remaining R[equest]A[array] and eval it.
		COMMAND="${!TABLE} ${SOID} ${RA[*]:1}"
		debug_echo "found command in table: \"${COMMAND}\""
		eval "${COMMAND}"
	fi
}

# Main functional loop
function the_loop
{
	# Declare local variables
	local QUIT QUERY BASE_OID OID RARRAY

	# Try to resolve the numeric base oid from the base mib.
	# shellcheck disable=SC2153
	[[ -z "${BASE_MIB}" ]] && die "You must set BASE_MIB before starting the_loop()"
	BASE_OID="$(snmptranslate -On "${BASE_MIB}")" || die "Unable to resolve base OID from ${BASE_MIB}"
	
	# Loop until we are instructed to quit
	QUIT=0
	while (( QUIT == 0 )); do
	
		# Get the SNMP query type and convert to lower case.
		read -r QUERY
		QUERY=${QUERY,,}
					
		# What kind of request is this?
		case ${QUERY} in
			"ping")				# Handle PING request
			handle_ping
			;;
			
			"quit"|"exit"|"")	# Handle QUIT or EXIT request
			echo "Bye"
			exit
			;;
			
			"get")				# Handle GET requests
			get_and_split_request_oid "${BASE_OID}" OID RARRAY || handle_unknown_oid "${OID}"
			if (( ${#RARRAY[@]} > 0)); then
			    handle_get "#RTABLE" "${OID}" "${BASE_OID}" "${RARRAY[@]}" || handle_unknown_oid "${OID}"
			else
			    send_none "${OID}"
			fi
			;;
	
			"getnext")			# Handle GETNEXT requests
			get_and_split_request_oid "${BASE_OID}" OID RARRAY || handle_unknown_oid "${OID}"
			(( ${#RARRAY[@]} > 0)) && RARRAY="${RARRAY[*]}" || RARRAY="" 
			handle_getnext "#RTABLE" "${OID}" "${BASE_OID}" ${RARRAY}
			;;
	
			"set")				# Handle SET requests
			handle_set
			;;
	
			*)					# Handle unknown commands
			handle_unknown_query "${QUERY}"
			;;
		esac
		
	done
}
