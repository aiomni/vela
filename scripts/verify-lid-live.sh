#!/bin/zsh
# Run from an unlocked desktop with an administrator available. This changes
# the system-wide SleepDisabled flag and deliberately kills a test process.
set -euo pipefail
cd "${0:A:h:h}"
test_case="${1:-all}"
[[ "$test_case" == all || "$test_case" == --timeout-only || "$test_case" == --cancel-only || "$test_case" == --preexisting-only || "$test_case" == --battery-only || "$test_case" == --thermal-only || "$test_case" == --external-only || "$test_case" == --pending-auth-only ]] || {
    print -u2 -- 'Usage: verify-lid-live.sh [--timeout-only|--cancel-only|--preexisting-only|--battery-only|--thermal-only|--external-only|--pending-auth-only]'
    exit 2
}
app="$PWD/dist/Vela.app/Contents/MacOS/Vela"
[[ -x "$app" ]] || { print -u2 -- 'Build dist/Vela.app first'; exit 2; }

sleep_disabled() {
    local value
    value="$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2 }')"
    value="${value:-0}"
    [[ "$value" == 0 || "$value" == 1 ]] || return 1
    print -r -- "$value"
}

baseline="$(sleep_disabled)"
[[ "$baseline" == 0 ]] || { print -u2 -- 'SleepDisabled is already 1; this test requires 0. System settings were not changed.'; exit 2; }
session_directories() {
    /usr/bin/find /private/tmp -maxdepth 1 -type d -name "vela-lid-$(/usr/bin/id -u)-*" -print | /usr/bin/sort
}
baseline_sessions="$(session_directories)"
log_dir="$PWD/.build/lid-live-check-$(/bin/date +%Y%m%d-%H%M%S)"
mkdir -p "$log_dir"
active_pid=""

wait_for_restore() {
    local deadline=$((SECONDS + ${1:-12}))
    while (( SECONDS < deadline )); do
        [[ "$(sleep_disabled)" == 0 ]] && return 0
        /bin/sleep 0.2
    done
    return 1
}

wait_for_session_cleanup() {
    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        [[ "$(session_directories)" == "$baseline_sessions" ]] && return 0
        /bin/sleep 0.2
    done
    return 1
}

cleanup() {
    if [[ -n "$active_pid" ]] && /bin/kill -0 "$active_pid" 2>/dev/null; then
        local child
        for child in ${(@f)$(/usr/bin/pgrep -P "$active_pid" -x osascript 2>/dev/null)}; do
            [[ -n "$child" ]] && /bin/kill "$child" 2>/dev/null || true
        done
        /bin/kill "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    if [[ "$(sleep_disabled 2>/dev/null || print unknown)" != 0 ]]; then
        wait_for_restore 12 && return
        print -u2 -- 'Recovery monitor not confirmed. Requesting administrator approval to restore normal sleep…'
        /usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with prompt "Vela live verification needs to restore normal closed-lid sleep." with administrator privileges' || true
        if [[ "$(sleep_disabled 2>/dev/null || print unknown)" != 0 ]]; then
            print -u2 -- 'URGENT: SleepDisabled=0 could not be confirmed. Check pmset -g and ask an administrator to restore it.'
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$test_case" == --pending-auth-only ]]; then
    print -- 'Pending-authorization exit check: leave the administrator dialog open without clicking a button.'
    "$app" --lid-pending-auth-live-test > "$log_dir/pending-auth.log" 2>&1 &
    active_pid=$!
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        /usr/bin/grep -q '^LID_PENDING_AUTH_READY ' "$log_dir/pending-auth.log" && break
        if ! /bin/kill -0 "$active_pid" 2>/dev/null; then
            /bin/cat "$log_dir/pending-auth.log"
            exit 1
        fi
        /bin/sleep 0.2
    done
    /usr/bin/grep -q '^LID_PENDING_AUTH_READY ' "$log_dir/pending-auth.log" || {
        print -u2 -- 'No child process waiting for authorization was observed.'
        exit 1
    }
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_PENDING_AUTH_CLEANED$' "$log_dir/pending-auth.log" || {
        /bin/cat "$log_dir/pending-auth.log"
        exit 1
    }
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'SleepDisabled is not 0 after exit.'; exit 1; }
    print -- 'Pending-authorization exit: authorization child ended; SleepDisabled remains 0.'
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

