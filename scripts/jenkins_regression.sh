#!/bin/bash
##
## Copyright 2019 International Business Machines
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##

usage() { echo '''
    Usage: jenkins_regression.sh [-l <regression_list>] [-e <ies lib>] [-b] [-n]
    -l <regression_list> -- the file contains name of testcases, one test per line;
    -e <ies lib>         -- the path to the ies simulation library, which is generated by vivado compile_sim_lib;
    -b                   -- use LSF (bsub) to submit jobs in parallel, one test per job;
    -n                   -- do not compile simulation model before simulation.
    ''' 1>&2; exit 1; 
}

BSUB=0
NO_COMPILE=0
IESL=${HOME}/vol0/xcelium_lib
REGRESSION_LIST=./regression_list
BSUB_CMD_BASE='bsub -P P9 -G p91_unit -M 32 -n 2 -R "select[osname == linux]" -R "select[type == X86_64]" -q normal '
ALL_JOBS=()
SPIN=("-" "\\" "|" "/")

while getopts ":l:be:n" o; do
    case "${o}" in
        l)
            REGRESSION_LIST=${OPTARG}
            ;;
        b)
            BSUB=1
            ;;
        e)
            IESL=${OPTARG}
            ;;
        n) 
            NO_COMPILE=1
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ ! -d $IESL ]]; then
    echo "Invalid IES_LIBS: $IES_LIBS"
    usage
    exit -1
fi

if [[ ! -f $REGRESSION_LIST ]]; then
    echo "Invalid REGRESSION_LIST: $REGRESSION_LIST"
    usage
    exit -1
fi

OCACCEL_ROOT=`pwd`

if [[ ! -d ${OCACCEL_ROOT}/actions ]]; then
    echo "Current directory is not a valid OCACCEL ROOT, please run this script from OCACCEL ROOT with ./scripts/$0"
    exit -1
fi

. ./setup_tools.ksh

export IES_LIBS=$IESL
echo "Setting IES_LIBS to ${IES_LIBS}"

if [[ $NO_COMPILE == 0 ]]; then
    # Compile the simulation model
    ./ocaccel_workflow.py -c --simulator xcelium --no_run_sim --unit_sim

    if [[ $? != 0 ]]; then
        echo "Model compilation FAILED!!"
        exit -1
    fi
fi

# Get the bsub job ID
function JD {
output=$($*)
echo $output | head -n1 | cut -d'<' -f2 | cut -d'>' -f1
}

# Run simulation on all tests in the list file
while IFS= read -r test
do
    test=`echo -e "${test}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
    if [[ $test == \#* ]]; then
        continue
    fi

    echo "Running Test: $test"
    CMD="./ocaccel_workflow.py --no_configure --no_make_model --simulator xcelium --unit_sim --unit_test $test"
    if [[ $BSUB == 1 ]]; then
        output=`eval $BSUB_CMD_BASE $CMD`
        JOBID=`echo $output | head -n1 | cut -d'<' -f2 | cut -d'>' -f1`
        echo "Submitted JOB ID: $JOBID"
        ALL_JOBS+=( $JOBID )

        if [[ $? != 0 ]]; then
            echo "Failed to submit job with command:"
            echo "$BSUB_CMD_BASE $CMD"
            echo "You may want to kill all previously submitted jobs via bkill -r <job id>"
            exit -1;
        fi
    else 
        eval $CMD

        if [[ $? != 0 ]]; then
            echo "$test FAILED!!"
            exit -1
        fi
    fi
done < "$REGRESSION_LIST"

if [[ $BSUB == 1 ]]; then
    echo "Waiting for at least 1 job to be started"
    COUNT=0
    DONE=0
    sleep 5;
    while true; do
        for J in "${ALL_JOBS[@]}"; do
            echo $J
            CMD='bjobs -noheader -o "STAT" $J'
            output=`eval $CMD`
            result=`echo $output | tr -d '\040\011\012\015'`
            sleep 0.3
            if [ "$result" == "RUN" ]; then
                DONE=1
                break
            fi
            COUNT=$((COUNT+1))
        done
        if [[ $DONE == 1 ]]; then
            break
        fi
        INDEX=$((COUNT%4))
        echo -ne "\b${SPIN[INDEX]}"
    done
    ./scripts/parse_unit_sim_result.pl -input_dir ${OCACCEL_ROOT}/hardware/sim/xcelium
fi

exit 0