#!/bin/bash -xv
#
# End-to end test (can also be used on CI slaves)
#
# This script runs all necessary components for a single test:
# - a set of node(s)
# - a researcher
#
# the researcher runs the given script (python or python notebook)
# the dataset is loaded into local DB of the node
# everything is cleaned at the end of the run.
#
# Arguments: see usage() function
#
# the -d directive can be repeated to run more than one node
#
# Example:
# ./scripts/run_end_to_end_one.sh -s ./notebooks/101_getting-started.py \
#                                -d ./tests/datasets/mnist.json
#
# This will run 3 nodes:
# ./scripts/run_end_to_end_one.sh -s ./notebooks/101_getting-started.py \
#                                -d ./tests/datasets/mnist.json \
#                                -d ./tests/datasets/mnist.json \
#                                -d ./tests/datasets/mnist.json
#
# Remark: multiple instances of this script cannot run at the same time
#         because:
#         - it runs a researcher
#

# ---------------
# ** variables **
# ---------------

# default timeout in seconds for aborting the test (can be changed at runtime)
TEST_TIMEOUT=900


# ---------------
# ** functions **
# ---------------

usage() {
    #
    # print usage
    #
    echo "\
Usage: ${0##*/} -s file -d dataset.json

  -h, --help                  this help
  -s, --script  <file>        script to run (.py or .ipynb)
  -t, --timeout <integer>     max execution time (default = $TEST_TIMEOUT)
  -d, --dataset <json-file>   dataset description

Remarks: 
1. only dataset availability is checked. Coherence between
provided script and dataset is not validated by this launcher
2. the -d directive can be repeated to run more than one node
3. multiple instances of this script cannot run at the same time because:
   - it runs a researcher

Example:
./scripts/run_end_to_end_test -s ./notebooks/101_getting-started.py \
                               -d ./tests/datasets/mnist.json

This will run 3 nodes:
./scripts/run_end_to_end_test -s ./notebooks/101_getting-started.py \
                               -d ./tests/datasets/mnist.json \
                               -d ./tests/datasets/mnist.json \
                               -d ./tests/datasets/mnist.json
"
}

bad_usage () {
    echo "\
ERROR: $*
"
    usage
    exit 1
}

banner() {
    echo "======================================================================"
    echo "== $*"
    echo "======================================================================"
}



subprocess() {
    # find all suprocesses of a given pid
    # (should be as portable as pgrep is)
    parent=$1

    [[ -z "$parent" ]] && { echo "" ; return ; }
    pids=$(pgrep -P $parent)

    [[ -z "pids" ]] && { echo "" ; return ; }

    list=""
    for i in $pids ; do
        list+="$i $(subprocess $i) "
    done

    echo "$list"
}

generate_config_filename() {
    #
    # return a config filename which does not exist yet
    seed=$1

    found=0
    i=0
    while [ $found = 0 ]
    do
        file="$basedir/etc/config_node_integration_${seed}.${i}.ini"
        if [ ! -f "$file" ]
        then
            found=1
            echo "config_node_integration_${seed}.${i}.ini"
        fi
        i=$(( $i + 1 ))
    done
}


script_executor() {
    #
    # return the command necessary to run the script (.py, .ipynb, any executable)
    #
    script=$1

    case $script in
        *.py)
            if [ -x $script ]
            then
                echo "$script"
            else
                echo "python $script"
            fi
            ;;
        *.ipynb)
            # converting notebook to script to run
            output="${script##*/}.$RANDOM"
            convert=$(jupyter nbconvert --output-dir=/tmp --output=$output --to script $script 2> /dev/null)
            if [ $? == 0 ]
            then
                # conversion did well
                echo "ipython /tmp/$output.py"
            else
                # must quit
                echo "ERROR: CANNOT RUN THIS SCRIPT: $script"
                return -1
            fi
            ;;
        *)
            file=$(file $script| grep -i python)
            if [ -z "$file" ]
            then
                if [ -x "$script" ]
                then
                    echo "$script"
                else
                    echo "ERROR: CANNOT RUN THIS SCRIPT: $script"
                    return -1
                fi
            else
                if [ -x $script ]
                then
                    echo "$script"
                else
                    echo "python $script"
                fi
            fi
            ;;
    esac
    return 0
}

