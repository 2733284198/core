#!/usr/bin/env bash

# composer install

# from http://stackoverflow.com/a/630387
SCRIPT_PATH="`dirname \"$0\"`"              # relative
SCRIPT_PATH="`( cd \"${SCRIPT_PATH}\" && pwd )`"  # absolutized and normalized

echo 'Script path: '${SCRIPT_PATH}

OC_PATH=${SCRIPT_PATH}/../../
OCC=${OC_PATH}occ
BEHAT=${OC_PATH}lib/composer/bin/behat

# Look for command line options for:
# -c or --config - specify a behat.yml to use
# --feature - specify a single feature to run
# --suite - specify a single suite to run
# --type - api or webui - if no individual feature or suite is specified, then
#          specify the type of acceptance tests to run. Default api.
# --tags - specify tags for scenarios to run (or not)
# --remote - the server under test is remote, so we cannot locally enable the
#            testing app. We have to assume it is already enabled.
# --show-oc-logs - tail the ownCloud log after the test run
# --norerun - do not rerun failed webUI scenarios
# --part - run a subset of scenarios, need two numbers.
#          first number: which part to run
#          second number: in how many parts to divide the set of scenarios
BEHAT_TAGS_OPTION_FOUND=false
REMOTE_ONLY=false
SHOW_OC_LOGS=false
RERUN_FAILED_WEBUI_SCENARIOS=true
ACCEPTANCE_TEST_TYPE="api"

while [[ $# -gt 0 ]]
do
	key="$1"
	case ${key} in
		-c|--config)
			BEHAT_YML="$2"
			shift
			;;
		--feature)
			BEHAT_FEATURE="$2"
			shift
			;;
		--suite)
			BEHAT_SUITE="$2"
			shift
			;;
		--type)
			# Lowercase the parameter value, so the user can provide "API", "webUI" etc
			ACCEPTANCE_TEST_TYPE="${2,,}"
			shift
			;;
		--tags)
			BEHAT_FILTER_TAGS="$2"
			BEHAT_TAGS_OPTION_FOUND=true
			shift
			;;
		--browser)
			BROWSER="$2"
			shift
			;;
		--part)
			RUN_PART="$2"
			DIVIDE_INTO_NUM_PARTS="$3"
			if [ ${RUN_PART} -gt ${DIVIDE_INTO_NUM_PARTS} ]
			then
				echo "cannot run part ${RUN_PART} of ${DIVIDE_INTO_NUM_PARTS}"
				exit 1
			fi
			shift 2
			;;
		--remote)
			REMOTE_ONLY=true
			;;
		--show-oc-logs)
			SHOW_OC_LOGS=true
			;;
		--norerun)
			RERUN_FAILED_WEBUI_SCENARIOS=false
			;;
		*)
			# A "random" parameter is presumed to be a feature file to run.
			# Typically that will be specified at the end, or as the only
			# parameter.
			BEHAT_FEATURE="$1"
			;;
	esac
	shift
done

# Save the current language and set the language to "C"
# We want to have it all in english to be able to parse outputs
OLD_LANG=${LANG}
export LANG=C

# @param $1 admin authentication string username:password
# @param $2 occ url
# @param $3 command
# sets $REMOTE_OCC_STDOUT and $REMOTE_OCC_STDERR from returned xml data
# @return occ return code given in the xml data
function remote_occ() {
	COMMAND=`echo $3 | xargs`
	CURL_OCC_RESULT=`curl -s -u $1 $2 -d "command=${COMMAND}"`
	# xargs is (miss)used to trim the output
	RETURN=`echo ${CURL_OCC_RESULT} | xmllint --xpath "string(ocs/data/code)" - | xargs`
	# We could not find a proper return of the testing app, so something went wrong
	if [ -z "${RETURN}" ]
	then
		RETURN=1
		REMOTE_OCC_STDERR=${CURL_OCC_RESULT}
	else
		REMOTE_OCC_STDOUT=`echo ${CURL_OCC_RESULT} | xmllint --xpath "string(ocs/data/stdOut)" - | xargs`
		REMOTE_OCC_STDERR=`echo ${CURL_OCC_RESULT} | xmllint --xpath "string(ocs/data/stdErr)" - | xargs`
	fi
	return ${RETURN}
}

# $1 admin auth as needed for curl
# $2 full URL of the occ command in the testing app
# $3 system|app
# $4 app-name if app used
# $5 setting name
# $6 type of the variable to set it back correctly (optional)
# adds a new element to the array PREVIOUS_SETTINGS
# PREVIOUS_SETTINGS will be an array of strings containing:
# URL;system|app;app-name;setting-name;value;variable-type
function save_config_setting() {
	remote_occ $1 $2 "--no-warnings config:$3:get $4 $5"
	PREVIOUS_SETTINGS+=("$2;$3;$4;$5;${REMOTE_OCC_STDOUT};$6")
}

