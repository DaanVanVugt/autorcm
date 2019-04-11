#!/usr/bin/env bash
# Automatically start an RCM session (if necessary) and connect to it
# with turbovnc.
#
# Daan van Vugt <daanvanvugt@gmail.com>
set -eu
shopt -s extglob

function usage() {
  echo ""
  echo "Usage: `basename $0` [-hv] [-f <config-file>] [-g <geometry>] [-t <timelimit>] [-n <n_cpu>] [-m <memory>]"
  echo ""
  echo "  -h               Print this usage information and exit"
  echo "  -v               Enable verbose operation (use multiple times for more verbosity)"
  echo "  -f <config-file> Read default settings from a config file (default ~/.autorcm)"
  echo "  -g <geometry>    Set resolution of remote desktop (default 1920x1080)"
  echo "  -t <timelimit>   Set time-limit of job (default 2:58:00)"
  echo "  -n <n_cpu>       Number of cores to request (default 4)"
  echo "  -m <memory>      Memory to request in GB (default 18)"
  echo ""
  echo "Command-line arguments overwrite config file options."
  echo "You need to setup ssh key authentication and your username in .ssh/config"
  echo "for login.marconi.cineca.it."
  echo ""
  echo "Use at your own risk: the existing RCM job limits were instated for a reason."
  echo ""
  echo "The config file has this format:"
  echo "var=value"
  echo "valid vars are geometry, timelimit, n_cpu and memory."
}
define(){ IFS='\n' read -r -d '' ${1} || true; }

# Initialize our own variables:
default_config_file=~/.autorcm

configfile=$default_config_file
verbose=0
geometry=1920x1080
timelimit=2:58:00
ncpu=4
mem=18

# command-line option defaults
mygeometry=""
mytimelimit=""
myncpu=""
mymem=""

while getopts "h?vg:t:n:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    v)  verbose=$((verbose + 1))
        ;;
    f)  configfile=$OPTARG
        ;;
    g)  mygeometry=$OPTARG
        ;;
    t)  mytimelimit=$OPTARG
        ;;
    n)  myncpu=$OPTARG
        ;;
    m)  mymem=$OPTARG
        ;;
    esac
done