wait_for_ready() {
    local pid="$1" log="$2" deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        /usr/bin/grep -q '^LID_READY ' "$log" && return 0
        if /usr/bin/grep -q '^LID_OPEN_FAILED:' "$log"; then
            /bin/cat "$log"
            return 1
        fi
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/cat "$log"
            return 1
        fi
        /bin/sleep 0.2
    done
    print -u2 -- 'Timed out waiting for administrator approval.'
    return 1
}

if [[ "$test_case" == --cancel-only ]]; then
    print -- 'Authorization cancellation check: click Cancel in the macOS administrator dialog.'
    "$app" --lid-live-test 8 > "$log_dir/cancel.log" 2>&1 &
    active_pid=$!
    if wait_for_ready "$active_pid" "$log_dir/cancel.log"; then
        print -u2 -- 'This start was authorized, possibly by cached system approval. Cancellation was not tested.'
        exit 1
    fi
    local_wait=0
    while /bin/kill -0 "$active_pid" 2>/dev/null && (( local_wait < 15 )); do
        /bin/sleep 0.2
        (( local_wait += 1 ))
    done
    if /bin/kill -0 "$active_pid" 2>/dev/null; then
        print -u2 -- 'The authorization dialog is still waiting. Cancellation was not tested.'
        exit 1
    fi
    wait "$active_pid" 2>/dev/null || true
    active_pid=""
    /usr/bin/grep -q '^LID_OPEN_FAILED:' "$log_dir/cancel.log" || {
        print -u2 -- 'The app did not report authorization cancellation or startup failure.'
        exit 1
    }
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'SleepDisabled is not 0 after cancellation.'; exit 1; }
    print -- 'Authorization canceled: SleepDisabled remains 0.'
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

if [[ "$test_case" == --preexisting-only ]]; then
    print -- 'Preexisting value check: temporarily setting SleepDisabled=1. Approve the administrator dialog when requested.'
    /usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 1" with prompt "Vela live verification needs to temporarily disable closed-lid sleep." with administrator privileges'
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'Unable to set test baseline to 1'; exit 1; }
    "$app" --lid-live-test 5 > "$log_dir/preexisting.log" 2>&1 &
    active_pid=$!
    wait_for_ready "$active_pid" "$log_dir/preexisting.log"
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'Vela changed the preexisting value 1 on start'; exit 1; }
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_RESTORED$' "$log_dir/preexisting.log"
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'Vela did not preserve the preexisting value 1 on stop'; exit 1; }
    print -- 'Vela preserved the preexisting value 1. Restoring the pre-test value 0.'
    /usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with prompt "Vela live verification needs to restore normal closed-lid sleep." with administrator privileges'
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'Restoration of pre-test SleepDisabled=0 was not confirmed'; exit 1; }
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

if [[ "$test_case" == --battery-only ]]; then
    print -- 'Power-source check: keep AC power connected and approve the closed-lid administrator dialog when requested.'
    "$app" --lid-battery-live-test > "$log_dir/battery.log" 2>&1 &
    active_pid=$!
    deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        /usr/bin/grep -q '^LID_BATTERY_READY ' "$log_dir/battery.log" && break
        if /usr/bin/grep -q '^LID_.*FAILED' "$log_dir/battery.log" || ! /bin/kill -0 "$active_pid" 2>/dev/null; then
            /bin/cat "$log_dir/battery.log"
            exit 1
        fi
        /bin/sleep 0.2
    done
    /usr/bin/grep -q '^LID_BATTERY_READY ' "$log_dir/battery.log" || { print -u2 -- 'Timed out waiting for a closed-lid session.'; exit 1; }
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'SleepDisabled is not 1 before changing the power source'; exit 1; }
    print -- 'Closed-lid watch ready: unplug AC power for about 10 seconds, then reconnect after the restoration result.'
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_BATTERY_RESTORED ' "$log_dir/battery.log" || { /bin/cat "$log_dir/battery.log"; exit 1; }
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'SleepDisabled did not return to 0 after changing the power source'; exit 1; }
    /bin/cat "$log_dir/battery.log"
    print -- 'Power-source restoration check passed. Reconnect AC power.'
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