declare -a PREVIOUS_SETTINGS

# get the sub path from an URL
# $1 the full URL including the protocol
# echos the path
function get_path_from_url() {
	PROTOCOL="$(echo $1 | grep :// | sed -e's,^\(.*://\).*,\1,g')"
	URL="$(echo ${1/$PROTOCOL/})"
	PATH="$(echo ${URL} | grep / | cut -d/ -f2-)"
	echo ${PATH}
}

# Provide a default admin username and password.
# But let the caller pass them if they wish
if [ -z "${ADMIN_USERNAME}" ]
then
	ADMIN_USERNAME="admin"
fi

if [ -z "${ADMIN_PASSWORD}" ]
then
	ADMIN_PASSWORD="admin"
fi

ADMIN_AUTH="${ADMIN_USERNAME}:${ADMIN_PASSWORD}"

export ADMIN_USERNAME
export ADMIN_PASSWORD

function env_alt_home_enable {
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "config:app:set testing enable_alt_user_backend --value yes"
}

function env_alt_home_clear {
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "app:disable testing" || { echo "Unable to disable testing app" >&2; exit 1; }
}

function env_encryption_enable {
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "app:enable encryption"
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "encryption:enable"
}

function env_encryption_enable_master_key {
	env_encryption_enable || { echo "Unable to enable masterkey encryption" >&2; exit 1; }
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "encryption:select-encryption-type masterkey --yes"
}

function env_encryption_enable_user_keys {
	env_encryption_enable || { echo "Unable to enable user-keys encryption" >&2; exit 1; }
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "encryption:select-encryption-type user-keys --yes"
}

function env_encryption_disable {
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "encryption:disable"
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "app:disable encryption"
}

function env_encryption_disable_master_key {
	env_encryption_disable || { echo "Unable to disable masterkey encryption" >&2; exit 1; }
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "config:app:delete encryption useMasterKey"
}

function env_encryption_disable_user_keys {
	env_encryption_disable || { echo "Unable to disable user-keys encryption" >&2; exit 1; }
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "config:app:delete encryption userSpecificKey"
}

# expected variables
# --------------------
# $SUITE_FEATURE_TEXT - human readable which test to run
# $BEHAT_SUITE_OPTION - suite setting with "--suite" or empty if all suites have to be run
# $BEHAT_FEATURE - feature file, or empty
# $BEHAT_FILTER_TAGS - list of tags
# $BEHAT_TAGS_OPTION_FOUND
# $BROWSER_TEXT
# $BROWSER_VERSION_TEXT
# $PLATFORM_TEXT
# $TEST_LOG_FILE
# $BEHAT - behat executable
# $BEHAT_YML
# $RUNNING_WEBUI_TESTS
# $RERUN_FAILED_WEBUI_SCENARIOS
#
# set variables
# ---------------
# $PASSED true|false