if [ -f $configfile ]; then
    # Read config file
    while IFS='= ' read -r lhs rhs
    do
        if [[ ! $lhs =~ ^\ *# && -n $lhs ]]; then
        rhs="${rhs%%\#*}"    # Del in line right comments
        rhs="${rhs%%*( )}"   # Del trailing spaces
        rhs="${rhs%\"*}"     # Del opening string quotes 
        rhs="${rhs#\"*}"     # Del closing string quotes 
        declare $lhs="$rhs"
    fi
    done < $configfile
    if [ "$verbose" -ge 2 ]; then
        echo "Read config file $configfile"
    fi
else
    if [ "$verbose" -ge 2 ] || [ "$configfile" -ne "$default_config_file" ]; then
        echo "Config file $configfile could not be read."
    fi
fi

# Overwrite with command line arguments if present
[[ ! -z $mygeometry ]] && geometry=$mygeometry
[[ ! -z $mytimelimit ]] && timelimit=$mytimelimit
[[ ! -z $myncpu ]] && ncpu=$myncpu
[[ ! -z $mymem ]] && mem=$mymem

if [ "$verbose" -ge 1 ]; then
    echo "Settings:"
    echo "geometry=$geometry"
    echo "timelimit=$timelimit"
    echo "ncpu=$ncpu"
    echo "mem=$mem"
fi

# constants
N=2 # Don't know why this version number is used
HOST=login.marconi.cineca.it

# Connect to marconi (with a controlmaster connection)
# Get username
user=$(ssh -M $HOST whoami)
if [ "$verbose" -ge 2 ]; then
    echo "Established ControlMaster connection to $HOST"
    echo "username: $user"
fi

job_hostname=""
function has_job() {
    jobline=$(ssh $HOST squeue -n $user-slurm-$N -u $user -l | grep RUNNING)
    if  [ ! -z "$jobline" ]; then
        job_hostname=$(grep -o 'r[0-9]*c[0-9]*s[0-9]*' <<< "$jobline")
        return 0
    else
        return 1
    fi
}
function waiting_for_job() {
    jobline=$(ssh $HOST squeue -n $user-slurm-$N -u $user -l | grep PENDING)
    if  [ ! -z "$jobline" ]; then
        return 0
    else
        return 1
    fi
}

function launch_job() {
# Job script for slurm
define JOBSCRIPT <<EOT
#!/bin/bash
#SBATCH --partition skl_usr_dbg
#SBATCH --qos=qos_rcm
#SBATCH --time=$timelimit
#SBATCH --job-name=$user-slurm-$N
#SBATCH --output /marconi/home/userexternal/$user/.rcm/$user-slurm-$N.joblog
#SBATCH -N 1 -n $ncpu --mem=${mem}GB
module load rcm

for d_p in \$(vncserver  -list | grep ^: | cut -d: -f2 | cut -f 1,3 --output-delimiter=@); do
    i=\$(echo \$d_p | cut -d@ -f2)
    d=\$(echo \$d_p | cut -d@ -f1)
    a=\$(ps -p \$i -o comm=)
    if [ "x\$a" == "x" ] ; then 
      vncserver -kill  :\$d 1>/dev/null
    fi
done
vncserver -fg -geometry $geometry -rfbauth /marconi/home/userexternal/$user/.rcm/$user-slurm-$N.joblog.pwd -xstartup \${RCM_HOME}/bin/config/xstartup.fluxbox > /marconi/home/userexternal/$user/.rcm/$user-slurm-$N.joblog.vnc 2>&1
EOT

    # Generate a new password for the vnc connection
    vncpass="$(pwgen -y 8 1)"
    vncpass_crypt="$(echo "$vncpass" | vncpasswd -f)"
    echo "$vncpass_crypt" | ssh $HOST "cat > ~/.rcm/$user-slurm-$N.joblog.pwd"
    output="$(ssh $HOST "cat > /tmp/$user-slurm-$N.job; sbatch /tmp/$user-slurm-$N.job" <<< "$JOBSCRIPT")"
    if [ "$verbose" -ge 1 ]; then
        echo "$output"
    fi
}


function connect_vnc() {
    vncpass_crypt="$(ssh $HOST "cat ~/.rcm/$user-slurm-$N.joblog.pwd")"
    vnc_settings="$(ssh $HOST "cat ~/.rcm/$user-slurm-$N.joblog.vnc")"
    # this could be nicer
    myscreen_number=$(echo "$vnc_settings" | grep 'on display' | grep -o ':[0-9]*' | tail -n 1 | tr -d ':')
    screen_number=$(printf "%02d" $myscreen_number)
    if [ -z "$screen_number" ]; then
        echo "ERROR: cannot find VNC server"
        return
    fi

    if [ "$verbose" -ge 2 ]; then
        echo "screen number $screen_number"
    fi
    localport=5999 # TODO: find a unused port
    ssh -fNL $localport:$job_hostname-hfi:59$screen_number $HOST
    if [ "$verbose" -ge 1 ]; then
        echo "Created SSH tunnel from localhost:$localport to $job_hostname-hfi.marconi.cineca.it:59$screen_number"
    fi
    vncpass_crypt_ascii="$(echo "$vncpass_crypt" | xxd -c 256 -ps)"
    vncviewer -loglevel 150 localhost::$localport -EncPassword="$vncpass_crypt_ascii"
}



if has_job; then
    if [ "$verbose" -ge 1 ]; then
        echo "Existing job found on $job_hostname, connecting to VNC server"
    fi
    connect_vnc
else
    if ! waiting_for_job; then
        launch_job
    fi
    for i in {1..120}
    do
        if [ "$verbose" -ge 2 ]; then
            echo "Waiting for job start"
        fi
        if has_job; then
            if [ "$verbose" -ge 1 ]; then
                echo "Job started on $job_hostname, connecting VNC"
            fi
            connect_vnc
            break
        fi
        sleep 1
    done
fi


# Kill the ssh connection
ssh -M -O exit $HOST
if [ "$verbose" -ge 2 ]; then
    echo "Closed ControlMaster connection to $HOST"
fi