if [[ "$test_case" == --thermal-only ]]; then
    print -- 'Thermal pause check: approve the closed-lid administrator dialog. Thermal state is simulated only in the test process.'
    "$app" --lid-thermal-live-test > "$log_dir/thermal.log" 2>&1 &
    active_pid=$!
    deadline=$((SECONDS + 120))
    while /bin/kill -0 "$active_pid" 2>/dev/null && (( SECONDS < deadline )); do
        /bin/sleep 0.2
    done
    if /bin/kill -0 "$active_pid" 2>/dev/null; then
        print -u2 -- 'Timed out waiting for administrator approval.'
        exit 1
    fi
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_THERMAL_RESTORED$' "$log_dir/thermal.log" || { /bin/cat "$log_dir/thermal.log"; exit 1; }
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'SleepDisabled did not return to 0 after thermal pause'; exit 1; }
    print -- 'Simulated critical thermal state: assertions released and SleepDisabled=0 restored.'
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

if [[ "$test_case" == --external-only ]]; then
    print -- 'External-change check: approve the administrator dialog when requested.'
    "$app" --lid-external-live-test > "$log_dir/external.log" 2>&1 &
    active_pid=$!
    deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        /usr/bin/grep -q '^LID_EXTERNAL_READY ' "$log_dir/external.log" && break
        if /usr/bin/grep -q '^LID_.*FAILED' "$log_dir/external.log" || ! /bin/kill -0 "$active_pid" 2>/dev/null; then
            /bin/cat "$log_dir/external.log"
            exit 1
        fi
        /bin/sleep 0.2
    done
    /usr/bin/grep -q '^LID_EXTERNAL_READY ' "$log_dir/external.log" || { print -u2 -- 'Timed out waiting for a closed-lid session.'; exit 1; }
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'SleepDisabled is not 1 before the external change'; exit 1; }
    print -- 'Setting SleepDisabled to 0 from the test script and observing the app heartbeat.'
    /usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with prompt "Vela live verification will externally restore closed-lid sleep." with administrator privileges'
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_EXTERNAL_STOPPED$' "$log_dir/external.log" || { /bin/cat "$log_dir/external.log"; exit 1; }
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'SleepDisabled is not 0 after the external change'; exit 1; }
    print -- 'External change: the app detected invalid closed-lid protection and ended the session.'
    print -r -- "Verification logs: $log_dir"
    exit 0
fi

if [[ "$test_case" == all ]]; then
    print -- 'Normal-stop check: approve this test in the macOS dialog.'
    "$app" --lid-live-test 8 > "$log_dir/normal.log" 2>&1 &
    active_pid=$!
    wait_for_ready "$active_pid" "$log_dir/normal.log"
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'SleepDisabled did not become 1 after start'; exit 1; }
    wait "$active_pid"
    active_pid=""
    /usr/bin/grep -q '^LID_RESTORED$' "$log_dir/normal.log"
    [[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'Normal stop did not restore sleep'; exit 1; }
    print -- 'Normal stop: SleepDisabled=0 restored.'

    print -- 'Forced-exit check: approve the administrator dialog again.'
    "$app" --lid-live-test 120 > "$log_dir/crash.log" 2>&1 &
    active_pid=$!
    wait_for_ready "$active_pid" "$log_dir/crash.log"
    [[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'SleepDisabled did not become 1 before forced exit'; exit 1; }
    /bin/kill -9 "$active_pid"
    wait "$active_pid" 2>/dev/null || true
    active_pid=""
    wait_for_restore || { print -u2 -- 'Sleep was not restored within 12 seconds of forced exit'; exit 1; }
    print -- 'Forced exit: SleepDisabled=0 restored.'
fi

print -- 'Heartbeat timeout check: approve this test in the macOS dialog.'
"$app" --lid-live-test 120 > "$log_dir/timeout.log" 2>&1 &
active_pid=$!
wait_for_ready "$active_pid" "$log_dir/timeout.log"
[[ "$(sleep_disabled)" == 1 ]] || { print -u2 -- 'SleepDisabled did not become 1 after start'; exit 1; }
wait_for_restore 40 || { print -u2 -- 'Sleep was not restored within 40 seconds of the heartbeat stopping'; exit 1; }
[[ "$(sleep_disabled)" == 0 ]] || { print -u2 -- 'Sleep was not restored after heartbeat timeout'; exit 1; }
wait_for_session_cleanup || { print -u2 -- 'New closed-lid session directories remain after heartbeat timeout'; exit 1; }
/bin/kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
active_pid=""
print -- 'Heartbeat timeout: SleepDisabled=0 restored.'
print -r -- "Verification logs: $log_dir"
