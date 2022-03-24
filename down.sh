#!/bin/bash

function wait_for_stack() {
   stack=$1
   status="PENDING"

   until [ "$status" == "DELETE_COMPLETE" -o "$status" == "FAILURE" -o -z "$status" ]; 
   do
     status=$(aws cloudformation describe-stacks --stack-name $stack 2>/dev/null | jq -r '.Stacks[].StackStatus' )
     echo "$status" | grep "Stack with id $stack does not exist" >/dev/null
     exitCode=$?
     if [ $exitCode -eq 0 ]; then
        echo "[$(date)] [$stack] stack $stack is already gone.  Going to next step."
        status="DELETE_COMPLETE"
     elif [ -n "$status" -a "$status" != "DELETE_COMPLETE" ]; then 
        echo "[$(date)] [$stack] waiting for stack to do down.  Currently $status"
        sleep 5
     fi
   done
   if [ -n "$status" -a "$status" != "DELETE_COMPLETE" ]; then
     echo "[$(date)] [$stack] stack is NOT down: $status."
     return 1
   fi
   echo "[$(date)] [$stack] stack is down."
   return 0
}
function die() {
   msg="$*"
   echo "[$(date)] [FATAL] $msg" 1>&2 
   exit 1
}
aws cloudformation delete-stack --stack-name wg1
wait_for_stack wg1
sleep 1
aws cloudformation delete-stack --stack-name wg1-eip 
wait_for_stack wg1-eip