function run_behat_tests() {
	echo "Running ${SUITE_FEATURE_TEXT} tests tagged ${BEHAT_FILTER_TAGS} ${BROWSER_TEXT}${BROWSER_VERSION_TEXT}${PLATFORM_TEXT}" | tee ${TEST_LOG_FILE}

	${BEHAT} --colors --strict -c ${BEHAT_YML} -f junit -f pretty ${BEHAT_SUITE_OPTION} --tags ${BEHAT_FILTER_TAGS} ${BEHAT_FEATURE} -v  2>&1 | tee -a ${TEST_LOG_FILE}
	
	BEHAT_EXIT_STATUS=${PIPESTATUS[0]}
	
	if [ ${BEHAT_EXIT_STATUS} -eq 0 ]
	then
		PASSED=true
	else
		PASSED=false
	fi
	
	# With webUI tests, we try running failed tests again.
	if [ "${PASSED}" = false ] && [ "${RUNNING_WEBUI_TESTS}" = true ] && [ "${RERUN_FAILED_WEBUI_SCENARIOS}" = true ]
	then
		echo "webUI test run failed with exit status: ${BEHAT_EXIT_STATUS}"
		PASSED=true
		SOME_SCENARIO_RERUN=false
		FAILED_SCENARIOS=`awk '/Failed scenarios:/',0 ${TEST_LOG_FILE} | grep feature`
		for FEATURE_COLORED in ${FAILED_SCENARIOS}
			do
				SOME_SCENARIO_RERUN=true
				# There will be some ANSI escape codes for color in the FEATURE_COLORED var.
				# Strip them out so we can pass just the ordinary feature details to Behat.
				# Thanks to https://en.wikipedia.org/wiki/Tee_(command) and
				# https://stackoverflow.com/questions/23416278/how-to-strip-ansi-escape-sequences-from-a-variable
				# for ideas.
				FEATURE=$(echo "${FEATURE_COLORED}" | sed "s/\x1b[^m]*m//g")
				echo "Rerun failed scenario: ${FEATURE}"
				${BEHAT} --colors --strict -c ${BEHAT_YML} -f junit -f pretty ${BEHAT_SUITE_OPTION} --tags ${BEHAT_FILTER_TAGS} ${FEATURE} -v  2>&1 | tee -a ${TEST_LOG_FILE}
				BEHAT_EXIT_STATUS=${PIPESTATUS[0]}
				if [ ${BEHAT_EXIT_STATUS} -ne 0 ]
				then
					echo "webUI test rerun failed with exit status: ${BEHAT_EXIT_STATUS}"
					PASSED=false
				fi
			done
	
		if [ "${SOME_SCENARIO_RERUN}" = false ]
		then
			# If the original Behat had a fatal PHP error and exited directly with
			# a "bad" exit code, then it may not have even logged a summary of the
			# failed scenarios. In that case there was an error and no scenarios
			# have been rerun. So PASSED needs to be false.
			PASSED=false
		fi
	fi
	
	if [ "${BEHAT_TAGS_OPTION_FOUND}" != true ]
	then
		# The behat run specified to skip scenarios tagged @skip
		# Report them in a dry-run so they can be seen
		# Big red error output is displayed if there are no matching scenarios - send it to null
		DRY_RUN_FILE=$(mktemp)
		SKIP_TAGS="${TEST_TYPE_TAG}&&@skip"
		${BEHAT} --dry-run --colors -c ${BEHAT_YML} -f junit -f pretty ${BEHAT_SUITE_OPTION} --tags "${SKIP_TAGS}" ${BEHAT_FEATURE} 1>${DRY_RUN_FILE} 2>/dev/null
		if grep -q -m 1 'No scenarios' "${DRY_RUN_FILE}"
		then
			# If there are no skip scenarios, then no need TEST_SERVER_URLto report that
			:
		else
			echo ""
			echo "The following tests were skipped because they are tagged @skip:"
			cat "${DRY_RUN_FILE}" | tee -a ${TEST_LOG_FILE}
		fi
		rm -f "${DRY_RUN_FILE}"
	fi
}

