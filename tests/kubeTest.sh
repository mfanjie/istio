#!/bin/bash

# Copyright 2017 Istio Authors

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.


# Local vars
SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
NAMESPACE=$(uuidgen)
K8CLI="kubectl"
ISTIOCLI="istioctl"
RULESDIR=$SCRIPTDIR/apps/bookinfo/rules
EXAMPLESDIR=$SCRIPTDIR/apps/bookinfo/output
PASS=true

export POD_NAMESPACE=$NAMESPACE

# Import relevant utils
. $SCRIPTDIR/commonUtils.sh # Must be first for print_block_echo usage in other util files
. $SCRIPTDIR/kubeUtils.sh
. $SCRIPTDIR/istioUtils.sh

# Setup
create_namespace
modify_rules_namespace
deploy_istio
deploy_bookinfo

# Get gateway IP and port
GATEWAYIP=$($K8CLI -n $NAMESPACE describe pod $($K8CLI -n $NAMESPACE get pods | awk 'NR>1 {print $1}' | grep istio-ingress-controller) | grep Node | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
PORT=$($K8CLI -n $NAMESPACE get services | grep istio-ingress-controller | awk '{print $4}' | grep -oE 3[0-9]{4})

# Verify default routes
print_block_echo "Testing default route behavior..."
for (( i=0; i<=4; i++ ))
do  
    response=$(curl --write-out %{http_code} --silent --output /dev/null http://$GATEWAYIP:$PORT/productpage)
    if [ $response -ne 200 ]
    then
        if [ $i -eq 4 ]
        then
            echo "Failed to resolve default routes"
            PASS=false
            dump_debug
        fi
        echo "Couldn't get to the bookinfo product page, trying again...'"
    else
        echo "Success!"
        break
    fi
    sleep 10
done

# Test version routing
print_block_echo "Testing version routing..."
create_rule $RULESDIR/route-rule-all-v1.yaml
create_rule $RULESDIR/route-rule-reviews-test-v2.yaml
echo "Waiting for rules to propagate..."
sleep 30

test_version_routing_response() {
    USER=$1
    VERSION=$2
    echo "injecting traffic for user=$USER, expecting productpage-$USER-$VERSION..."
    curl -s -b "foo=bar;user=$USER;" http://$GATEWAYIP:$PORT/productpage > /tmp/productpage-$USER-$VERSION.html
    compare_output $EXAMPLESDIR/productpage-$USER-$VERSION.html /tmp/productpage-$USER-$VERSION.html $USER
    if [ $? -ne 0 ]
    then
        PASS=false
        dump_debug
    fi
}

test_version_routing_response "normal-user" "v1"
test_version_routing_response "test-user" "v2"

# Test fault injection
print_block_echo "Testing fault injection..."

create_rule $RULESDIR/route-rule-delay.yaml

test_fault_delay() {
    USER=$1
    VERSION=$2
    EXP_MIN_DELAY=$3
    EXP_MAX_DELAY=$4
    
    for (( i=0; i<=4; i++ ))
    do  
        echo "injecting traffic for user=$USER, expecting productpage-$USER-$VERSION in $EXP_MIN_DELAY to $EXP_MAX_DELAY seconds"
        before=$(date +"%s")
        curl -s -b "foo=bar;user=$USER;" http://$GATEWAYIP:$PORT/productpage > /tmp/productpage-$USER-$VERSION.html
        after=$(date +"%s")
        delta=$(($after-$before))
        if [ $delta -ge $EXP_MIN_DELAY ] && [ $delta -le $EXP_MAX_DELAY ]
        then
            echo "Success!"
            if [ $EXP_MIN_DELAY -gt 0 ]
            then
                compare_output $EXAMPLESDIR/productpage-$USER-$VERSION-review-timeout.html /tmp/productpage-$USER-$VERSION.html $USER
            else
                compare_output $EXAMPLESDIR/productpage-$USER-$VERSION.html /tmp/productpage-$USER-$VERSION.html $USER
            fi
            return 0
        elif [ $i -eq 4 ]
        then
            echo "Productpage took $delta seconds to respond (expected between $EXP_MIN_DELAY and $EXP_MAX_DELAY) for user=$USER in fault injection phase"
            PASS=false
            dump_debug
        fi
        sleep 10
    done
    return 1
}

test_fault_delay "normal-user" "v1" 0 2
test_fault_delay "test-user" "v1" 5 8

# Remove fault injection and verify
print_block_echo "Deleting fault injection..."

delete_rule $RULESDIR/route-rule-delay.yaml
echo "Waiting for rule clean up to propagate..."
sleep 30
test_fault_delay "test-user" "v2" 0 2
if [ $? -eq 0 ]
then
    echo "Fault injection was successfully cleared up"
else
    echo "Fault injection persisted"
    PASS=false
    dump_debug
fi

# Test gradual migration traffic to reviews:v3 for all users
cleanup_all_rules
print_block_echo "Testing gradual migration..."

COMMAND_INPUT="curl -s -b 'foo=bar;user=normal-user;' http://$GATEWAYIP:$PORT/productpage"
EXPECTED_OUTPUT1="$EXAMPLESDIR/productpage-normal-user-v1.html"
EXPECTED_OUTPUT2="$EXAMPLESDIR/productpage-normal-user-v3.html"
create_rule $RULESDIR/route-rule-reviews-50-v3.yaml
echo "Waiting for rules to propagate..."
sleep 30
echo "Expected percentage based routing is 50% to v1 and 50% to v3."

# Validate that 50% of traffic is routing to v1
# Curl the health check and check the version cookie
check_routing_rules "$COMMAND_INPUT" "$EXPECTED_OUTPUT1" "$EXPECTED_OUTPUT2" 50
if [ $? -ne 0 ]
then
    PASS=false
    dump_debug
fi

# Teardown
cleanup_all_rules
cleanup
revert_rules_namespace # only really needed for local retests...

if [ $PASS == false ]
then
    echo "ONE OR MORE TESTS HAVE FAILED"
    exit 1
else
    echo "TESTS HAVE PASSED"
fi