cleaning() {
    #
    # do all cleaning here (normal ending or trapped signal)
    #

    # avoid multiple CTLR-C from impatient users
    trap '' INT TERM

    #echo "** INFO: cleaning before quitting - please wait"
    banner "cleaning before quitting - please wait"

    # clean running node processes
    if [ -z "$ALL_PIDS" ]
    then
        echo "== INFO: no node process to kill"
    else
        echo "== INFO: killing node processes: $ALL_PIDS"
        kill -15 $ALL_PIDS
        sleep 3
        kill -9 $ALL_PIDS 2> /dev/null
    fi

    #
    # clean all datasets from nodes
    i=0
    while [ $i -lt ${#ALL_CONFIG[@]} ]
    do
        config=${ALL_CONFIG[$i]}
        $basedir/scripts/fedbiomed_run node config $config --delete-all

        # find node_id from config file
        # and delete corresponding message queue and dbfile
        nodeid=$(grep ^node_id $basedir/etc/$config | awk {'print $NF'})
        /bin/rm -f  $basedir/var/db_${nodeid}.json 2> /dev/null
        /bin/rm -fr $basedir/var/queue_manager_${nodeid} 2> /dev/null

        /bin/rm -f $basedir/etc/$config 2> /dev/null
        i=$(( $i + 1 ))
    done

    # clean files
    if [ ! -z "$FILES_TO_CLEAN" ]
    then
        echo "== INFO: cleaning file(s): $FILES_TO_CLEAN"
        /bin/rm -f $FILES_TO_CLEAN
    fi

}

cleaning_trap() {
    #
    # script interruption
    #

    # avoid multiple CTLR-C from impatient users
    trap '' INT TERM

    banner "end to end test interrupted"
    cleaning
    echo "== Failure: script was interrupted"
    exit 1
}

find_gtimeout() {
    #
    # as it's name explains
    #
    case $(uname) in
        Linux )
            CMD_TIMEOUT="/usr/bin/timeout"
            return
            ;;
        Darwin )
            for c in /usr/local/bin/gtimeout /opt/homebrew/bin/gtimeout
            do
                if [ -x "$c" ]
                then
                    CMD_TIMEOUT=$c
                    return
                fi
            done
            echo "== ERROR Please install gtimeout using: brew install coreutils"
            exit 1
            ;;
        *)
            echo "== ERROR This script is only supported on Linux and Apple Mac OSX"
            exit 1
            ;;
    esac
}


# ---------------
# **   main    **
# ---------------

# trap some signals to do a proper cleaning at the end
#trap cleaning_trap INT TERM

# locate the topdir of the distribution
basedir=$(cd "$(dirname $0)"/.. || exit 1 ; pwd)

banner "decoding & verifying arguments"

# deal with arguments being relative files (done later)
CURRENT_DIR=$(pwd)

# prerequisite: OS specific commands
find_gtimeout