function teardown() {
	if [ "${RUNNING_API_TESTS}" = true ]
	then
		remote_occ ${ADMIN_AUTH} ${OCC_URL} "files_external:delete -y ${ID_STORAGE}"
	fi
	
	# Enable any apps that were disabled for the test run
	for i in "${!APPS_TO_REENABLE[@]}"
	do
		read -r -a APP <<< "${APPS_TO_REENABLE[$i]}"
		remote_occ ${ADMIN_AUTH} ${APP[0]} "--no-warnings app:enable ${APP[1]}"
	done
	
	# Disable any apps that were enabled for the test run
	for i in "${!APPS_TO_REDISABLE[@]}"
	do
		read -r -a APP <<< "${APPS_TO_REDISABLE[$i]}"
		remote_occ ${ADMIN_AUTH} ${APP[0]} "--no-warnings app:disable ${APP[1]}"
	done

	# Put back settings that were set for the test-run
	for i in "${!PREVIOUS_SETTINGS[@]}"
	do
		PREVIOUS_IFS=${IFS}
		IFS=';'
		read -r -a SETTING <<< "${PREVIOUS_SETTINGS[$i]}"
		IFS=${PREVIOUS_IFS}
		if [ -z "${SETTING[4]}" ]
		then
			remote_occ ${ADMIN_AUTH} ${SETTING[0]} "config:${SETTING[1]}:delete ${SETTING[2]} ${SETTING[3]}"
		else
			TYPE_STRING=""
			if [ -n "${SETTING[5]}" ]
			then
				#place the space here not in the command line, so that there is no space if the string is empty
				TYPE_STRING=" --type ${SETTING[5]}"
			fi
			remote_occ ${ADMIN_AUTH} ${SETTING[0]} "config:${SETTING[1]}:set ${SETTING[2]} ${SETTING[3]} --value=${SETTING[4]}${TYPE_STRING}"
		fi
	done
	
	# Put back state of the testing app
	if [ "${TESTING_ENABLED_BY_SCRIPT}" = true ]
	then
		${OCC} app:disable testing
	fi

	# Upload log file for later analysis
	if [ "${PASSED}" = false ] && [ ! -z "${REPORTING_WEBDAV_USER}" ] && [ ! -z "${REPORTING_WEBDAV_PWD}" ] && [ ! -z "${REPORTING_WEBDAV_URL}" ]
	then
		curl -u ${REPORTING_WEBDAV_USER}:${REPORTING_WEBDAV_PWD} -T ${TEST_LOG_FILE} ${REPORTING_WEBDAV_URL}/"${TRAVIS_JOB_NUMBER}"_`date "+%F_%T"`.log
	fi
	
	if [ "${RUNNING_API_TESTS}" = true ]
	then
		# Clear storage folder
		rm -Rf work/local_storage/*
	fi
	
	if [ "${OC_TEST_ALT_HOME}" = "1" ]
	then
		env_alt_home_clear
	fi
	
	# Disable encryption if requested
	if [ "${OC_TEST_ENCRYPTION_ENABLED}" = "1" ]
	then
		env_encryption_disable
	fi
	
	if [ "${OC_TEST_ENCRYPTION_MASTER_KEY_ENABLED}" = "1" ]
	then
		env_encryption_disable_master_key
	fi
	
	if [ "${OC_TEST_ENCRYPTION_USER_KEYS_ENABLED}" = "1" ]
	then
		env_encryption_disable_user_keys
	fi
	
	if [ "${TEST_WITH_PHPDEVSERVER}" == "true" ]
	then
		kill ${PHPPID}
		kill ${PHPPID_FED}
	fi
	
	if [ "${SHOW_OC_LOGS}" = true ]
	then
		tail "${OC_PATH}/data/owncloud.log"
	fi
	
	# Reset the original language
	export LANG=${OLD_LANG}
	
	rm -f "${TEST_LOG_FILE}"
	
	echo "runsh: Exit code of main run: ${BEHAT_EXIT_STATUS}"
}

declare -x TEST_SERVER_URL
declare -x TEST_SERVER_FED_URL
declare -x TEST_WITH_PHPDEVSERVER
[[ -z "${TEST_SERVER_URL}" && -z "${TEST_SERVER_FED_URL}" ]] && TEST_WITH_PHPDEVSERVER="true"

if [ -z "${IPV4_URL}" ]
then
	IPV4_URL="${TEST_SERVER_URL}"
fi

if [ -z "${IPV6_URL}" ]
then
	IPV6_URL="${TEST_SERVER_URL}"
fi

if [ "${TEST_WITH_PHPDEVSERVER}" != "true" ]
then
	# The endpoint to use to do occ commands via the testing app
	# set it already here, so it can be used for remote_occ
	# we know the TEST_SERVER_URL already
	OCC_URL="${TEST_SERVER_URL}/ocs/v2.php/apps/testing/api/v1/occ"
	if [ -n "${TEST_SERVER_FED_URL}" ]
	then
		OCC_FED_URL="${TEST_SERVER_FED_URL}/ocs/v2.php/apps/testing/api/v1/occ"
	fi
	
	echo "Not using php inbuilt server for running scenario ..."
	echo "Updating .htaccess for proper rewrites"
	#get the sub path of the webserver and set the correct RewriteBase
	WEBSERVER_PATH=$(get_path_from_url ${TEST_SERVER_URL})
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "config:system:set htaccess.RewriteBase --value /${WEBSERVER_PATH}/"
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "maintenance:update:htaccess"

	if [ -n "${TEST_SERVER_FED_URL}" ]
	then
		WEBSERVER_PATH=$(get_path_from_url ${TEST_SERVER_FED_URL})
		remote_occ ${ADMIN_AUTH} ${OCC_FED_URL} "config:system:set htaccess.RewriteBase --value /${WEBSERVER_PATH}/"
		remote_occ ${ADMIN_AUTH} ${OCC_FED_URL} "maintenance:update:htaccess"
	fi
else
	echo "Using php inbuilt server for running scenario ..."

	# Avoid port collision on jenkins - use $EXECUTOR_NUMBER
	declare -x EXECUTOR_NUMBER
	[[ -z "${EXECUTOR_NUMBER}" ]] && EXECUTOR_NUMBER=0

	PORT=$((8080 + ${EXECUTOR_NUMBER}))
	echo ${PORT}
	php -S localhost:${PORT} -t "${OC_PATH}" &
	PHPPID=$!
	echo ${PHPPID}

	PORT_FED=$((8180 + ${EXECUTOR_NUMBER}))
	echo ${PORT_FED}
	php -S localhost:${PORT_FED} -t ../.. &
	PHPPID_FED=$!
	echo ${PHPPID_FED}

	export TEST_SERVER_URL="http://localhost:${PORT}"
	export TEST_SERVER_FED_URL="http://localhost:${PORT_FED}"

	# The endpoint to use to do occ commands via the testing app
	OCC_URL="${TEST_SERVER_URL}/ocs/v2.php/apps/testing/api/v1/occ"

	# Give time for the PHP dev server to become available
	# because we want to use it to get and change settings with the testing app
	sleep 5
fi

# If a feature file has been specified but no suite, then deduce the suite
if [ -n "${BEHAT_FEATURE}" ] && [ -z "${BEHAT_SUITE}" ]
then
	FEATURE_PATH=`dirname ${BEHAT_FEATURE}`
	BEHAT_SUITE=`basename ${FEATURE_PATH}`
fi

declare -a BEHAT_SUITES
if [ -n "${BEHAT_SUITE}" ]
then
	BEHAT_SUITES+=(${BEHAT_SUITE})
else
	if [ -n "${RUN_PART}" ]
	then
		ALL_SUITES=`find features/ -type d -iname ${ACCEPTANCE_TEST_TYPE}* | sort | cut -d"/" -f2`
		COUNT_ALL_SUITES=`echo "${ALL_SUITES}" | wc -l`
		#divide the suites letting it round down (could be zero)
		MIN_SUITES_PER_RUN=$((${COUNT_ALL_SUITES} / ${DIVIDE_INTO_NUM_PARTS}))
		#some jobs might need an extra suite
		MAX_SUITES_PER_RUN=$((${MIN_SUITES_PER_RUN} + 1))
		# the remaining number of suites that need to be distributed (could be zero)
		REMAINING_SUITES=$((${COUNT_ALL_SUITES} - (${DIVIDE_INTO_NUM_PARTS} * ${MIN_SUITES_PER_RUN})))

		if [ ${RUN_PART} -le ${REMAINING_SUITES} ]
		then
			SUITES_THIS_RUN=${MAX_SUITES_PER_RUN}
			SUITES_IN_PREVIOUS_RUNS=$((${MAX_SUITES_PER_RUN} * (${RUN_PART} - 1)))
		else
			SUITES_THIS_RUN=${MIN_SUITES_PER_RUN}
			SUITES_IN_PREVIOUS_RUNS=$(((${MAX_SUITES_PER_RUN} * ${REMAINING_SUITES}) + (${MIN_SUITES_PER_RUN} * (${RUN_PART} - ${REMAINING_SUITES} - 1))))
		fi

		if [ ${SUITES_THIS_RUN} -eq 0 ]
		then
			echo "there are only ${COUNT_ALL_SUITES} suites, nothing to do in part ${RUN_PART}"
			teardown
			exit 0
		fi

		COUNT_FINISH_AND_TODO_SUITES=$((${SUITES_IN_PREVIOUS_RUNS} + ${SUITES_THIS_RUN}))
		BEHAT_SUITES+=(`echo "${ALL_SUITES}" | head -n ${COUNT_FINISH_AND_TODO_SUITES} | tail -n ${SUITES_THIS_RUN}`)
	fi
fi

# If the suite name begins with "webUI" or the user explicitly specified type "webui"
# then we will setup for webUI testing and run tests tagged as @webUI,
# otherwise it is API tests.
# Currently, running both API and webUI tests in a single run is not supported.
if [[ "${BEHAT_SUITE}" == webUI* ]] || [ "${ACCEPTANCE_TEST_TYPE}" = "webui" ]
then
	TEST_TYPE_TAG="@webUI"
	TEST_TYPE_TEXT="webUI"
	RUNNING_API_TESTS=false
	RUNNING_WEBUI_TESTS=true
else
	TEST_TYPE_TAG="@api"
	TEST_TYPE_TEXT="API"
	RUNNING_API_TESTS=true
	RUNNING_WEBUI_TESTS=false
fi

# Always have one of "@api" or "@webUI" filter tags
if [ -z "${BEHAT_FILTER_TAGS}" ]
then
	BEHAT_FILTER_TAGS="${TEST_TYPE_TAG}"
else
	BEHAT_FILTER_TAGS="${BEHAT_FILTER_TAGS}&&${TEST_TYPE_TAG}"
fi

if [ -z "${BEHAT_YML}" ]
then
	BEHAT_YML="config/behat.yml"
fi

if [ -z "${MAILHOG_HOST}" ]
then
	MAILHOG_HOST="127.0.0.1"
fi

if [ -z "${MAILHOG_SMTP_PORT}" ]
then
	MAILHOG_SMTP_PORT="1025"
fi

if [ -z "${SELENIUM_HOST}" ]
then
	SELENIUM_HOST=localhost
fi

if [ -z "${SELENIUM_PORT}" ]
then
	SELENIUM_PORT=4445
fi

if [ -z "${BROWSER}" ]
then
	BROWSER="chrome"
fi

# Check if we can rely on a local ./occ command or if we are testing
# a remote instance (e.g. inside docker).
# If we have a remote instance we cannot enable the testing app and
# we have to hope it is enabled already, by other ways
if [ "${REMOTE_ONLY}" = false ]
then
	# Enable testing app
	PREVIOUS_TESTING_APP_STATUS=$(${OCC} --no-warnings app:list "^testing$")
	if [[ "${PREVIOUS_TESTING_APP_STATUS}" =~ ^Disabled: ]]
	then
		${OCC} app:enable testing || { echo "Unable to enable testing app" >&2; exit 1; }
		TESTING_ENABLED_BY_SCRIPT=true;
	else
		TESTING_ENABLED_BY_SCRIPT=false;
	fi
else
	TESTING_ENABLED_BY_SCRIPT=false;
fi

# calculate the correct skeleton folder
# $SRC_SKELETON_DIR is the path to the skeleton folder on the machine where the tests are executed
# it is used for file comparisons in various tests
if [ "${RUNNING_API_TESTS}" = true ]
then
	export SRC_SKELETON_DIR="${SCRIPT_PATH}/../../apps/testing/data/apiSkeleton"
else
	export SRC_SKELETON_DIR="${SCRIPT_PATH}/../../apps/testing/data/webUISkeleton"
fi

# $SKELETON_DIR is the path to the skeleton folder on the machine where oC runs (system under test)
# It is used to give users a defined set of files and folders for the tests
if [ -z "${SKELETON_DIR}" ]
then
	export SKELETON_DIR="${SRC_SKELETON_DIR}"
fi

# table of settings to be remembered and set
#system|app;app-name;setting-name;value;variable-type
declare -a SETTINGS
SETTINGS+=("system;;mail_domain;foobar.com")
SETTINGS+=("system;;mail_from_address;owncloud")
SETTINGS+=("system;;mail_smtpmode;smtp")
SETTINGS+=("system;;mail_smtphost;${MAILHOG_HOST}")
SETTINGS+=("system;;mail_smtpport;${MAILHOG_SMTP_PORT}")
SETTINGS+=("app;core;backgroundjobs_mode;webcron")
SETTINGS+=("system;;sharing.federation.allowHttpFallback;true;boolean")
SETTINGS+=("app;core;enable_external_storage;yes")
SETTINGS+=("system;;files_external_allow_create_new_local;true")
SETTINGS+=("system;;skeletondirectory;${SKELETON_DIR}")

# Set various settings
for URL in ${OCC_URL} ${OCC_FED_URL}
do
	for i in "${!SETTINGS[@]}"
	do
		PREVIOUS_IFS=${IFS}
		IFS=';'
		read -r -a SETTING <<< "${SETTINGS[$i]}"
		IFS=${PREVIOUS_IFS}
		
		save_config_setting "${ADMIN_AUTH}" "${URL}" "${SETTING[0]}" "${SETTING[1]}" "${SETTING[2]}" "${SETTING[4]}"
		
		TYPE_STRING=""
		if [ -n "${SETTING[4]}" ]
		then
			#place the space here not in the command line, so that there is no space if the string is empty
			TYPE_STRING=" --type ${SETTING[4]}"
		fi
		
		remote_occ ${ADMIN_AUTH} ${URL} "config:${SETTING[0]}:set ${SETTING[1]} ${SETTING[2]} --value=${SETTING[3]}${TYPE_STRING}"
		if [ $? -ne 0 ]
		then
			echo -e "Could not set ${SETTING[2]} on ${URL}. Result:\n'${REMOTE_OCC_STDERR}'"
			teardown
			exit 1
		fi
	done
done

#Enable and disable apps as required for default
if [ -z "${APPS_TO_DISABLE}" ]
then
	APPS_TO_DISABLE="firstrunwizard notifications"
fi

if [ -z "${APPS_TO_ENABLE}" ]
then
	APPS_TO_ENABLE=""
fi

declare -a APPS_TO_REENABLE;

for URL in ${OCC_URL} ${OCC_FED_URL}
	do
	for APP_TO_DISABLE in ${APPS_TO_DISABLE}; do
		remote_occ ${ADMIN_AUTH} ${URL} "--no-warnings app:list ^${APP_TO_DISABLE}$"
		PREVIOUS_APP_STATUS=${REMOTE_OCC_STDOUT}
		if [[ "${PREVIOUS_APP_STATUS}" =~ ^Enabled: ]]
		then
			APPS_TO_REENABLE+=("${URL} ${APP_TO_DISABLE}");
			remote_occ ${ADMIN_AUTH} ${URL} "--no-warnings app:disable ${APP_TO_DISABLE}"
		fi
	done
done

declare -a APPS_TO_REDISABLE;

for URL in ${OCC_URL} ${OCC_FED_URL}
	do
	for APP_TO_ENABLE in ${APPS_TO_ENABLE}; do
		remote_occ ${ADMIN_AUTH} ${URL} "--no-warnings app:list ^${APP_TO_ENABLE}$"
		PREVIOUS_APP_STATUS=${REMOTE_OCC_STDOUT}
		if [[ "${PREVIOUS_APP_STATUS}" =~ ^Disabled: ]]
		then
			APPS_TO_REDISABLE+=("${URL} ${APP_TO_ENABLE}");
			remote_occ ${ADMIN_AUTH} ${URL} "--no-warnings app:enable ${APP_TO_ENABLE}"
		fi
	done
done

# Only make local storage when running API tests.
# The local storage folder cannot be deleted by an ordinary user.
# That makes problems for webUI tests that try to select all files in the top
# folder of a user, and then delete them in a batch.
if [ "${RUNNING_API_TESTS}" = true ]
then
	mkdir -p work/local_storage || { echo "Unable to create work folder" >&2; exit 1; }
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "files_external:create local_storage local null::null -c datadir=${SCRIPT_PATH}/work/local_storage"
	OUTPUT_CREATE_STORAGE=${REMOTE_OCC_STDOUT}
	ID_STORAGE=`echo ${OUTPUT_CREATE_STORAGE} | awk {'print $5'}`
	remote_occ ${ADMIN_AUTH} ${OCC_URL} "files_external:option ${ID_STORAGE} enable_sharing true"
fi

if [ "${OC_TEST_ALT_HOME}" = "1" ]
then
	env_alt_home_enable
fi

# We need to skip some tests in certain browsers.
if [ "${BROWSER}" == "internet explorer" ] || [ "${BROWSER}" == "MicrosoftEdge" ] || [ "${BROWSER}" == "firefox" ]
then
	BROWSER_IN_CAPITALS=${BROWSER//[[:blank:]]/}
	BROWSER_IN_CAPITALS=${BROWSER_IN_CAPITALS^^}
	BEHAT_FILTER_TAGS="${BEHAT_FILTER_TAGS}&&~@skipOn${BROWSER_IN_CAPITALS}"
fi

# Skip tests tagged with the current oC version
# One, two or three parts of the version can be used
# e.g.
# @skipOnOcV10.0.4
# @skipOnOcV10.0
# @skipOnOcV10

remote_occ ${ADMIN_AUTH} ${OCC_URL} "config:system:get version"
OWNCLOUD_VERSION=`echo ${REMOTE_OCC_STDOUT} | cut -d"." -f1-3`
BEHAT_FILTER_TAGS='~@skipOnOcV'${OWNCLOUD_VERSION}'&&'${BEHAT_FILTER_TAGS}
OWNCLOUD_VERSION=`echo ${OWNCLOUD_VERSION} | cut -d"." -f1-2`
BEHAT_FILTER_TAGS='~@skipOnOcV'${OWNCLOUD_VERSION}'&&'${BEHAT_FILTER_TAGS}
OWNCLOUD_VERSION=`echo ${OWNCLOUD_VERSION} | cut -d"." -f1`
BEHAT_FILTER_TAGS='~@skipOnOcV'${OWNCLOUD_VERSION}'&&'${BEHAT_FILTER_TAGS}

# If we are running remote only tests add another skip '@skipWhenTestingRemoteSystems'
if [ "${REMOTE_ONLY}" = true ]
then
	BEHAT_FILTER_TAGS='~@skipWhenTestingRemoteSystems&&'${BEHAT_FILTER_TAGS}
fi

# Enable encryption if requested
if [ "${OC_TEST_ENCRYPTION_ENABLED}" = "1" ]
then
	env_encryption_enable
	BEHAT_EXTRA_TAGS="~@no_encryption&&~@no_default_encryption"
elif [ "${OC_TEST_ENCRYPTION_MASTER_KEY_ENABLED}" = "1" ]
then
	env_encryption_enable_master_key
	BEHAT_EXTRA_TAGS="~@no_encryption&&~@no_masterkey_encryption"
elif [ "${OC_TEST_ENCRYPTION_USER_KEYS_ENABLED}" = "1" ]
then
	env_encryption_enable_user_keys
	BEHAT_EXTRA_TAGS="~@no_encryption&&~@no_userkeys_encryption"
else
	BEHAT_EXTRA_TAGS="~@masterkey_encryption"
fi

if [ "${OC_TEST_ON_OBJECTSTORE}" = "1" ]
then
   	BEHAT_FILTER_TAGS="${BEHAT_FILTER_TAGS}&&~@skip_on_objectstore"
fi

BEHAT_FILTER_TAGS="${BEHAT_FILTER_TAGS}&&${BEHAT_EXTRA_TAGS}"

# If the caller did not mention specific tags, skip the skipped tests by default
if [ "${BEHAT_TAGS_OPTION_FOUND}" = false ]
then
	BEHAT_FILTER_TAGS="${BEHAT_FILTER_TAGS}&&~@skip"
fi

if [ -n "${BROWSER_VERSION}" ]
then
	BROWSER_VERSION_EXTRA_CAPABILITIES_STRING='"browserVersion":"'${BROWSER_VERSION}'",'
	BROWSER_VERSION_SELENIUM_STRING='"version": "'${BROWSER_VERSION}'", '
	BROWSER_VERSION_TEXT='('${BROWSER_VERSION}') '
else
	BROWSER_VERSION_EXTRA_CAPABILITIES_STRING=""
	BROWSER_VERSION_SELENIUM_STRING=""
	BROWSER_VERSION_TEXT=""
fi

if [ -n "${PLATFORM}" ]
then
	PLATFORM_SELENIUM_STRING='"platform": "'${PLATFORM}'", '
	PLATFORM_TEXT="on platform '${PLATFORM}' "
else
	PLATFORM_SELENIUM_STRING=""
	PLATFORM_TEXT=""
fi

if [ "${RUNNING_API_TESTS}" = true ]
then
	EXTRA_CAPABILITIES=""
	BROWSER_TEXT=""
else
	BROWSER_TEXT="on browser '${BROWSER}' "

	# If we are running on Travis, use the Travis details as the name
	if [ -n "${TRAVIS_REPO_SLUG}" ]
	then
		CAPABILITIES_NAME_TEXT="${TRAVIS_REPO_SLUG} - ${TRAVIS_JOB_NUMBER}"
	else
		# If we are running in some automated CI, use the provided details
		if [ -n "${CI_REPO}" ]
		then
			CAPABILITIES_NAME_TEXT="${CI_REPO} - ${CI_BRANCH}"
		else
			# Otherwise this is a non-CI run, probably a local developer run
			CAPABILITIES_NAME_TEXT="ownCloud non-CI"
		fi
	fi

	# If SauceLabs credentials have been passed, then use them
	if [ -n "${SAUCE_USERNAME}" ] && [ -n "${SAUCE_ACCESS_KEY}" ]
	then
		SAUCE_CREDENTIALS="${SAUCE_USERNAME}:${SAUCE_ACCESS_KEY}@"
	else
		SAUCE_CREDENTIALS=""
	fi

	if [ "${BROWSER}" == "firefox" ]
	then
		# Set the screen resolution so that hopefully draggable elements will be visible
		# FF gives problems if the destination element is not visible
		EXTRA_CAPABILITIES='"screenResolution":"1920x1080",'

		# This selenium version works for Firefox after V47
		# We no longer need to support testing of Firefox V47 or earlier
		EXTRA_CAPABILITIES='"seleniumVersion":"3.4.0",'${EXTRA_CAPABILITIES}
	fi

	if [ "${BROWSER}" == "internet explorer" ]
	then
		EXTRA_CAPABILITIES='"iedriverVersion": "3.4.0","requiresWindowFocus":true,"screenResolution":"1920x1080",'
	fi

	EXTRA_CAPABILITIES=${EXTRA_CAPABILITIES}${BROWSER_VERSION_EXTRA_CAPABILITIES_STRING}'"maxDuration":"3600"'
	export BEHAT_PARAMS='{"extensions" : {"Behat\\MinkExtension" : {"browser_name": "'${BROWSER}'", "base_url" : "'${TEST_SERVER_URL}'", "selenium2":{"capabilities": {"marionette":null, "browser": "'${BROWSER}'", '${BROWSER_VERSION_SELENIUM_STRING}${PLATFORM_SELENIUM_STRING}'"name": "'${CAPABILITIES_NAME_TEXT}'", "extra_capabilities": {'${EXTRA_CAPABILITIES}'}}, "wd_host":"http://'${SAUCE_CREDENTIALS}${SELENIUM_HOST}':'${SELENIUM_PORT}'/wd/hub"}}, "SensioLabs\\Behat\\PageObjectExtension" : {}}}'
fi

echo ${EXTRA_CAPABILITIES}
echo ${BEHAT_PARAMS}

export IPV4_URL
export IPV6_URL
export FILES_FOR_UPLOAD="${SCRIPT_PATH}/filesForUpload/"

if [ ${#BEHAT_SUITES[@]} -eq 0 ] && [ -z "${BEHAT_FEATURE}" ]
then
	SUITE_FEATURE_TEXT="all ${TEST_TYPE_TEXT}"
	run_behat_tests
else
	if [ -n "${BEHAT_SUITE}" ]
	then
		SUITE_FEATURE_TEXT="${BEHAT_SUITE}"
	fi

	if [ -n "${BEHAT_FEATURE}" ]
	then
		# If running a whole feature, it will be something like login.feature
		# If running just a single scenario, it will also have the line number
		# like login.feature:36 - which will be parsed correctly like a "file"
		# by basename.
		BEHAT_FEATURE_FILE=`basename ${BEHAT_FEATURE}`
		SUITE_FEATURE_TEXT="${SUITE_FEATURE_TEXT} ${BEHAT_FEATURE_FILE}"
	fi
fi

TEST_LOG_FILE=$(mktemp)

for i in "${!BEHAT_SUITES[@]}"
	do
	BEHAT_SUITE_OPTION="--suite=${BEHAT_SUITES[$i]}"
	SUITE_FEATURE_TEXT="${BEHAT_SUITES[$i]}"

	run_behat_tests

	if [ "${PASSED}" = false ]
	then
		teardown
		exit 1
	fi
done

teardown

if [ "${PASSED}" = true ]
then
	exit 0
else
	exit 1
fi