# argument decoding
SCRIPT=""          # script to run as a researcher
DATASETS=()        # array of provided DATASETS (one dataset per node)
FILES_TO_CLEAN=""  # files to clean after the launch
while (($# > 0)); do
    case $1 in
        -h|--help )
            usage
            exit 0
            ;;
        -s | --script )
            (($# >= 2 )) || { bad_usage "$1"; }
            SCRIPT="$2"
            shift
            ;;

        -t | --timeout )
            (($# >= 2 )) || { bad_usage "$1"; }
            TEST_TIMEOUT="$2"
            shift
            ;;

        -d | --dataset )
            (($# >= 2 )) || { bad_usage "$1"; }
            DATASETS+=("$2")
            shift
            ;;

        -* )
            bad_usage "Unknown option: $1"
            ;;
        * )
            bad_usage "no parameter allowed: $1"
            ;;
    esac
    shift
done

# mandatory arguments
[[ $SCRIPT ]] || bad_usage "providing a script is mandatory"
[[ ${#DATASETS[@]} == 0 ]] && bad_usage "providing a dataset json description is mandatory (at least one)"

# verify TEST_TIMEOUT
case $TEST_TIMEOUT in
    ''|*[!0-9]*)
        bad_usage "please provide a timeout value as an integer"
    ;;
    *) ;; # given value it OK
esac

# transform relative filenames to absolute filenames
case $SCRIPT in
    /* ) ;; # nothing to do
    *)
        SCRIPT="${CURRENT_DIR}/${SCRIPT}"
        ;;
esac

# loop on all dataset's filename to make it absolute
i=0
while [ $i -lt ${#DATASETS[@]} ]
do
    case ${DATASETS[$i]} in
        /* ) ;;  # nothing to do (already absolute)
        *)
            DATASETS[$i]="${CURRENT_DIR}/${DATASETS[$i]}"
            ;;
    esac

    i=$(( $i + 1 ))
done

# verify existence of dataset's file(s) before launching something
i=0
while [ $i -lt ${#DATASETS[@]} ]
do
    dataset=${DATASETS[$i]}
    [[ -f $dataset ]] || { echo "== ERROR dataset does not exist: $dataset" ; exit 1 ;}
    i=$(( $i + 1 ))
done

# Activate researcher conda environment
# (necessary to find a proper python/ipython)
source $basedir/scripts/fedbiomed_environment researcher
conda activate --stack fedbiomed-researcher-end-to-end

# is script ok ?
CMD_TO_RUN=$(script_executor $SCRIPT)

# if CMD_TO_RUN is an ipython script, we should clean the file at the end
case $CMD_TO_RUN in
    ERROR*)
      echo "== $CMD_TO_RUN"  # this is an error message in fact
      cleaning
      echo "== $CMD_TO_RUN"  # repeat at the end of the script for lisibility
      exit 1
    ;;
    ipython*)
        FILES_TO_CLEAN+="${CMD_TO_RUN##* } "
    ;;
esac

##### try to run the whole thing....

# run and start nodes, memorize the pids of all these processes and subprocesses
ALL_PIDS=""
ALL_CONFIG=()
i_node=0
while [ $i_node -lt 1 ] # in order to generate two nodes containing all the datasets.
do
  ((i_node+=1))
  i_dataset=0
  seed=$RANDOM

  # generate a random config file name
  config=$(generate_config_filename $seed)

  # store it for later cleaning
  ALL_CONFIG+=("$config")

  while [ $i_dataset -lt ${#DATASETS[@]} ]
  do
      dataset=${DATASETS[$i_dataset]}
      banner "i_dataset = $i_dataset"
      banner "launching node using: $dataset"

      if [ ! -f "$dataset" ]
      then
          echo "== ERROR: dataset $dataset is not a valid"
          cleaning
          exit 1
      fi

      # populate node
      echo "== INFO: populating fedbiomed node"
      $basedir/scripts/fedbiomed_run node config ${config} -adff $dataset || true

      ((i_dataset+=1))
  done
  # launch node
  echo "== INFO: launching fedbiomed node"
  $basedir/scripts/fedbiomed_run node config ${config} start &
  pid=$!
  sleep 10

  # store node pid and subprocesses pids
  ALL_PIDS+=" $pid $(subprocess $pid)"
done


# launch test and wait for completion
banner "launching fedbiomed researcher ($CMD_TO_RUN)"
${CMD_TIMEOUT} --preserve-status --signal=HUP --kill-after=10 --foreground  $TEST_TIMEOUT $CMD_TO_RUN
status=$?

# do the cleaning before exit
cleaning

## propagate exit code
banner "quitting"
if [ $status -eq 0 ]
then
    echo "== Success"
    exit 0
else
    echo "== Failure with status: $status"
    exit 1
fi
